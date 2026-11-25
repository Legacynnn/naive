use serde_json::{Value as Json, json};
use std::{cell::RefCell, rc::Rc};
use zgx_script::{ScriptHost, Shared, Value};

use crate::engine::{self, rpc::Watch};
use crate::plugins::{json_value, value_json};

#[derive(Default)]
struct Calls {
    shared: RefCell<Vec<Shared>>,
    pending: RefCell<Vec<Value>>,
    watch: RefCell<Option<Watch>>,
    listening: std::cell::Cell<bool>,
}

thread_local! {
    static CALLS: Rc<Calls> = Rc::new(Calls::default());
}

pub fn install(host: &ScriptHost) {
    if let Some(agent) = safari_user_agent() {
        host.shared("browser.user_agent", agent.as_str());
    }
    let c = CALLS.with(Rc::clone);
    c.shared
        .borrow_mut()
        .push(host.shared("browser_agent_calls", list(&c.pending.borrow())));
    if !c.listening.replace(true) {
        let weak = Rc::downgrade(&c);
        engine::get().on_connect(move |rpc| {
            let Some(c) = weak.upgrade() else { return };
            c.pending.borrow_mut().clear();
            c.publish();
            let me = Rc::downgrade(&c);
            let watch = rpc.watch("ServeBrowserTools", json!({}), move |call| {
                if let Some(c) = me.upgrade() {
                    c.heard(&call);
                }
            });
            *c.watch.borrow_mut() = Some(watch);
        });
    }
    let me = c.clone();
    host.action("browser_agent.answer", move |arg| {
        let id = arg.field("id").map(crate::auth::text).unwrap_or_default();
        if id.is_empty() {
            return;
        }
        me.pending
            .borrow_mut()
            .retain(|call| call.field("id").map(crate::auth::text).as_deref() != Some(id.as_str()));
        me.publish();
        let ok = arg.field("ok").is_some_and(Value::truthy);
        let mut params = json!({ "callId": id, "ok": ok });
        if ok {
            params["value"] = arg.field("value").map(value_json).unwrap_or(Json::Null);
        } else {
            params["error"] = Json::String(
                arg.field("error")
                    .map(crate::auth::text)
                    .unwrap_or_default(),
            );
        }
        engine::get().spawn(async move {
            if let Err(e) = engine::get().call("BrowserToolResult", params).await {
                eprintln!("naive-zgx: a browser tool's answer didn't reach the agent: {e}");
            }
        });
    });
}

impl Calls {
    fn heard(&self, call: &Json) {
        let Some(id) = call["callId"].as_str().filter(|id| !id.is_empty()) else {
            return;
        };
        let mut fields = vec![
            ("id", Value::from(id)),
            ("tool", Value::from(call["tool"].as_str().unwrap_or(""))),
            ("args", json_value(&call["args"])),
        ];
        if let Some(chat) = call["chatId"].as_str() {
            fields.push(("chat", Value::from(chat)));
        }
        self.pending.borrow_mut().push(Value::record(fields));
        self.publish();
    }

    fn publish(&self) {
        let value = list(&self.pending.borrow());
        for shared in self.shared.borrow().iter() {
            shared.set(value.clone());
        }
    }
}

fn list(calls: &[Value]) -> Value {
    Value::List(calls.to_vec().into())
}

// Google refuses sign-in from a WKWebView whose agent lacks Safari's `Version/… Safari/…`.
fn safari_user_agent() -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let plist = std::fs::read_to_string("/Applications/Safari.app/Contents/Info.plist").ok();
    let version = plist
        .as_deref()
        .and_then(|p| p.split("<key>CFBundleShortVersionString</key>").nth(1))
        .and_then(|rest| rest.split("<string>").nth(1))
        .and_then(|rest| rest.split("</string>").next())
        .map(str::trim)
        .filter(|v| !v.is_empty() && v.chars().all(|c| c.is_ascii_digit() || c == '.'))
        .unwrap_or("18.0");
    Some(format!(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/{version} Safari/605.1.15"
    ))
}
