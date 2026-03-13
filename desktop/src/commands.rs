use tauri::State;

use crate::state::AppState;

/// Returns the Rails port once the server has passed its health check, or
/// `None` while the server is still booting.
///
/// The launcher (`launcher/index.html`) polls this every 500 ms and navigates
/// to `http://localhost:{port}` as soon as a port is returned.
#[tauri::command]
pub(crate) async fn get_rails_port(state: State<'_, AppState>) -> Result<Option<u16>, String> {
    Ok(state.port())
}

/// Gracefully stops the Rails server and Solid Queue worker.
#[tauri::command]
pub(crate) async fn stop_rails_server(state: State<'_, AppState>) -> Result<(), String> {
    state.stop_processes();
    Ok(())
}
