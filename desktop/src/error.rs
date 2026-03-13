use thiserror::Error;

/// Errors that can occur during application startup and process management.
///
/// Every variant includes a `Fix:` hint so operators and developers can resolve
/// problems without digging through source code or logs.
#[derive(Debug, Error)]
pub enum AppError {
    #[error(
        "No available port found in range {start}–{end}. \
         Fix: close applications that are using ports in that range, or restart your Mac."
    )]
    NoPortAvailable { start: u16, end: u16 },

    #[error(
        "Rails application directory not found. \
         Fix: ensure webapp/ exists at the expected path relative to the application bundle."
    )]
    RailsDirectoryNotFound,

    #[error(
        "Bundled Ruby runtime not found. \
         Fix: run ./scripts/bundle-macos-x86_64.sh (Intel) or \
         ./scripts/bundle-macos-arm64.sh (Apple Silicon) before building."
    )]
    RubyNotBundled,

    #[error(
        "Failed to start Rails server: {reason}. \
         Fix: check application logs for the underlying error."
    )]
    RailsStartFailed { reason: String },

    #[error(
        "Rails server did not pass the health check after {seconds}s. \
         Fix: check application logs for Rails startup errors (database, missing gems, etc.)."
    )]
    HealthCheckTimeout { seconds: u64 },

    #[error(
        "Application bundle is incomplete — missing: {missing}. \
         Fix: reinstall the application."
    )]
    BundleIncomplete { missing: String },
}

impl From<AppError> for String {
    fn from(e: AppError) -> Self {
        e.to_string()
    }
}
