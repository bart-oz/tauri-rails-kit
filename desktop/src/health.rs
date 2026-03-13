use std::time::Duration;

use tauri::Emitter;

use crate::AppError;

const STARTUP_DELAY_SECS: u64 = 5;
const HEALTH_CHECK_INTERVAL_SECS: u64 = 2;
const HEALTH_CHECK_TIMEOUT_SECS: u64 = 10;
/// 90 × 2 s = 3 min maximum startup window.
const MAX_HEALTH_CHECK_ATTEMPTS: u32 = 90;
/// Extra warmup after /up passes.
///
/// WHY: /up responds before Rails has fully loaded all routes and assets.
/// A short extra wait avoids a blank first-load in the webview.
const EXTRA_WARMUP_SECS: u64 = 3;
const HEALTH_ENDPOINT: &str = "/up";
const HEALTH_MONITOR_INTERVAL_SECS: u64 = 30;
const HEALTH_MONITOR_TIMEOUT_SECS: u64 = 5;
const HEALTH_MONITOR_MAX_FAILURES: u32 = 3;

/// Polls `GET /up` until Rails responds with a success status.
///
/// Waits an initial delay to let Rails start, then polls every 2 s for up to
/// 3 minutes.  Adds a short warmup after the health check passes so all routes
/// and assets are loaded before the launcher navigates.
pub(crate) async fn wait_for_server_health(port: u16) -> Result<(), AppError> {
    let timeout_secs = (MAX_HEALTH_CHECK_ATTEMPTS as u64) * HEALTH_CHECK_INTERVAL_SECS;
    log::info!("Waiting for Rails to boot (up to {}s)...", timeout_secs);

    tokio::time::sleep(Duration::from_secs(STARTUP_DELAY_SECS)).await;

    let client = reqwest::Client::new();
    let url = format!("http://127.0.0.1:{}{}", port, HEALTH_ENDPOINT);

    for attempt in 1..=MAX_HEALTH_CHECK_ATTEMPTS {
        tokio::time::sleep(Duration::from_secs(HEALTH_CHECK_INTERVAL_SECS)).await;

        match client
            .get(&url)
            .timeout(Duration::from_secs(HEALTH_CHECK_TIMEOUT_SECS))
            .send()
            .await
        {
            Ok(r) if r.status().is_success() => {
                log::info!("Rails health check passed (attempt {})", attempt);
                tokio::time::sleep(Duration::from_secs(EXTRA_WARMUP_SECS)).await;
                log::info!("Rails fully ready");
                return Ok(());
            }
            _ if attempt == MAX_HEALTH_CHECK_ATTEMPTS => {
                return Err(AppError::HealthCheckTimeout {
                    seconds: timeout_secs,
                });
            }
            _ => {}
        }
    }

    Ok(())
}

/// Spawns a background task that emits `"health-alert"` to the frontend after
/// `HEALTH_MONITOR_MAX_FAILURES` consecutive failed health checks.
pub(crate) fn spawn_health_monitor(app_handle: tauri::AppHandle, port: u16) {
    tauri::async_runtime::spawn(async move {
        let client = reqwest::Client::new();
        let url = format!("http://127.0.0.1:{}{}", port, HEALTH_ENDPOINT);
        let mut failures: u32 = 0;

        loop {
            tokio::time::sleep(Duration::from_secs(HEALTH_MONITOR_INTERVAL_SECS)).await;

            let healthy = client
                .get(&url)
                .timeout(Duration::from_secs(HEALTH_MONITOR_TIMEOUT_SECS))
                .send()
                .await
                .map(|r| r.status().is_success())
                .unwrap_or(false);

            if healthy {
                failures = 0;
            } else {
                failures += 1;
                log::warn!("Rails health check failed ({} consecutive)", failures);
                if failures >= HEALTH_MONITOR_MAX_FAILURES {
                    let _ = app_handle.emit("health-alert", "rails_unhealthy");
                }
            }
        }
    });
}
