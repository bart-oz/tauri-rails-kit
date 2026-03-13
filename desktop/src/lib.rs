mod bundle;
mod commands;
mod error;
mod health;
mod process;
mod ruby;
mod state;

pub use error::AppError;

use commands::{get_rails_port, stop_rails_server};
use health::{spawn_health_monitor, wait_for_server_health};
use process::{find_available_port, spawn_rails_server, spawn_solid_queue_worker};
use state::AppState;
use tauri::Manager;

const DEFAULT_PORT: u16 = 8934;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState::default())
        .setup(|app| {
            app.handle().plugin(
                tauri_plugin_log::Builder::default()
                    .level(log::LevelFilter::Info)
                    .build(),
            )?;

            log::info!(
                "tauri-rails-kit starting (build: {})",
                if cfg!(debug_assertions) {
                    "dev"
                } else {
                    "release"
                }
            );

            // In production, fail fast if the bundle is incomplete.  In dev,
            // skip — no bundle is required for the fast iteration loop.
            #[cfg(not(debug_assertions))]
            {
                if let Err(e) = bundle::verify_bundle_integrity(app.handle()) {
                    log::error!("Bundle integrity check failed: {}", e);
                    return Err(Box::new(std::io::Error::new(
                        std::io::ErrorKind::Other,
                        e.to_string(),
                    )));
                }
            }

            // Start Rails in a background task so the launcher splash screen
            // can display immediately while the server boots.
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let state = app_handle.state::<AppState>();

                let port = match find_available_port(DEFAULT_PORT) {
                    Some(p) => p,
                    None => {
                        log::error!("No available port found starting from {}", DEFAULT_PORT);
                        return;
                    }
                };

                if let Err(e) = spawn_rails_server(port, &state) {
                    log::error!("Failed to spawn Rails: {}", e);
                    return;
                }

                if let Err(e) = wait_for_server_health(port).await {
                    log::error!("Rails did not become healthy: {}", e);
                    return;
                }

                // Expose the port — unblocks get_rails_port, launcher navigates.
                state.set_port(port);
                log::info!("Rails ready on port {} — launcher navigating", port);

                if let Err(e) = spawn_solid_queue_worker(&state) {
                    // Non-fatal: the app runs without background job processing.
                    log::warn!("Solid Queue worker failed to start: {}", e);
                }

                spawn_health_monitor(app_handle.clone(), port);
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![get_rails_port, stop_rails_server])
        .on_window_event(|window, event| {
            if matches!(
                event,
                tauri::WindowEvent::CloseRequested { .. } | tauri::WindowEvent::Destroyed
            ) {
                log::info!("Window closing — stopping child processes");
                window.state::<AppState>().stop_processes();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
