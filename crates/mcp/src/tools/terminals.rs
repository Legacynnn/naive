use std::time::{Duration, Instant};

use naive_rpc::{RpcError, methods};
use serde_json::{Value, json};

use super::{ToolDef, Tools};

pub(super) const OPEN: &str = "terminal_open";
pub(super) const READ: &str = "terminal_read";
pub(super) const WRITE: &str = "terminal_write";
pub(super) const LIST: &str = "terminal_list";
pub(super) const CLOSE: &str = "terminal_close";

pub(super) const NAMES: [&str; 5] = [OPEN, READ, WRITE, LIST, CLOSE];

const QUIET_MS: u64 = 1500;
const SETTLED_MS: u64 = 400;
const MAX_WAIT_SECS: u64 = 120;

fn terminal() -> Value {
    json!({ "type": "string", "description": "The terminal's id, from terminal_open or terminal_list." })
}

fn wait() -> Value {
    json!({ "type": "integer", "minimum": 0, "maximum": MAX_WAIT_SECS, "description": "Seconds to wait at most before reading (see `until`). Default 0: read now." })
}

fn until() -> Value {
    json!({ "type": "string", "enum": ["finished", "quiet"], "default": "finished", "description": "What `wait_secs` waits for: \"finished\" (no program running in the terminal any more, back at the shell prompt) or \"quiet\" (1.5 s with no new output: for a dev server or watcher that keeps running once it's up)." })
}

fn key_bytes(key: &str) -> Result<String, String> {
    let k = key.trim().to_ascii_lowercase().replace('-', "+");
    let named = match k.as_str() {
        "enter" | "return" => "\r",
        "tab" => "\t",
        "shift+tab" => "\u{1b}[Z",
        "escape" | "esc" => "\u{1b}",
        "backspace" => "\u{7f}",
        "delete" => "\u{1b}[3~",
        "up" => "\u{1b}[A",
        "down" => "\u{1b}[B",
        "right" => "\u{1b}[C",
        "left" => "\u{1b}[D",
        "home" => "\u{1b}[H",
        "end" => "\u{1b}[F",
        "pageup" => "\u{1b}[5~",
        "pagedown" => "\u{1b}[6~",
        "space" => " ",
        _ => "",
    };
    if !named.is_empty() {
        return Ok(named.to_owned());
    }
    if let Some(letter) = k.strip_prefix("ctrl+").filter(|l| l.len() == 1) {
        let c = letter.as_bytes()[0];
        let code = match c {
            b'a'..=b'z' => c - b'a' + 1,
            b'[' => 27,
            b'\\' => 28,
            b']' => 29,
            _ => return Err(format!("No control key {key}")),
        };
        return Ok((code as char).to_string());
    }
    Err(format!(
        "Unknown key {key}: use enter, tab, shift+tab, esc, backspace, delete, up, down, left, right, home, end, pageup, pagedown, space, or ctrl+<letter>"
    ))
}

pub(super) fn catalog() -> Vec<ToolDef> {
    vec![
        ToolDef {
            name: OPEN,
            description: "Open a terminal tab in this chat's panel in Naive's window, where the person sees it and can type in it too, and run `command` in it (in your chat's folder unless `cwd`). Use it whenever the person asks you to run something they'll want to watch or keep: dev servers, watchers, builds, test runs, scripts, REPLs, anything interactive. Prefer it to your own shell tool for those; keep your own shell for quick checks you only read yourself. Read what it prints with terminal_read, type into it with terminal_write. Only a chat with full access may use it.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "What to run, as typed in a terminal. Omit for a bare shell." },
                    "cwd": { "type": "string", "description": "Folder to start in. Defaults to the chat's folder." },
                    "title": { "type": "string", "description": "The tab's title. Defaults to what the shell calls itself." },
                    "wait_secs": wait(),
                    "until": until()
                }
            }),
        },
        ToolDef {
            name: READ,
            description: "What a terminal printed, as plain text (its last 16 KiB by default), and whether a program is `running` in it, it `exited` (with `exitCode`), and `quietMs` since its last output. Pass the `cursor` a read returned as `since` to get only what came after.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "terminal": terminal(),
                    "since": { "type": "integer", "minimum": 0, "description": "A previous read's cursor." },
                    "max_bytes": { "type": "integer", "minimum": 256, "maximum": 65536 },
                    "wait_secs": wait(),
                    "until": until()
                },
                "required": ["terminal"]
            }),
        },
        ToolDef {
            name: WRITE,
            description: "Type into a terminal: `input` is text (a command, an answer to a prompt), Enter pressed after unless `enter` is false; `keys` are keys pressed after it, in order, e.g. [\"ctrl+c\"] to interrupt, [\"up\", \"enter\"], [\"ctrl+d\"]. Give `input`, `keys`, or both.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "terminal": terminal(),
                    "input": { "type": "string" },
                    "enter": { "type": "boolean", "default": true },
                    "keys": { "type": "array", "items": { "type": "string" }, "description": "Keys to press: enter, tab, shift+tab, esc, backspace, delete, up, down, left, right, home, end, pageup, pagedown, space, ctrl+<letter>." },
                    "wait_secs": wait(),
                    "until": until()
                },
                "required": ["terminal"]
            }),
        },
        ToolDef {
            name: LIST,
            description: "This chat's terminals: each one's id and whether a program is running in it.",
            input_schema: json!({ "type": "object", "properties": {} }),
        },
        ToolDef {
            name: CLOSE,
            description: "Close a terminal and end what runs in it.",
            input_schema: json!({ "type": "object", "properties": { "terminal": terminal() }, "required": ["terminal"] }),
        },
    ]
}

fn plain(error: RpcError) -> String {
    match error {
        RpcError::Failed(message) => message,
        RpcError::UnknownMethod(_) => {
            "This Naive can't open terminals for agents yet; update Naive.".into()
        }
        other => other.to_string(),
    }
}

fn quiet_only(args: &Value) -> bool {
    args.get("until").and_then(Value::as_str) == Some("quiet")
}

fn wait_secs(args: &Value) -> u64 {
    args.get("wait_secs")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .min(MAX_WAIT_SECS)
}

impl Tools {
    async fn terminal_rpc(&self, method: &str, mut params: Value) -> Result<Value, String> {
        if let Some(chat) = &self.naive.origin().chat_id {
            params["chatId"] = json!(chat);
        }
        self.naive.call_rpc(method, params).await.map_err(plain)
    }

    async fn read_after_wait(
        &self,
        terminal: &str,
        since: Option<u64>,
        max_bytes: Option<u64>,
        wait: u64,
        quiet_only: bool,
    ) -> Result<Value, String> {
        let params = json!({ "terminalId": terminal, "after": since, "maxBytes": max_bytes });
        let deadline = Instant::now() + Duration::from_secs(wait);
        loop {
            let read = self
                .terminal_rpc(methods::AGENT_READ_TERMINAL, params.clone())
                .await?;
            let exited = read["exited"].as_bool().unwrap_or(false);
            let running = read["running"].as_bool().unwrap_or(false);
            let quiet_ms = read["quietMs"].as_u64().unwrap_or(0);
            let ready = if quiet_only {
                quiet_ms >= QUIET_MS
            } else {
                !running && quiet_ms >= SETTLED_MS
            };
            if wait == 0 || exited || ready || Instant::now() >= deadline {
                let mut read = read;
                if wait > 0 && !exited && !ready {
                    read["waitedOut"] = json!(true);
                }
                return Ok(read);
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }

    pub(super) async fn terminals(&self, name: &str, args: Value) -> Result<Value, String> {
        let terminal = args
            .get("terminal")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        match name {
            OPEN => {
                let opened = self
                    .terminal_rpc(
                        methods::AGENT_OPEN_TERMINAL,
                        json!({ "command": args.get("command"), "cwd": args.get("cwd") }),
                    )
                    .await?;
                let id = opened["terminalId"].as_str().unwrap_or_default().to_owned();
                let shown = self
                    .browser(
                        "terminal_show",
                        json!({ "terminal": id, "title": args.get("title") }),
                    )
                    .await;
                let mut reply = json!({ "terminal": id, "cwd": opened["cwd"] });
                if let Err(why) = shown {
                    reply["shown"] = json!(false);
                    reply["note"] = json!(format!("It runs, but isn't showing in Naive: {why}"));
                }
                let wait = wait_secs(&args);
                if wait > 0 {
                    tokio::time::sleep(Duration::from_millis(800)).await;
                    reply["read"] = self
                        .read_after_wait(&id, None, None, wait, quiet_only(&args))
                        .await?;
                }
                Ok(reply)
            }
            READ => {
                self.read_after_wait(
                    &terminal,
                    args.get("since").and_then(Value::as_u64),
                    args.get("max_bytes").and_then(Value::as_u64),
                    wait_secs(&args),
                    quiet_only(&args),
                )
                .await
            }
            WRITE => {
                let before = self
                    .terminal_rpc(
                        methods::AGENT_READ_TERMINAL,
                        json!({ "terminalId": terminal, "maxBytes": 256 }),
                    )
                    .await?;
                let text = args
                    .get("input")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let mut input = text.to_owned();
                if !text.is_empty() && args.get("enter").and_then(Value::as_bool).unwrap_or(true) {
                    input.push('\r');
                }
                for key in args
                    .get("keys")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    input.push_str(&key_bytes(key.as_str().unwrap_or_default())?);
                }
                if input.is_empty() {
                    return Err("Nothing to type: give `input` or `keys`".into());
                }
                self.terminal_rpc(
                    methods::AGENT_WRITE_TERMINAL,
                    json!({ "terminalId": terminal, "input": input, "enter": false }),
                )
                .await?;
                let wait = wait_secs(&args);
                if wait == 0 {
                    return Ok(json!({ "cursor": before["cursor"] }));
                }
                tokio::time::sleep(Duration::from_millis(300)).await;
                self.read_after_wait(
                    &terminal,
                    before["cursor"].as_u64(),
                    None,
                    wait,
                    quiet_only(&args),
                )
                .await
            }
            LIST => {
                self.terminal_rpc(methods::AGENT_LIST_TERMINALS, json!({}))
                    .await
            }
            _ => {
                self.terminal_rpc(
                    methods::AGENT_CLOSE_TERMINAL,
                    json!({ "terminalId": terminal }),
                )
                .await
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::key_bytes;

    #[test]
    fn keys_become_the_bytes_a_terminal_reads() {
        assert_eq!(key_bytes("ctrl+c").unwrap(), "\u{3}");
        assert_eq!(key_bytes("Ctrl-D").unwrap(), "\u{4}");
        assert_eq!(key_bytes("up").unwrap(), "\u{1b}[A");
        assert_eq!(key_bytes("enter").unwrap(), "\r");
        assert!(key_bytes("ctrl+1").is_err());
        assert!(key_bytes("hyper").is_err());
    }
}
