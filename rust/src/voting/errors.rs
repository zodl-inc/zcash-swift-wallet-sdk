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
