//! Helper-specific Tor HTTP deadlines, bounded bodies and outcome classification.
use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use std::{future::Future, time::Duration};
use zcash_client_backend::tor::{Error, http::HttpError};
use zcash_voting::{
    HelperFuture, HelperResponse, HelperTransport, HelperTransportError, MAX_HELPER_RESPONSE_BYTES,
};

pub(super) struct TorHelperTransport {
    tor: crate::tor::TorRuntime,
}
impl TorHelperTransport {
    pub(super) fn new(tor: crate::tor::TorRuntime) -> Self {
        Self { tor }
    }
    async fn request(
        &self,
        url: &str,
        body: Option<Vec<u8>>,
        timeout: Duration,
    ) -> Result<HelperResponse, HelperTransportError> {
        let uri = url
            .parse::<http::Uri>()
            .map_err(|_| HelperTransportError::Transport("invalid helper URL".to_string()))?;
        let is_post = body.is_some();
        complete_request(timeout, async {
            // parse_response runs only after headers arrive. Keep its failure as
            // the response body value so it can never become a safe POST retry.
            let response = if let Some(body) = body {
                self.tor
                    .client()
                    .http_post(
                        uri,
                        |builder| builder.header(http::header::CONTENT_TYPE, "application/json"),
                        Full::new(Bytes::from(body)),
                        |body| async { Ok(read_body(body).await) },
                        0,
                        |_| None,
                    )
                    .await
            } else {
                self.tor
                    .client()
                    .http_get(
                        uri,
                        |builder| builder,
                        |body| async { Ok(read_body(body).await) },
                        0,
                        |_| None,
                    )
                    .await
            }
            .map_err(|error| classify(error, is_post))?;
            helper_response(response)
        })
        .await
    }
}
impl HelperTransport for TorHelperTransport {
    fn get<'a>(&'a self, url: &'a str, timeout: Duration) -> HelperFuture<'a> {
        Box::pin(self.request(url, None, timeout))
    }
    fn post_json<'a>(&'a self, url: &'a str, body: Vec<u8>, timeout: Duration) -> HelperFuture<'a> {
        Box::pin(self.request(url, Some(body), timeout))
    }
}
fn helper_response(
    response: http::Response<Result<Vec<u8>, HelperTransportError>>,
) -> Result<HelperResponse, HelperTransportError> {
    let (parts, body) = response.into_parts();
    Ok(HelperResponse::new(
        parts.status.as_u16(),
        body?,
        parts
            .headers
            .get(http::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned),
    ))
}
async fn complete_request<T>(
    timeout: Duration,
    future: impl Future<Output = Result<T, HelperTransportError>>,
) -> Result<T, HelperTransportError> {
    tokio::time::timeout(timeout, future)
        .await
        .map_err(|_| HelperTransportError::Timeout)?
}
async fn read_body<B: BodyExt<Data = Bytes>>(body: B) -> Result<Vec<u8>, HelperTransportError>
where
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    Limited::new(body, MAX_HELPER_RESPONSE_BYTES)
        .collect()
        .await
        .map(|body| body.to_bytes().to_vec())
        .map_err(|_| HelperTransportError::Response("helper body read failed".to_string()))
}
fn classify(error: Error, is_post: bool) -> HelperTransportError {
    match error {
        Error::Http(HttpError::Timeout(_)) => HelperTransportError::Timeout,
        Error::Tor(_)
        | Error::Io(_)
        | Error::MissingTorDirectory
        | Error::Http(
            HttpError::NonHttpUrl | HttpError::Http(_) | HttpError::Tls(_) | HttpError::Spawn(_),
        ) => HelperTransportError::Transport("Tor helper connection failed".to_string()),
        _ if is_post => {
            HelperTransportError::Ambiguous("Tor helper POST outcome is unknown".to_string())
        }
        _ => HelperTransportError::Transport("Tor helper GET failed".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(start_paused = true)]
    async fn deadline_covers_headers_and_body() {
        let result = tokio::time::timeout(
            Duration::from_secs(1),
            complete_request::<()>(Duration::from_millis(10), std::future::pending()),
        )
        .await;
        assert_eq!(
            result,
            Ok(Err(HelperTransportError::Timeout)),
            "the complete request must honor the requested deadline"
        );
    }
    #[tokio::test]
    async fn response_cap_rejects_oversized_body_after_headers() {
        assert!(matches!(
            read_body(Full::new(Bytes::from(vec![
                0;
                MAX_HELPER_RESPONSE_BYTES + 1
            ])))
            .await,
            Err(HelperTransportError::Response(_))
        ));
        assert_eq!(
            read_body(Full::new(Bytes::from(vec![0; MAX_HELPER_RESPONSE_BYTES])))
                .await
                .unwrap()
                .len(),
            MAX_HELPER_RESPONSE_BYTES
        );
    }
    #[test]
    fn status_and_content_type_survive_and_body_failure_is_response() {
        let response = helper_response(
            http::Response::builder()
                .status(503)
                .header(http::header::CONTENT_TYPE, "application/json")
                .body(Ok(b"busy".to_vec()))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response.status(), 503);
        assert_eq!(response.content_type(), Some("application/json"));
        assert_eq!(response.body(), b"busy");
        assert!(matches!(
            helper_response(http::Response::new(Err(HelperTransportError::Response(
                "truncated".to_string()
            )))),
            Err(HelperTransportError::Response(_))
        ));
    }
    #[test]
    fn uncertain_post_stage_error_is_never_safe_to_retry() {
        let parse_error = serde_json::from_slice::<serde_json::Value>(b"truncated").unwrap_err();
        assert!(matches!(
            classify(Error::Http(HttpError::Json(parse_error)), true),
            HelperTransportError::Ambiguous(_)
        ));
    }
    #[test]
    fn definite_pre_dispatch_failure_is_safe_but_timeout_is_unknown() {
        assert!(matches!(
            classify(Error::Http(HttpError::NonHttpUrl), true),
            HelperTransportError::Transport(_)
        ));
        assert!(matches!(
            classify(
                Error::Http(HttpError::Tls(std::io::Error::other("fixture"))),
                true
            ),
            HelperTransportError::Transport(_)
        ));
        assert_eq!(
            classify(
                Error::Http(HttpError::Timeout(
                    zcash_client_backend::tor::http::TimeoutPhase::Connect
                )),
                true
            ),
            HelperTransportError::Timeout
        );
    }
}
