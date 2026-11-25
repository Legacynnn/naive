use naive_rpc::{RpcError, methods};
use serde_json::{Value, json};

use super::{ToolDef, Tools};

pub(super) const TABS: &str = "browser_tabs";
pub(super) const NAVIGATE: &str = "browser_navigate";
pub(super) const SNAPSHOT: &str = "browser_snapshot";
pub(super) const CLICK: &str = "browser_click";
pub(super) const TYPE: &str = "browser_type";
pub(super) const KEY: &str = "browser_key";
pub(super) const SCROLL: &str = "browser_scroll";
pub(super) const SCREENSHOT: &str = "browser_screenshot";
pub(super) const CONSOLE: &str = "browser_console";
pub(super) const WAIT: &str = "browser_wait";

const MAX_PICTURE: usize = 3_500_000;

pub(super) const NAMES: [&str; 10] = [
    TABS, NAVIGATE, SNAPSHOT, CLICK, TYPE, KEY, SCROLL, SCREENSHOT, CONSOLE, WAIT,
];

fn tab() -> Value {
    json!({ "type": "string", "description": "Tab id from browser_tabs. Omit for this chat's active browser tab." })
}

fn element() -> Value {
    json!({ "type": "string", "description": "An element's ref from the latest browser_snapshot (e.g. \"e12\")." })
}

fn schema(properties: Value, required: &[&str]) -> Value {
    json!({ "type": "object", "properties": properties, "required": required })
}

pub(super) fn catalog() -> Vec<ToolDef> {
    vec![
        ToolDef {
            name: TABS,
            description: "The browser tabs in this chat's panel in Naive's window, which the person sees. action: \"list\" (default), \"open\" (a new tab, at `url` if given), \"select\" or \"close\" (`tab`). Browser tools need Naive open on this device and a chat with full access.",
            input_schema: schema(
                json!({
                    "action": { "type": "string", "enum": ["list", "open", "select", "close"] },
                    "tab": tab(),
                    "url": { "type": "string" }
                }),
                &[],
            ),
        },
        ToolDef {
            name: NAVIGATE,
            description: "Go to `url` in a browser tab (a new one if this chat has none), or \"back\", \"forward\", \"reload\". Waits for the load, then answers the page's url and title.",
            input_schema: schema(
                json!({
                    "url": { "type": "string", "description": "An http(s) address, or back / forward / reload." },
                    "tab": tab()
                }),
                &["url"],
            ),
        },
        ToolDef {
            name: SNAPSHOT,
            description: "The page as an accessibility tree: each interactive or landmark element on one line with its role, name, state and a ref (e.g. [e12]). Act on elements by ref with browser_click and browser_type. Take a new snapshot after the page changes: refs from an older one may be gone.",
            input_schema: schema(json!({ "tab": tab() }), &[]),
        },
        ToolDef {
            name: CLICK,
            description: "Click an element by its ref from browser_snapshot.",
            input_schema: schema(
                json!({
                    "ref": element(),
                    "tab": tab(),
                    "double": { "type": "boolean" }
                }),
                &["ref"],
            ),
        },
        ToolDef {
            name: TYPE,
            description: "Type `text` into an input, textarea or editable element by ref. Replaces what's there unless `append`. `submit` presses Enter after.",
            input_schema: schema(
                json!({
                    "ref": element(),
                    "text": { "type": "string" },
                    "append": { "type": "boolean" },
                    "submit": { "type": "boolean" },
                    "tab": tab()
                }),
                &["ref", "text"],
            ),
        },
        ToolDef {
            name: KEY,
            description: "Press a key on the focused element (or `ref`'s): Enter, Escape, Tab, ArrowDown, Backspace, a letter. Modifiers as \"Control+a\", \"Shift+Tab\".",
            input_schema: schema(
                json!({
                    "key": { "type": "string" },
                    "ref": element(),
                    "tab": tab()
                }),
                &["key"],
            ),
        },
        ToolDef {
            name: SCROLL,
            description: "Scroll the page (or the element `ref` into view). direction: up, down, top, bottom; `amount` in pixels (default one screen).",
            input_schema: schema(
                json!({
                    "direction": { "type": "string", "enum": ["up", "down", "top", "bottom"] },
                    "amount": { "type": "number" },
                    "ref": element(),
                    "tab": tab()
                }),
                &[],
            ),
        },
        ToolDef {
            name: SCREENSHOT,
            description: "A picture of the tab's page as it shows in Naive (its visible area); the panel opens to show it. Act on what's there through browser_snapshot's refs.",
            input_schema: schema(json!({ "tab": tab() }), &[]),
        },
        ToolDef {
            name: CONSOLE,
            description: "The page's recent console messages and uncaught errors, oldest first, since Naive first reached the page (browser_navigate hooks the console as the load finishes, so messages logged during the load itself aren't seen). `clear` empties them after reading.",
            input_schema: schema(
                json!({
                    "tab": tab(),
                    "clear": { "type": "boolean" }
                }),
                &[],
            ),
        },
        ToolDef {
            name: WAIT,
            description: "Wait until `text` shows on the page, `selector` matches, or the page finishes loading (neither given). Up to `timeout` ms (default 10000, at most 30000).",
            input_schema: schema(
                json!({
                    "text": { "type": "string" },
                    "selector": { "type": "string" },
                    "timeout": { "type": "number" },
                    "tab": tab()
                }),
                &[],
            ),
        },
    ]
}

impl Tools {
    pub(super) async fn browser(&self, name: &str, args: Value) -> Result<Value, String> {
        let mut params = json!({ "tool": name, "args": args });
        if let Some(chat) = &self.naive.origin().chat_id {
            params["chatId"] = json!(chat);
        }
        let reply = self
            .naive
            .call_rpc(methods::CALL_BROWSER_TOOL, params)
            .await
            .map_err(|error| match error {
                RpcError::Failed(message) => message,
                RpcError::UnknownMethod(_) => {
                    "This Naive can't drive its browser yet; update Naive.".into()
                }
                other => other.to_string(),
            })?;
        let mut value = reply.get("value").cloned().unwrap_or(Value::Null);
        let picture = value.as_object_mut().and_then(|o| {
            o.remove("mcpImage");
            o.remove("jpeg")
        });
        if name == SCREENSHOT {
            let Some(Value::String(jpeg)) = picture else {
                return Err("The browser gave no picture".into());
            };
            if jpeg.len() > MAX_PICTURE {
                return Err(format!(
                    "The page's picture is too big to send ({} KB); use browser_snapshot",
                    jpeg.len() / 1024
                ));
            }
            value["mcpImage"] = json!({ "data": jpeg, "mimeType": "image/jpeg" });
        }
        Ok(value)
    }
}
