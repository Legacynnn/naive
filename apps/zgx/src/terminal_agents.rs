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
    host.async_action("terminal_agents.prepare", |_arg| async move {
        let paths = off_thread(prepare).await.ok_or("hooks didn't write")??;
        Ok(Value::record([("claude_settings", Value::from(paths.to_string_lossy().as_ref()))]))
    });
    host.async_action("terminal_agents.codex_hooks", |arg| async move {
        let want = match arg.field("on") {
            Some(Value::Bool(on)) => Some(*on),
            _ => None,
        };
        let on = off_thread(move || codex_hooks(codex_hooks_file(), want)).await.ok_or("hooks didn't write")??;
        Ok(Value::Bool(on))
    });
}

const HOOK_SCRIPT: &str = r#"#!/bin/sh
case "$NAIVE_ORIGIN" in terminal:*) ;; *) exit 0 ;; esac
agent="$1"
event="$2"
case "$event" in
  UserPromptSubmit|PreToolUse|PostToolUse) state="state=working" ;;
  PermissionRequest) state="state=blocked:kind=permission" ;;
  Notification)
    case "$(cat)" in
      *permission_prompt*) state="state=blocked:kind=permission" ;;
      *elicitation_dialog*) state="state=blocked:kind=question" ;;
      *) exit 0 ;;
    esac ;;
  Stop) state="state=done" ;;
  StopFailure) state="state=error" ;;
  SessionEnd) state="state=clear" ;;
  *) exit 0 ;;
esac
pid=$PPID
i=0
while [ "$i" -lt 6 ] && [ -n "$pid" ] && [ "$pid" != 1 ]; do
  t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$t" in
    ''|'?'|'??') pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') ;;
    *) printf '\033]7501;%s:id=naive-hook:app=%s\007' "$state" "$agent" > "/dev/$t" 2>/dev/null; exit 0 ;;
  esac
  i=$((i + 1))
done
exit 0
"#;

const CLAUDE_EVENTS: &[&str] = &["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"];
const CODEX_EVENTS: &[&str] = &["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"];
const MARKER: &str = ".naive/agent-hooks/terminal-hook.sh";

fn hooks_dir() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(std::env::temp_dir).join(".naive").join("agent-hooks")
}

fn script_path() -> PathBuf {
    hooks_dir().join("terminal-hook.sh")
}

fn hook_command(agent: &str, event: &str) -> String {
    let script = script_path().to_string_lossy().replace('\'', "'\\''");
    format!("if [ -f '{script}' ]; then sh '{script}' {agent} {event}; fi")
}

fn hook_entry(agent: &str, event: &str) -> serde_json::Value {
    serde_json::json!({ "matcher": "", "hooks": [{ "type": "command", "command": hook_command(agent, event), "timeout": 10 }] })
}

fn write_if_changed(path: &Path, text: &str) -> Result<(), String> {
    if std::fs::read_to_string(path).is_ok_and(|now| now == text) {
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("naive-tmp");
    std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn write_script() -> Result<(), String> {
    let path = script_path();
    write_if_changed(&path, HOOK_SCRIPT)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn prepare() -> Result<PathBuf, String> {
    write_script()?;
    let mut hooks = serde_json::Map::new();
    for event in CLAUDE_EVENTS {
        hooks.insert((*event).to_owned(), serde_json::Value::Array(vec![hook_entry("claude", event)]));
    }
    let settings = serde_json::json!({ "hooks": hooks });
    let path = hooks_dir().join("claude-settings.json");
    write_if_changed(&path, &format!("{}\n", serde_json::to_string_pretty(&settings).unwrap_or_default()))?;
    Ok(path)
}

fn codex_hooks_file() -> PathBuf {
    std::env::var_os("CODEX_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".codex")))
        .unwrap_or_else(|| PathBuf::from(".codex"))
        .join("hooks.json")
}

fn ours(entry: &serde_json::Value) -> bool {
    entry["hooks"].as_array().is_some_and(|hooks| hooks.iter().any(|h| h["command"].as_str().is_some_and(|c| c.contains(MARKER))))
}

fn codex_hooks(path: PathBuf, want: Option<bool>) -> Result<bool, String> {
    let raw = std::fs::read_to_string(&path).ok();
    let mut config: serde_json::Value = match raw.as_deref() {
        Some(text) if !text.trim().is_empty() => serde_json::from_str(text).map_err(|e| format!("{}: {e}", path.display()))?,
        _ => serde_json::json!({}),
    };
    let installed = CODEX_EVENTS.iter().all(|event| config["hooks"][*event].as_array().is_some_and(|list| list.iter().any(ours)));
    let Some(on) = want else {
        return Ok(installed);
    };
    if on {
        write_script()?;
    }
    if !config.is_object() {
        config = serde_json::json!({});
    }
    if !config["hooks"].is_object() {
        config["hooks"] = serde_json::json!({});
    }
    let hooks = config["hooks"].as_object_mut().ok_or("hooks isn't an object")?;
    for event in CODEX_EVENTS {
        let mut list: Vec<serde_json::Value> = hooks.get(*event).and_then(|v| v.as_array()).cloned().unwrap_or_default();
        list.retain(|entry| !ours(entry));
        if on {
            list.push(hook_entry("codex", event));
        }
        if list.is_empty() {
            hooks.remove(*event);
        } else {
            hooks.insert((*event).to_owned(), serde_json::Value::Array(list));
        }
    }
    if raw.is_none() && !on {
        return Ok(false);
    }
    write_if_changed(&path, &format!("{}\n", serde_json::to_string_pretty(&config).map_err(|e| e.to_string())?))?;
    Ok(on)
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

    #[test]
    fn codex_hooks_go_in_beside_others_and_come_out_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hooks.json");
        let theirs = serde_json::json!({ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "other-tool hook" }] }] } });
        std::fs::write(&path, theirs.to_string()).unwrap();
        assert!(!codex_hooks(path.clone(), None).unwrap());
        assert!(codex_hooks(path.clone(), Some(true)).unwrap());
        assert!(codex_hooks(path.clone(), None).unwrap());
        assert!(codex_hooks(path.clone(), Some(true)).unwrap());
        let on: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(on["hooks"]["Stop"].as_array().unwrap().len(), 2);
        assert_eq!(on["hooks"]["PermissionRequest"].as_array().unwrap().len(), 1);
        assert!(!codex_hooks(path.clone(), Some(false)).unwrap());
        let off: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(off, theirs);
    }

    #[test]
    fn no_codex_file_is_left_alone_when_turned_off() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hooks.json");
        assert!(!codex_hooks(path.clone(), Some(false)).unwrap());
        assert!(!path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn the_hook_reports_to_its_agents_terminal_and_only_in_naives() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("hook.sh");
        std::fs::write(&script, HOOK_SCRIPT).unwrap();
        let status = std::process::Command::new("sh").arg("-n").arg(&script).status().unwrap();
        assert!(status.success());
        let quiet = std::process::Command::new("sh").arg(&script).args(["claude", "Stop"]).env_remove("NAIVE_ORIGIN").output().unwrap();
        assert!(quiet.status.success());
        assert!(quiet.stdout.is_empty());
    }
}
