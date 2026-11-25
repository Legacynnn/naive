use base64::Engine as _;
use naive_proto::TerminalEvent;
use naive_rpc::{RpcError, RpcReply, methods, parse_params};
use serde::Deserialize;
use serde_json::{Value, json};

use super::EngineRpc;

const COLS: u16 = 120;
const ROWS: u16 = 32;
const DEFAULT_READ: usize = 16 * 1024;
const MAX_READ: usize = 64 * 1024;

pub(super) fn handles(method: &str) -> bool {
    matches!(
        method,
        methods::AGENT_OPEN_TERMINAL
            | methods::AGENT_READ_TERMINAL
            | methods::AGENT_WRITE_TERMINAL
            | methods::AGENT_LIST_TERMINALS
            | methods::AGENT_CLOSE_TERMINAL
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenParams {
    chat_id: String,
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TerminalParams {
    chat_id: String,
    terminal_id: String,
    #[serde(default)]
    after: Option<u64>,
    #[serde(default)]
    max_bytes: Option<usize>,
    #[serde(default)]
    input: Option<String>,
    #[serde(default)]
    enter: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatParams {
    chat_id: String,
}

fn failed(error: impl std::fmt::Display) -> RpcError {
    RpcError::Failed(error.to_string())
}

impl EngineRpc {
    pub(super) async fn agent_terminal(
        &self,
        method: &str,
        params: Value,
    ) -> Result<RpcReply, RpcError> {
        match method {
            methods::AGENT_OPEN_TERMINAL => {
                let p: OpenParams = parse_params(params)?;
                let chat = self
                    .workspace
                    .chat(&p.chat_id)
                    .ok()
                    .flatten()
                    .filter(|chat| chat.device_id == self.doc_host.device_id())
                    .ok_or_else(|| {
                        failed("This chat doesn't run on this device, so it has no terminal here")
                    })?;
                let cwd = super::resolve_open_terminal_cwd(
                    p.cwd,
                    chat.cwd.clone(),
                    None,
                    &self.repos.scratch_root(),
                )
                .map_err(failed)?;
                let session = self.terminals.open(&cwd, COLS, ROWS).map_err(failed)?;
                self.terminals
                    .associate_chat(&session.id, &p.chat_id)
                    .map_err(failed)?;
                if let Some(command) = p.command.filter(|c| !c.trim().is_empty()) {
                    self.terminals
                        .write_bytes(&session.id, format!("{command}\r").as_bytes())
                        .map_err(failed)?;
                }
                RpcReply::value(
                    &json!({ "terminalId": session.id, "cwd": session.cwd, "shell": session.shell }),
                )
            }
            methods::AGENT_LIST_TERMINALS => {
                let p: ChatParams = parse_params(params)?;
                let mut out = Vec::new();
                for (terminal, chat) in self.terminals.chats() {
                    if chat != p.chat_id {
                        continue;
                    }
                    if let Ok(status) = self.terminals.status(&terminal) {
                        out.push(json!({ "terminalId": terminal, "busy": status.busy, "exited": status.exited }));
                    }
                }
                RpcReply::value(&json!({ "terminals": out }))
            }
            _ => {
                let p: TerminalParams = parse_params(params)?;
                if self.terminals.chats().get(&p.terminal_id) != Some(&p.chat_id) {
                    return Err(failed(
                        "No terminal of this chat has that id: terminal_list lists them",
                    ));
                }
                match method {
                    methods::AGENT_WRITE_TERMINAL => {
                        let mut input = p.input.unwrap_or_default();
                        if p.enter.unwrap_or(true) {
                            input.push('\r');
                        }
                        self.terminals
                            .write_bytes(&p.terminal_id, input.as_bytes())
                            .map_err(failed)?;
                        RpcReply::value(&json!({}))
                    }
                    methods::AGENT_CLOSE_TERMINAL => {
                        self.terminals.close(&p.terminal_id).map_err(failed)?;
                        RpcReply::value(&json!({}))
                    }
                    _ => self.read_terminal(&p),
                }
            }
        }
    }

    fn read_terminal(&self, p: &TerminalParams) -> Result<RpcReply, RpcError> {
        let limit = p.max_bytes.unwrap_or(DEFAULT_READ).clamp(256, MAX_READ);
        let mut rx = self
            .terminals
            .subscribe_viewer(&p.terminal_id, p.after, false)
            .map_err(failed)?;
        let mut bytes = Vec::new();
        let mut cursor = p.after.unwrap_or(0);
        let mut exit = None;
        while let Ok(event) = rx.try_recv() {
            match event {
                TerminalEvent::Data { seq, data } => {
                    cursor = cursor.max(seq);
                    if let Ok(chunk) = base64::engine::general_purpose::STANDARD.decode(data) {
                        bytes.extend_from_slice(&chunk);
                    }
                }
                TerminalEvent::Exit { seq, exit_code, .. } => {
                    cursor = cursor.max(seq);
                    exit = Some(exit_code);
                }
            }
        }
        drop(rx);
        let omitted = bytes.len().saturating_sub(limit);
        let text = plain(&String::from_utf8_lossy(&bytes[omitted..]));
        let status = self.terminals.status(&p.terminal_id).ok();
        RpcReply::value(&json!({
            "output": text,
            "cursor": cursor,
            "omittedBytes": omitted,
            "running": status.as_ref().is_some_and(|s| s.busy),
            "exited": exit.is_some() || status.as_ref().is_none_or(|s| s.exited),
            "exitCode": exit,
            "quietMs": status.and_then(|s| s.quiet_ms),
        }))
    }
}

/// Terminal output as text: escape sequences dropped, carriage-return redraws collapsed.
fn plain(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                Some('[') => {
                    while let Some(&n) = chars.peek() {
                        chars.next();
                        if ('@'..='~').contains(&n) {
                            break;
                        }
                    }
                }
                Some(']') | Some('P') | Some('_') | Some('^') => {
                    while let Some(n) = chars.next() {
                        if n == '\u{7}' {
                            break;
                        }
                        if n == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {}
            },
            '\u{8}' => {
                out.pop();
            }
            c if c.is_control() && c != '\n' && c != '\r' && c != '\t' => {}
            c => out.push(c),
        }
    }
    out.split('\n')
        .map(|line| {
            let line = line.strip_suffix('\r').unwrap_or(line);
            line.rsplit('\r').next().unwrap_or(line)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::plain;

    #[test]
    fn terminal_output_reads_as_plain_text() {
        assert_eq!(plain("\u{1b}[1;32mok\u{1b}[0m\r\n"), "ok\n");
        assert_eq!(plain("\u{1b}]0;title\u{7}$ ls\r\n"), "$ ls\n");
        assert_eq!(plain("10%\r50%\r100%\r\ndone"), "100%\ndone");
        assert_eq!(plain("abc\u{8}d"), "abd");
    }
}
