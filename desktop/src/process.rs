use crate::ruby::{build_rails_command, find_rails_directory};
use crate::state::AppState;
use crate::AppError;

const PORT_SCAN_RANGE: u16 = 100;

/// Finds the first available TCP port starting from `start`.
pub(crate) fn find_available_port(start: u16) -> Option<u16> {
    (start..start + PORT_SCAN_RANGE)
        .find(|&port| std::net::TcpListener::bind(("127.0.0.1", port)).is_ok())
}

/// Runs `db:prepare` on first launch or `db:migrate` on subsequent launches.
fn setup_database(rails_dir: &std::path::Path) -> Result<(), AppError> {
    log::info!("Checking database setup...");

    let db_path = rails_dir.join("storage/desktop.sqlite3");
    let task = if db_path.exists() {
        "db:migrate"
    } else {
        "db:prepare"
    };

    log::info!("Running rails {}...", task);

    let status = build_rails_command(rails_dir, &[task])
        .map_err(|e| AppError::RailsStartFailed {
            reason: e.to_string(),
        })?
        .status()
        .map_err(|e| AppError::RailsStartFailed {
            reason: e.to_string(),
        })?;

    if !status.success() && task == "db:prepare" {
        return Err(AppError::RailsStartFailed {
            reason: "db:prepare failed — check logs for details".to_string(),
        });
    }

    log::info!("Database ready");
    Ok(())
}

/// Sets up the database, then spawns the Rails server on `port`.
pub(crate) fn spawn_rails_server(port: u16, state: &AppState) -> Result<(), AppError> {
    let rails_dir = find_rails_directory()?;
    setup_database(&rails_dir)?;

    let port_str = port.to_string();
    let mut cmd = build_rails_command(&rails_dir, &["server", "-p", &port_str])?;

    // WHY process_group(0): puts the child in its own process group so that
    // SIGKILL to -pid kills the entire Ruby/Puma tree, not just the top process.
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    let child = cmd.spawn().map_err(|e| AppError::RailsStartFailed {
        reason: e.to_string(),
    })?;

    state.set_rails_process(child);
    log::info!("Rails server spawned on port {}", port);
    Ok(())
}

/// Spawns the Solid Queue worker process.
pub(crate) fn spawn_solid_queue_worker(state: &AppState) -> Result<(), AppError> {
    let rails_dir = find_rails_directory()?;
    let mut cmd = build_rails_command(&rails_dir, &["solid_queue:start"])?;

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    let child = cmd.spawn().map_err(|e| AppError::RailsStartFailed {
        reason: format!("Solid Queue: {}", e),
    })?;

    state.set_solid_queue_process(child);
    log::info!("Solid Queue worker spawned");
    Ok(())
}
