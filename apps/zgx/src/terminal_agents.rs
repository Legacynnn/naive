use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    sync::OnceLock,
    time::Duration,
};

use zgx_script::{ScriptHost, Value};

pub fn install(host: &ScriptHost) {
    host.async_action("terminal_agents.detect", |arg| async move {
        let bins: Vec<String> = match arg.field("bins") {
            Some(Value::List(list)) => list.iter().map(crate::auth::text).filter(|b| valid(b)).collect(),
            _ => Vec::new(),
        };
        let found = off_thread(move || {
            let dirs = search_dirs();
            bins.into_iter()
                .filter_map(|bin| find(&dirs, &bin).map(|path| (bin, path.to_string_lossy().into_owned())))
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        Ok(Value::record(found.iter().map(|(bin, path)| (bin.as_str(), Value::from(path.as_str())))))
    });
}

async fn off_thread<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    let (tx, mut rx) = zgx::task::latest();
    std::thread::spawn(move || {
        tx.send(work());
    });
    rx.recv().await
}

fn valid(bin: &str) -> bool {
    !bin.is_empty() && bin.len() < 64 && bin.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

fn find(dirs: &[PathBuf], bin: &str) -> Option<PathBuf> {
    dirs.iter().map(|dir| dir.join(exe_name(bin))).find(|path| runnable(path))
}

#[cfg(windows)]
fn exe_name(bin: &str) -> String {
    format!("{bin}.exe")
}

#[cfg(not(windows))]
fn exe_name(bin: &str) -> String {
    bin.to_owned()
}

#[cfg(unix)]
fn runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn runnable(path: &Path) -> bool {
    path.is_file()
}

fn search_dirs() -> Vec<PathBuf> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    let mut add = |dir: PathBuf| {
        if seen.insert(dir.clone()) {
            out.push(dir);
        }
    };
    for path in [login_path().map(str::to_owned), std::env::var("PATH").ok()].into_iter().flatten() {
        for dir in std::env::split_paths(&path) {
            add(dir);
        }
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        for rel in [".local/bin", ".bun/bin", ".npm-global/bin", ".cargo/bin", ".volta/bin", ".deno/bin", ".amp/bin", ".opencode/bin", "go/bin", "bin"] {
            add(home.join(rel));
        }
    }
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        add(PathBuf::from(dir));
    }
    out
}

fn login_path() -> Option<&'static str> {
    static PATH: OnceLock<Option<String>> = OnceLock::new();
    PATH.get_or_init(ask_login_path).as_deref()
}

#[cfg(unix)]
fn ask_login_path() -> Option<String> {
    use std::{io::Read, process::Stdio};
    let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into());
    let mut child = std::process::Command::new(shell)
        .args(["-l", "-c", "printenv PATH"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        let _ = tx.send(text);
    });
    let text = rx.recv_timeout(Duration::from_secs(4)).ok();
    let _ = child.kill();
    let _ = child.wait();
    text.and_then(|t| t.lines().rev().find(|l| l.contains('/')).map(str::to_owned))
}

#[cfg(not(unix))]
fn ask_login_path() -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_plain_names_are_looked_up() {
        assert!(valid("claude"));
        assert!(valid("cursor-agent"));
        assert!(!valid("../bin/sh"));
        assert!(!valid("a b"));
        assert!(!valid(""));
    }
}
