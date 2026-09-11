//! Every voting FFI failure crosses the boundary as `VotingErrorView` JSON so
//! Swift can branch on typed kinds instead of message text.
use zcash_voting::{VotingError, VotingErrorView};

pub(super) fn voting_error(error: VotingError) -> anyhow::Error {
    let view = VotingErrorView::from(&error);
    match serde_json::to_string(&view) {
        Ok(json) => anyhow::anyhow!(json),
        Err(_) => anyhow::anyhow!(error.to_string()),
    }
}

pub(super) fn invalid_input(message: impl Into<String>) -> anyhow::Error {
    voting_error(VotingError::InvalidInput {
        message: message.into(),
    })
}

pub(super) fn internal(message: impl Into<String>) -> anyhow::Error {
    voting_error(VotingError::Internal {
        message: message.into(),
    })
}

/// Ensure `error` crosses the boundary as `VotingErrorView` JSON, wrapping it
/// as `invalid_input` only when it is not already an envelope.
///
/// For helpers that mix the two: some of what they call fails with a bare
/// message and some fails with an envelope already. Wrapping unconditionally
/// would nest one envelope's JSON inside another's `message`, leaving Swift a
/// typed error whose kind is right but whose text is a serialized error.
pub(super) fn envelope_or_invalid_input(error: anyhow::Error) -> anyhow::Error {
    let text = error.to_string();
    if serde_json::from_str::<VotingErrorView>(&text).is_ok() {
        error
    } else {
        invalid_input(text)
    }
}

pub(super) trait VotingResultExt<T> {
    fn ffi(self) -> anyhow::Result<T>;
}

impl<T> VotingResultExt<T> for Result<T, VotingError> {
    fn ffi(self) -> anyhow::Result<T> {
        self.map_err(voting_error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_voting::{VotingError, VotingErrorView};

    #[test]
    fn voting_error_display_is_error_view_json() {
        let error = voting_error(VotingError::InvalidInput {
            message: "bad".into(),
        });
        let view: VotingErrorView = serde_json::from_str(&error.to_string()).expect("json");
        // `VotingErrorView::from` sets `message` to `VotingError`'s `Display` text (via
        // `error.to_string()`), not the raw inner `message` field alone — every variant's
        // `thiserror` format prefixes it (e.g. "Invalid input: ", "Voting state is busy: ").
        assert_eq!(view.message, "Invalid input: bad");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
    }

    #[test]
    fn helpers_produce_invalid_input_and_internal_kinds() {
        let a: VotingErrorView = serde_json::from_str(&invalid_input("x").to_string()).unwrap();
        let b: VotingErrorView = serde_json::from_str(&internal("y").to_string()).unwrap();
        assert_eq!(serde_json::to_value(a.kind).unwrap(), "invalid_input");
        assert_eq!(serde_json::to_value(b.kind).unwrap(), "internal");
    }

    /// A bare message becomes an envelope; one that already is an envelope is
    /// returned untouched rather than nested inside a second one.
    #[test]
    fn envelope_or_invalid_input_wraps_only_bare_messages() {
        let wrapped = envelope_or_invalid_input(anyhow::anyhow!("seed must be at least 32 bytes"));
        let view: VotingErrorView = serde_json::from_str(&wrapped.to_string()).expect("json");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
        assert_eq!(
            view.message,
            "Invalid input: seed must be at least 32 bytes"
        );

        let already = envelope_or_invalid_input(voting_error(VotingError::InvalidInput {
            message: "network id 0 is Testnet".into(),
        }));
        let view: VotingErrorView = serde_json::from_str(&already.to_string()).expect("json");
        assert_eq!(view.message, "Invalid input: network id 0 is Testnet");
    }

    #[test]
    fn result_ext_maps_err() {
        let r: Result<(), VotingError> = Err(VotingError::Busy {
            message: "b".into(),
        });
        let e = r.ffi().unwrap_err();
        let view: VotingErrorView = serde_json::from_str(&e.to_string()).unwrap();
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "busy");
    }
}
