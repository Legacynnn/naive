//! naive — the command line with the engine linked in: `naive headless` runs
//! the engine alone, and the engine's other subcommands run here. It starts
//! local-only without credentials. `naive login` and `naive logout` select
//! the profile used by the next engine start without mutating a live runtime.
//!
//! The command line is `naive_cli`'s (shared with the engine helper and the
//! zgx interface). The desktop app is the zgx interface (apps/zgx), which
//! ships its own `naive`: this one opens no window.

use naive_cli::{Engines, Launch};

fn main() -> anyhow::Result<()> {
    // The engine runs its own executable as an agent's stdio MCP forwarder
    // (`naive headless`'s agents): first, before any setup, to stay tiny.
    if std::env::args().nth(1).as_deref() == Some("mcp-proxy") {
        return naive_mcp::proxy::run();
    }
    match naive_cli::run(naive_update::current_version(), Engines::InProcess) {
        Launch::Done(result) => result,
        Launch::Engine(command) => naive_app::run_engine_command(command),
        #[cfg(target_os = "linux")]
        Launch::Appshot => anyhow::bail!("Appshots are the desktop app's: open Naive and use its shortcut"),
        Launch::Window { .. } => anyhow::bail!(
            "this `naive` has no window: open the Naive app, or run `naive headless` for the engine alone"
        ),
    }
}
