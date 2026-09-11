//! Transport route — Tor or direct — selected when a voting session is opened.
//!
//! `zcash_voting` keeps PIR, tree-sync, helper and vote-chain traffic behind one
//! host-supplied request executor, [`zcash_voting::RouteHttp`]. [`SdkRoute`] is
//! this SDK's executor: either the crate's own direct HTTP client, or the
//! wallet's Tor runtime. A session picks one when it opens and keeps it, so a
//! round that chose Tor can never reach the network any other way — a Tor route
//! that cannot connect fails the request rather than falling back, because a
//! silent fall-back would put the voter's traffic on the clear network after
//! they asked for Tor, which is the one outcome worse than the request failing.
//!
//! The crate owns protocol headers, deadlines, response ceilings and the
//! definite-versus-ambiguous classification; this module owns only how one
//! request leaves the device, and what the Tor client's failures mean in the
//! crate's [`RoutePhase`] terms.

use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use zcash_client_backend::tor::{Error as TorError, http::HttpError};
use zcash_voting::{
    DirectRoute, HyperTransport, RouteError, RouteFuture, RouteHttp, RoutePhase, RouteRequest,
    RouteResponse,
};

/// The request executor a voting session routes its traffic through.
///
/// Chosen once when the session opens. There is deliberately no path from
/// [`Self::Tor`] to a direct connection: an unavailable Tor route fails the
/// request.
pub(super) enum SdkRoute {
    /// The crate's own pooled HTTP/HTTPS client.
    Direct(DirectRoute),
    /// The wallet's Tor runtime. Boxed because an owned `TorRuntime` is an
    /// order of magnitude larger than a `DirectRoute`, and every session pays
    /// for the larger arm otherwise.
    Tor(Box<TorRoute>),
}

impl SdkRoute {
    /// The direct HTTP/HTTPS route.
    pub(super) fn direct() -> Self {
        Self::Direct(DirectRoute::new())
    }

    /// The Tor route over `tor`.
    ///
    /// Takes the runtime by value so the session owns the handle it routes
    /// through; pass [`crate::tor::TorRuntime::isolated_client`] to keep a
    /// session's circuits unlinkable from the rest of the wallet's Tor use.
    pub(super) fn tor(tor: crate::tor::TorRuntime) -> Self {
        Self::Tor(Box::new(TorRoute { tor }))
    }
}

impl RouteHttp for SdkRoute {
    fn execute<'a>(
        &'a self,
        request: RouteRequest<'a>,
        on_dispatch: &'a (dyn Fn() + Send + Sync),
    ) -> RouteFuture<'a> {
        match self {
            Self::Direct(direct) => direct.execute(request, on_dispatch),
            Self::Tor(tor) => tor.execute(request, on_dispatch),
        }
    }

    fn hook_precedes_connection_setup(&self) -> bool {
        match self {
            Self::Direct(direct) => direct.hook_precedes_connection_setup(),
            Self::Tor(tor) => tor.hook_precedes_connection_setup(),
        }
    }

    fn enforces_connect_timeout(&self) -> bool {
        match self {
            Self::Direct(direct) => direct.enforces_connect_timeout(),
            Self::Tor(tor) => tor.enforces_connect_timeout(),
        }
    }
}

/// Routes one voting request over the wallet's Tor client.
pub(super) struct TorRoute {
    tor: crate::tor::TorRuntime,
}

/// What the adapter had observed when the Tor client reported a failure.
///
/// The Tor client reports the same error type throughout a request, so what a
/// failure means depends on how far the request had got. The adapter learns
/// that from the one hook it is given: the response-parsing callback, which
/// runs only once response headers have arrived.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum TorPhase {
    /// No response headers had arrived.
    BeforeHeaders,
    /// Response headers had arrived; only the body was outstanding.
    AfterHeaders,
}

/// The [`RoutePhase`] a Tor client failure translates to.
///
/// Pre-dispatch is claimed only where the Tor client's error names a stage that
/// runs before the request is written — bootstrap, the circuit, TLS, building
/// the request, spawning the connection task — or a deadline that expired in
/// one. Everything else observed before headers may have reached the network
/// and is reported as such, because a helper or chain POST wrongly called
/// undispatched would be repeated.
// Consumed by `TorRoute::request`; also the module's unit-tested contract.
pub(super) fn classify_tor_error(error: &TorError, phase: TorPhase) -> RoutePhase {
    if phase == TorPhase::AfterHeaders {
        return RoutePhase::ResponseRead;
    }
    match error {
        TorError::MissingTorDirectory | TorError::Tor(_) | TorError::Io(_) => {
            RoutePhase::BeforeDispatch
        }
        TorError::Http(
            HttpError::NonHttpUrl
            | HttpError::Http(_)
            | HttpError::Tls(_)
            | HttpError::Spawn(_)
            | HttpError::Timeout(_),
        ) => RoutePhase::BeforeDispatch,
        // `HttpError::Hyper` covers the write and the wait for headers, so it
        // may have been delivered. `HttpError::Unsuccessful` is documented
        // upstream as unreachable for `http_get`/`http_post`; it is mapped here
        // rather than assumed away. Both enums are `#[non_exhaustive]`, so a
        // variant added upstream lands here too — conservatively.
        _ => RoutePhase::AfterDispatch,
    }
}

/// The URI a Tor request is dispatched to, or the pre-dispatch failure that
/// stands in for it.
///
/// Factored out of [`TorRoute::request`] so the rejection path is exercised
/// without a Tor runtime, which cannot be built without a Tor directory.
fn parse_url(url: &str) -> Result<http::Uri, RouteError> {
    url.parse::<http::Uri>()
        .map_err(|error| RouteError::before_dispatch(format!("invalid URL: {error}")))
}

/// The two request shapes the Tor client offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TorMethod {
    Get,
    Post,
}

/// The Tor client call `method` maps to, or the pre-dispatch failure for a
/// method it has no call for.
///
/// The crate only ever issues GET and POST. Anything else is refused rather
/// than quietly sent as one of them, because a method the endpoint did not
/// receive is a request it did not answer.
fn tor_method(method: &http::Method) -> Result<TorMethod, RouteError> {
    if *method == http::Method::GET {
        Ok(TorMethod::Get)
    } else if *method == http::Method::POST {
        Ok(TorMethod::Post)
    } else {
        Err(RouteError::before_dispatch(format!(
            "the Tor route cannot issue a {method} request"
        )))
    }
}

/// Reads a response body, stopping at `max` bytes.
///
/// Runs only after response headers have arrived, so every failure here is
/// [`RoutePhase::ResponseRead`] — a truncated read and an over-long body alike.
/// The body type is left generic because `hyper` is not a dependency of this
/// crate and its `Incoming` type therefore cannot be named.
async fn read_body<B: BodyExt<Data = Bytes>>(body: B, max: usize) -> Result<Vec<u8>, RouteError>
where
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    Limited::new(body, max)
        .collect()
        .await
        .map(|body| body.to_bytes().to_vec())
        .map_err(|error| {
            RouteError::response_read(format!("read response body (limit {max} bytes): {error}"))
        })
}

impl TorRoute {
    async fn request(
        &self,
        request: RouteRequest<'_>,
        on_dispatch: &(dyn Fn() + Send + Sync),
    ) -> Result<RouteResponse, RouteError> {
        let RouteRequest {
            method,
            url,
            headers,
            body,
            timeout,
            // The Tor client's connection-setup deadline is fixed when the
            // client is created, so this route cannot bound setup per request
            // and says so through `enforces_connect_timeout`.
            connect_timeout: _,
            max_response_bytes,
        } = request;
        let uri = parse_url(url)?;
        let method = tor_method(&method)?;
        let headers = headers.to_vec();
        let apply = move |mut builder: http::request::Builder| {
            for (name, value) in &headers {
                builder = builder.header(name, value);
            }
            // The Tor client runs this callback with the circuit, the TLS
            // session and the HTTP/1 handshake already established, and writes
            // the request immediately after it returns. That makes this the
            // last moment at which no request byte can have left.
            on_dispatch();
            builder
        };
        let seen_headers = Arc::new(AtomicBool::new(false));
        let seen = Arc::clone(&seen_headers);
        // The body read's own failure travels as the response *value*, not as a
        // Tor error, so it can never be mistaken for a pre-dispatch failure.
        let read_response = move |body| async move {
            seen.store(true, Ordering::SeqCst);
            Ok(read_body(body, max_response_bytes).await)
        };
        let client = self.tor.client();
        // Retries are disabled: the crate decides what may be repeated, from a
        // phase this adapter reports. A retry here would repeat a POST the
        // crate had classified as ambiguous.
        let call = async {
            match method {
                TorMethod::Get => {
                    client
                        .http_get(uri, apply, read_response, 0, |_| None)
                        .await
                }
                TorMethod::Post => {
                    client
                        .http_post(
                            uri,
                            apply,
                            Full::new(Bytes::from(body)),
                            read_response,
                            0,
                            |_| None,
                        )
                        .await
                }
            }
        };
        let phase = || {
            if seen_headers.load(Ordering::SeqCst) {
                TorPhase::AfterHeaders
            } else {
                TorPhase::BeforeHeaders
            }
        };
        let response = tokio::time::timeout(timeout, call)
            .await
            .map_err(|_| match phase() {
                TorPhase::AfterHeaders => {
                    RouteError::response_read("timed out reading the response body")
                }
                TorPhase::BeforeHeaders => RouteError::before_dispatch("timed out before dispatch"),
            })?
            .map_err(|error| {
                let message = error.to_string();
                match classify_tor_error(&error, phase()) {
                    RoutePhase::BeforeDispatch => RouteError::before_dispatch(message),
                    RoutePhase::AfterDispatch => RouteError::after_dispatch(message),
                    RoutePhase::ResponseRead => RouteError::response_read(message),
                }
            })?;
        let (parts, body) = response.into_parts();
        let body = body?;
        let headers = parts
            .headers
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|value| (name.as_str().to_string(), value.to_string()))
            })
            .collect();
        Ok(RouteResponse {
            status: parts.status.as_u16(),
            headers,
            body,
        })
    }
}

impl RouteHttp for TorRoute {
    fn execute<'a>(
        &'a self,
        request: RouteRequest<'a>,
        on_dispatch: &'a (dyn Fn() + Send + Sync),
    ) -> RouteFuture<'a> {
        Box::pin(self.request(request, on_dispatch))
    }

    // `hook_precedes_connection_setup` and `enforces_connect_timeout` both keep
    // their `false` defaults, and both are load-bearing:
    //
    // The Tor client does not fuse connection setup with the first write — it
    // opens the circuit and completes the TLS and HTTP/1 handshakes before it
    // asks for the request headers, which is where the dispatch hook fires. So
    // every connect failure is already reported before the hook and stays
    // definite without any declaration. Claiming otherwise would buy nothing
    // and cost a great deal: the crate would then honor a pre-dispatch phase
    // reported *after* the hook, and the one deadline that can expire there
    // covers the write as well as the wait for headers. A POST cut off by it
    // would be reported as never sent and repeated.
    //
    // Connection setup is bounded by the deadline fixed when the Tor client was
    // created, not by the caller's `connect_timeout`, so this route claims no
    // connect budget either.
}

/// The crate transport for the chain and helper traffic of one session.
///
/// PIR and vote-tree traffic keeps the shared direct transport instead
/// ([`super::runtime::direct_transport`]): it identifies no voter and is
/// throughput-sensitive, so it is not what this route governs.
pub(super) fn routed_transport(route: SdkRoute) -> Arc<HyperTransport<SdkRoute>> {
    Arc::new(HyperTransport::with_route(route))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use http_body_util::Full;
    use std::sync::atomic::{AtomicBool, Ordering};
    use zcash_client_backend::tor::{
        Error as TorError,
        http::{HttpError, TimeoutPhase},
    };
    use zcash_voting::{RouteHttp, RoutePhase, RouteRequest};

    fn http_build_error() -> http::Error {
        http::Request::builder()
            .header("invalid header name", "v")
            .body(())
            .expect_err("an invalid header name fails the builder")
    }

    fn json_error() -> serde_json::Error {
        serde_json::from_slice::<serde_json::Value>(b"truncated")
            .expect_err("`truncated` is not JSON")
    }

    #[test]
    fn tor_bootstrap_and_url_failures_are_before_dispatch() {
        for error in [
            TorError::MissingTorDirectory,
            TorError::Io(std::io::Error::other("fixture")),
            TorError::Http(HttpError::NonHttpUrl),
            TorError::Http(HttpError::Http(http_build_error())),
            TorError::Http(HttpError::Tls(std::io::Error::other("fixture"))),
            TorError::Http(HttpError::Timeout(TimeoutPhase::Connect)),
            TorError::Http(HttpError::Timeout(TimeoutPhase::Request)),
        ] {
            assert_eq!(
                classify_tor_error(&error, TorPhase::BeforeHeaders),
                RoutePhase::BeforeDispatch,
                "{error} must be reported as definitely undispatched"
            );
        }
    }

    #[test]
    fn other_failures_before_headers_are_after_dispatch() {
        for error in [
            TorError::Http(HttpError::Json(json_error())),
            // Documented upstream as unreachable for `http_get`/`http_post`; mapped
            // defensively rather than assumed away.
            TorError::Http(HttpError::Unsuccessful(
                http::StatusCode::INTERNAL_SERVER_ERROR,
            )),
        ] {
            assert_eq!(
                classify_tor_error(&error, TorPhase::BeforeHeaders),
                RoutePhase::AfterDispatch,
                "{error} may have reached the network"
            );
        }
    }

    #[test]
    fn failures_after_headers_are_response_read() {
        assert_eq!(
            classify_tor_error(
                &TorError::Http(HttpError::NonHttpUrl),
                TorPhase::AfterHeaders
            ),
            RoutePhase::ResponseRead
        );
        assert_eq!(
            classify_tor_error(
                &TorError::Http(HttpError::Timeout(TimeoutPhase::ResponseBody)),
                TorPhase::AfterHeaders
            ),
            RoutePhase::ResponseRead
        );
    }

    #[test]
    fn tor_route_with_invalid_url_fails_before_dispatch_without_network() {
        // A `TorRuntime` cannot be created without a Tor directory; the URL check runs
        // first, so it is factored out and exercised on its own.
        let error = parse_url("not a url").expect_err("a URL with spaces cannot be a URI");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
        assert!(parse_url("https://helper.example/x").is_ok());
    }

    #[test]
    fn only_get_and_post_reach_the_tor_client() {
        assert!(matches!(tor_method(&http::Method::GET), Ok(TorMethod::Get)));
        assert!(matches!(
            tor_method(&http::Method::POST),
            Ok(TorMethod::Post)
        ));
        let error = tor_method(&http::Method::PUT).expect_err("PUT is not a voting method");
        assert_eq!(error.phase, RoutePhase::BeforeDispatch);
    }

    #[test]
    fn response_body_cap_is_enforced_after_headers() {
        let runtime = crate::voting::runtime::runtime();
        let body = |len: usize| Full::new(Bytes::from(vec![0u8; len]));
        assert_eq!(
            runtime.block_on(read_body(body(8), 8)).expect("under cap"),
            vec![0u8; 8]
        );
        let error = runtime
            .block_on(read_body(body(9), 8))
            .expect_err("over cap");
        assert_eq!(error.phase, RoutePhase::ResponseRead);
    }

    #[test]
    fn direct_route_executes_against_loopback_server() {
        // Minimal HTTP/1.1 server on 127.0.0.1 answering 200 with body "ok". Bound
        // before the thread is spawned so the address is live when the client dials,
        // and the thread returns rather than blocking if no client ever arrives.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let addr = listener.local_addr().expect("loopback address");
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            // Read the whole request head before answering, so the response is not
            // written into a half-sent request.
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                match stream.read(&mut byte) {
                    Ok(1) => head.push(byte[0]),
                    _ => return,
                }
            }
            let _ = stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        });

        let route = SdkRoute::direct();
        let url = format!("http://{addr}/x");
        let headers: Vec<(String, String)> = Vec::new();
        let request = RouteRequest {
            method: http::Method::GET,
            url: &url,
            headers: &headers,
            body: Vec::new(),
            timeout: std::time::Duration::from_secs(5),
            connect_timeout: None,
            max_response_bytes: 1024,
        };
        let dispatched = AtomicBool::new(false);
        let response = crate::voting::runtime::runtime()
            .block_on(route.execute(request, &|| dispatched.store(true, Ordering::SeqCst)))
            .expect("the loopback server answers");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"ok");
        assert!(dispatched.load(Ordering::SeqCst));
    }

    #[test]
    fn direct_route_delegates_its_dispatch_semantics() {
        let route = SdkRoute::direct();
        assert!(route.hook_precedes_connection_setup());
        assert!(route.enforces_connect_timeout());
    }

    #[test]
    fn routed_transport_carries_the_selected_route() {
        let transport = routed_transport(SdkRoute::direct());
        assert!(matches!(**transport.route(), SdkRoute::Direct(_)));
    }
}
