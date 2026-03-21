/// Checks that all required bundled resources are present.
///
/// Fails fast in production so startup fails with a clear message rather than
/// a cryptic spawn error later.  Skipped entirely in dev builds — no bundle
/// is needed for the fast inner-loop iteration workflow.
#[cfg(not(debug_assertions))]
pub(crate) fn verify_bundle_integrity(
    app_handle: &tauri::AppHandle,
) -> Result<(), crate::AppError> {
    use crate::AppError;
    use tauri::Manager;

    let resource_dir =
        app_handle
            .path()
            .resource_dir()
            .map_err(|e| AppError::BundleIncomplete {
                missing: e.to_string(),
            })?;

    let required = [
        (
            "Ruby binary",
            resource_dir.join("resources/ruby/bin/ruby"),
        ),
        ("Rails Gemfile", resource_dir.join("_up_/webapp/Gemfile")),
    ];

    let missing: Vec<&str> = required
        .iter()
        .filter(|(label, path)| {
            if path.exists() {
                log::info!("Bundle: {} ✓", label);
                false
            } else {
                log::error!("Bundle: {} not found at {:?}", label, path);
                true
            }
        })
        .map(|(label, _)| *label)
        .collect();

    if missing.is_empty() {
        log::info!("Bundle integrity OK");
        Ok(())
    } else {
        Err(AppError::BundleIncomplete {
            missing: missing.join(", "),
        })
    }
}
