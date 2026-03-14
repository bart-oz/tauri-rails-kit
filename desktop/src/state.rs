use std::sync::Mutex;
use std::time::Duration;

/// Shared state managed by Tauri for the full lifetime of the application.
pub struct AppState {
    /// Port Rails is listening on — `None` until the health check passes.
    rails_port: Mutex<Option<u16>>,
    rails_process: Mutex<Option<std::process::Child>>,
    solid_queue_process: Mutex<Option<std::process::Child>>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            rails_port: Mutex::new(None),
            rails_process: Mutex::new(None),
            solid_queue_process: Mutex::new(None),
        }
    }
}

/// Guarantee cleanup on every exit path, including panics.
///
/// WHY: `on_window_event` is not reliably called on SIGINT/SIGKILL. Drop *is*
/// called whenever `AppState` goes out of scope, so it covers all normal exits.
impl Drop for AppState {
    fn drop(&mut self) {
        log::info!("AppState dropped — stopping all child processes");
        self.stop_processes();
    }
}

impl AppState {
    pub(crate) fn port(&self) -> Option<u16> {
        *self.rails_port.lock().unwrap()
    }

    /// Stores the Rails port — unblocks `get_rails_port` and the launcher.
    pub(crate) fn set_port(&self, port: u16) {
        *self.rails_port.lock().unwrap() = Some(port);
    }

    pub(crate) fn set_rails_process(&self, child: std::process::Child) {
        *self.rails_process.lock().unwrap() = Some(child);
    }

    pub(crate) fn set_solid_queue_process(&self, child: std::process::Child) {
        *self.solid_queue_process.lock().unwrap() = Some(child);
    }

    /// Stops Solid Queue, Rails, then kills any orphaned process on the Rails
    /// port.  Called from both `Drop` and `on_window_event` — idempotent.
    pub(crate) fn stop_processes(&self) {
        log::info!("Stopping all child processes...");

        stop_child(
            self.solid_queue_process.lock().unwrap().take(),
            "Solid Queue worker",
        );
        stop_child(self.rails_process.lock().unwrap().take(), "Rails server");

        #[cfg(unix)]
        if let Some(port) = self.port() {
            kill_processes_on_port(port);
        }

        *self.rails_port.lock().unwrap() = None;
        log::info!("All child processes stopped");
    }
}

/// Sends SIGTERM, waits 1 s, then sends SIGKILL to the child's process group.
fn stop_child(child: Option<std::process::Child>, label: &str) {
    let Some(mut child) = child else { return };
    let pid = child.id();
    log::info!("Stopping {} (PID {})...", label, pid);

    #[cfg(unix)]
    {
        // Safety: standard Unix signal calls — valid PID, valid signal numbers.
        unsafe {
            libc::kill(-(pid as i32), libc::SIGTERM);
            std::thread::sleep(Duration::from_millis(1_000));
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
    }

    #[cfg(not(unix))]
    let _ = child.kill();

    let _ = child.wait();
    log::info!("{} stopped", label);
}

/// SIGTERM → SIGKILL any process still holding `port` after managed shutdown.
#[cfg(unix)]
pub(crate) fn kill_processes_on_port(port: u16) {
    use std::process::Command;

    let Ok(output) = Command::new("lsof")
        .args(["-ti", &format!(":{}", port)])
        .output()
    else {
        return;
    };

    let Ok(stdout) = String::from_utf8(output.stdout) else {
        return;
    };

    for pid_str in stdout.lines() {
        if let Ok(pid) = pid_str.trim().parse::<i32>() {
            log::info!("Safety net: killing orphaned PID {} on port {}", pid, port);
            // Safety: standard Unix signal calls — PID obtained from lsof stdout.
            unsafe {
                libc::kill(pid, libc::SIGTERM);
                std::thread::sleep(Duration::from_millis(500));
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
}
