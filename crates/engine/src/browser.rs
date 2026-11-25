use std::sync::{Arc, LazyLock};
use std::time::Duration;

use futures::future::BoxFuture;
use naive_rpc::{RpcError, RpcReply, methods, parse_params};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::plugins::broker::{CallError, ToolAnswer, ToolBroker};

const TIMEOUT: Duration = Duration::from_secs(150);

pub trait Backend: Send + Sync {
    fn name(&self) -> &'static str;
    fn available(&self) -> bool;
    fn call<'a>(
        &'a self,
        tool: &'a str,
        args: Value,
        chat: Option<&'a str>,
    ) -> BoxFuture<'a, Result<Value, String>>;
}
#[derive(Default)]
pub struct Webview {
    broker: ToolBroker,
}

impl Backend for Webview {
    fn name(&self) -> &'static str {
        "webview"
    }

    fn available(&self) -> bool {
        self.broker.serve.is_open()
    }

    fn call<'a>(
        &'a self,
        tool: &'a str,
        args: Value,
        chat: Option<&'a str>,
    ) -> BoxFuture<'a, Result<Value, String>> {
        Box::pin(async move {
            self.broker
                .call("browser", tool, args, chat, TIMEOUT)
                .await
                .map_err(|error| match error {
                    CallError::NotOpen => "The browser needs Naive open on this device".to_string(),
                    CallError::TimedOut => format!(
                        "The browser didn't answer {tool} within {} s",
                        TIMEOUT.as_secs()
                    ),
                    CallError::Failed(why) => why,
                })
        })
    }
}

pub struct BrowserTools {
    webview: Arc<Webview>,
    backends: Vec<Arc<dyn Backend>>,
}

impl Default for BrowserTools {
    fn default() -> Self {
        let webview = Arc::new(Webview::default());
        Self {
            backends: vec![webview.clone()],
            webview,
        }
    }
}

static TOOLS: LazyLock<BrowserTools> = LazyLock::new(BrowserTools::default);

pub fn handles(method: &str) -> bool {
    matches!(
        method,
        methods::CALL_BROWSER_TOOL | methods::SERVE_BROWSER_TOOLS | methods::BROWSER_TOOL_RESULT
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CallParams {
    tool: String,
    #[serde(default)]
    args: Value,
    #[serde(default)]
    chat_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResultParams {
    call_id: String,
    ok: bool,
    #[serde(default)]
    value: Value,
    #[serde(default)]
    error: Option<String>,
}
pub async fn dispatch(method: &str, params: Value, runner: bool) -> Result<RpcReply, RpcError> {
    TOOLS.dispatch(method, params, runner).await
}

impl BrowserTools {
    async fn dispatch(
        &'static self,
        method: &str,
        params: Value,
        runner: bool,
    ) -> Result<RpcReply, RpcError> {
        if runner {
            return Err(RpcError::Failed("Browser tools are off on Cloud".into()));
        }
        match method {
            methods::CALL_BROWSER_TOOL => {
                let p: CallParams = parse_params(params)?;
                let value = self
                    .call(&p.tool, p.args, p.chat_id.as_deref())
                    .await
                    .map_err(RpcError::Failed)?;
                RpcReply::value(&json!({ "ok": true, "value": value }))
            }
            methods::SERVE_BROWSER_TOOLS => {
                let webview = Arc::downgrade(&self.webview);
                Ok(RpcReply::Stream(self.webview.broker.serve.subscribe(
                    move || {
                        if let Some(webview) = webview.upgrade() {
                            webview.broker.drop_pending();
                        }
                    },
                )))
            }
            methods::BROWSER_TOOL_RESULT => {
                let p: ResultParams = parse_params(params)?;
                let answer = if p.ok {
                    ToolAnswer::Ok(p.value)
                } else {
                    ToolAnswer::Err(p.error.unwrap_or_else(|| "The browser tool failed".into()))
                };
                self.webview.broker.answer(&p.call_id, answer);
                RpcReply::value(&json!({}))
            }
            _ => Err(RpcError::Failed(format!("{method} isn't a browser method"))),
        }
    }

    async fn call(&self, tool: &str, args: Value, chat: Option<&str>) -> Result<Value, String> {
        match self.backends.iter().find(|b| b.available()) {
            Some(backend) => backend.call(tool, args, chat).await,
            None => Err("The browser needs Naive open on this device".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::StreamExt;

    #[tokio::test]
    async fn browser_calls_reach_the_serving_app_and_fail_without_one() {
        let tools: &'static BrowserTools = Box::leak(Box::default());
        let call = |tool: &'static str| async move {
            tools
                .dispatch(
                    methods::CALL_BROWSER_TOOL,
                    json!({ "tool": tool, "args": {}, "chatId": "c1" }),
                    false,
                )
                .await
        };
        assert!(
            matches!(call("browser_tabs").await, Err(RpcError::Failed(why)) if why.contains("Naive open"))
        );
        let Ok(RpcReply::Stream(mut served)) = tools
            .dispatch(methods::SERVE_BROWSER_TOOLS, json!({}), false)
            .await
        else {
            panic!("no stream");
        };
        let app = tokio::spawn(async move {
            let item = served.next().await.unwrap();
            assert_eq!(item["tool"], "browser_tabs");
            assert_eq!(item["chatId"], "c1");
            let id = item["callId"].as_str().unwrap().to_owned();
            tools
                .dispatch(
                    methods::BROWSER_TOOL_RESULT,
                    json!({ "callId": id, "ok": true, "value": { "tabs": [] } }),
                    false,
                )
                .await
                .unwrap();
            served
        });
        assert!(call("browser_tabs").await.is_ok());
        drop(app.await.unwrap());
        assert!(
            tools
                .dispatch(
                    methods::CALL_BROWSER_TOOL,
                    json!({ "tool": "browser_tabs" }),
                    true
                )
                .await
                .is_err()
        );
    }
}
