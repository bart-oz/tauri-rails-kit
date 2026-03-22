use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::AppError;

/// Resolves the Rails `webapp/` directory relative to the running executable.
///
/// | Mode       | Executable location            | `webapp/` location                        |
/// |------------|-------------------------------|-------------------------------------------|
/// | dev build  | `desktop/target/debug/app`    | `../../../webapp` (project root)          |
/// | production | `App.app/Contents/MacOS/app`  | `../Resources/_up_/webapp` (macOS bundle) |
///
/// WHY `_up_`: Tauri prefixes any resource path that starts with `../` with
/// `_up_` in the bundle to avoid escaping the `Resources/` directory.
pub(crate) fn find_rails_directory() -> Result<PathBuf, AppError> {
    let exe = std::env::current_exe().map_err(|_| AppError::RailsDirectoryNotFound)?;
    let exe_dir = exe.parent().ok_or(AppError::RailsDirectoryNotFound)?;

    let candidates: Vec<PathBuf> = if cfg!(debug_assertions) {
        vec![
            exe_dir.join("../../../webapp"), // desktop/target/debug → project root
            exe_dir.join("../../webapp"),
        ]
    } else {
        vec![
            exe_dir.join("../Resources/_up_/webapp"), // standard macOS bundle layout
            exe_dir.join("../Resources/webapp"),
            exe_dir.join("webapp"),
        ]
    };

    log::info!("Searching for Rails directory (exe: {:?})", exe);
    for path in candidates {
        let resolved = path.canonicalize().unwrap_or(path.clone());
        if resolved.join("Gemfile").exists() {
            log::info!("Found Rails directory at {:?}", resolved);
            return Ok(resolved);
        }
        log::info!("  not found: {:?}", resolved);
    }

    Err(AppError::RailsDirectoryNotFound)
}

/// Locates the bundled Ruby runtime inside the application bundle.
///
/// Only called in production builds.  In development the system Ruby on PATH
/// is used so developers can iterate without a full bundle.
pub(crate) fn find_bundled_ruby(rails_dir: &Path) -> Result<PathBuf, AppError> {
    let bundle_root = rails_dir.parent().ok_or(AppError::RubyNotBundled)?;
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    };

    log::info!("Looking for bundled Ruby (arch: {})", arch);

    // Tauri bundles ../webapp/** as _up_/webapp/, so:
    //   rails_dir  = Contents/Resources/_up_/webapp/
    //   bundle_root = Contents/Resources/_up_/
    //   bundle_root.parent() = Contents/Resources/      ← where our resources live
    //
    // resources/ruby-x86_64/** is bundled at Contents/Resources/resources/ruby-x86_64/
    let resource_dir = bundle_root.parent().unwrap_or(bundle_root);
    let candidates = [
        resource_dir.join("resources/ruby"), // production macOS bundle
        resource_dir.join(format!("resources/ruby-{}", arch)), // legacy arch-specific name
        bundle_root.join("resources/ruby"),  // fallback
        bundle_root.join(format!("resources/ruby-{}", arch)),
        bundle_root.join("ruby"),
    ];

    for path in &candidates {
        if path.join("bin/ruby").exists() {
            log::info!("Found bundled Ruby at {:?}", path);
            return Ok(path.clone());
        }
    }

    Err(AppError::RubyNotBundled)
}

/// Builds a minimal, isolated environment for production Ruby/Rails processes.
///
/// WHY: `env_clear()` + this map ensures child processes never inherit the
/// developer's PATH, RVM, rbenv, Homebrew, or system Ruby that could shadow
/// the bundled runtime or gem set.  Only paths we explicitly list are reachable.
pub(crate) fn build_ruby_env(rails_dir: &Path, ruby_dir: &Path) -> HashMap<String, String> {
    let mut env = HashMap::new();

    let bin = ruby_dir.join("bin");
    let lib = ruby_dir.join("lib");

    // PATH: bundled ruby bin + minimal system tools Rails needs internally.
    env.insert(
        "PATH".to_string(),
        format!("{}:/usr/bin:/bin", bin.display()),
    );

    // HOME: needed by Rails for temp files and asset cache paths.
    if let Ok(home) = std::env::var("HOME") {
        env.insert("HOME".to_string(), home);
    }

    env.insert(
        "TMPDIR".to_string(),
        std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".to_string()),
    );

    // RUBYLIB: belt-and-suspenders alongside --enable-load-relative.
    let abi = detect_ruby_abi(ruby_dir).unwrap_or_else(|| "4.0.0".to_string());
    let stdlib = ruby_dir.join(format!("lib/ruby/{}", abi));
    let mut rubylib = vec![stdlib.display().to_string()];
    if let Ok(entries) = std::fs::read_dir(&stdlib) {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if entry.path().is_dir()
                    && (name.starts_with("x86_64-darwin") || name.starts_with("aarch64-darwin"))
                {
                    rubylib.push(entry.path().display().to_string());
                }
            }
        }
    }
    env.insert("RUBYLIB".to_string(), rubylib.join(":"));

    // DYLD_LIBRARY_PATH: bundled lib dir only — resolves libruby.dylib and
    // the bundled Homebrew dylibs (libssl, libgmp, etc.).
    env.insert("DYLD_LIBRARY_PATH".to_string(), lib.display().to_string());

    // Gem / Bundler — vendor/bundle only, never system gems.
    let ruby_ver =
        find_vendor_bundle_ruby_version(rails_dir).unwrap_or_else(|| "4.0.0".to_string());
    let vendor_root = rails_dir.join("vendor/bundle");
    let vendor_ruby = vendor_root.join(format!("ruby/{}", ruby_ver));

    env.insert("GEM_HOME".to_string(), vendor_ruby.display().to_string());
    env.insert("GEM_PATH".to_string(), vendor_ruby.display().to_string());
    env.insert(
        "BUNDLE_GEMFILE".to_string(),
        rails_dir.join("Gemfile").display().to_string(),
    );
    env.insert("BUNDLE_PATH".to_string(), vendor_root.display().to_string());
    env.insert("BUNDLE_DEPLOYMENT".to_string(), "true".to_string());
    env.insert(
        "BUNDLE_WITHOUT".to_string(),
        "development:test:desktop".to_string(),
    );

    // Rails / app env.
    env.insert("RAILS_ENV".to_string(), "desktop".to_string());
    env.insert("DESKTOP_MODE".to_string(), "true".to_string());
    env.insert("RUBYOPT".to_string(), "-W0".to_string());
    env.insert("LANG".to_string(), "en_US.UTF-8".to_string());


    env
}

/// Builds a `Command` for a Rails task, configured for the current build mode.
///
/// - **Dev** (`debug_assertions`): inherits the shell environment, uses `ruby`
///   from PATH.  Fast inner loop — no bundle required.
/// - **Prod**: uses the bundled Ruby with `env_clear()` + an isolated env map.
pub(crate) fn build_rails_command(rails_dir: &Path, args: &[&str]) -> Result<Command, AppError> {
    let rails_bin = rails_dir.join("bin/rails");

    if cfg!(debug_assertions) {
        let mut cmd = Command::new("ruby");
        cmd.arg(&rails_bin);
        cmd.args(args);
        cmd.current_dir(rails_dir);
        cmd.env("RAILS_ENV", "desktop");
        cmd.stdout(Stdio::inherit());
        cmd.stderr(Stdio::inherit());
        Ok(cmd)
    } else {
        let ruby_dir = find_bundled_ruby(rails_dir)?;
        let env = build_ruby_env(rails_dir, &ruby_dir);
        let mut cmd = Command::new(ruby_dir.join("bin/ruby"));
        cmd.arg(&rails_bin);
        cmd.args(args);
        cmd.current_dir(rails_dir);
        cmd.env_clear();
        cmd.envs(env);
        cmd.stdout(Stdio::inherit());
        cmd.stderr(Stdio::inherit());
        Ok(cmd)
    }
}

/// Detects the Ruby ABI version string from `lib/ruby/<version>/`.
/// e.g. returns `"4.0.0"` when `lib/ruby/4.0.0/` exists.
fn detect_ruby_abi(ruby_dir: &Path) -> Option<String> {
    std::fs::read_dir(ruby_dir.join("lib/ruby"))
        .ok()?
        .flatten()
        .find(|e| {
            e.path().is_dir()
                && e.file_name()
                    .to_str()
                    .is_some_and(|n| n.chars().next().is_some_and(|c| c.is_ascii_digit()))
        })
        .and_then(|e| e.file_name().to_str().map(str::to_owned))
}

/// Detects the Ruby ABI directory name inside `vendor/bundle/ruby/`.
fn find_vendor_bundle_ruby_version(rails_dir: &Path) -> Option<String> {
    std::fs::read_dir(rails_dir.join("vendor/bundle/ruby"))
        .ok()?
        .flatten()
        .find(|e| e.path().is_dir())
        .and_then(|e| e.file_name().to_str().map(str::to_owned))
}
