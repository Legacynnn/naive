//! Naive mobile core — the UniFFI surface shared by the iOS and Android apps.
//!
//! - [`client_ffi`]: account, workspace and session state (wraps `naive-client`).
//! - [`layout`]: analytic transcript layout — markdown → measured display lists
//!   (wraps `naive-markdown` + `naive-text`).
//! - [`orb`]: the desktop's voice orb as paintable frames (wraps `naive-orb`).
//! - [`caption`]: the voice caption's streaming veil (wraps `naive-veil`).

uniffi::setup_scaffolding!("naive_core");

mod client_ffi;
pub mod layout;
pub mod caption;
pub mod orb;
pub mod terminal;
pub mod wallpaper;
pub mod visual;

/// Version handshake: the Swift/Kotlin bindings must match the linked library.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
