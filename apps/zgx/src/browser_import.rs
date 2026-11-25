use aes::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use rusqlite::Connection;
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};
use zgx::web_view::{WebCookie, WebProfile, set_cookies};
use zgx_script::{ScriptHost, Value};

use crate::auth::text;
use crate::favicons::off_thread;

// Async actions run on the UI thread's executor, and off_thread resumes there, so this is UI-thread safe.
fn store(profile: &str, cookies: Vec<WebCookie>, done: impl FnOnce(Result<usize, String>) + 'static) {
    set_cookies(&WebProfile::Named(profile.into()), cookies, done);
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Kind {
    Chromium(&'static str),
    Firefox,
    Safari,
}

impl Kind {
    fn word(self) -> &'static str {
        match self {
            Kind::Chromium(_) => "chromium",
            Kind::Firefox => "firefox",
            Kind::Safari => "safari",
        }
    }
}

#[derive(Clone)]
struct Source {
    id: String,
    browser: String,
    profile: String,
    label: String,
    kind: Kind,
    path: PathBuf,
}

#[derive(Debug, PartialEq)]
enum Failure {
    NotFound,
    Keychain,
    FullDiskAccess,
    Unreadable,
}

impl Failure {
    fn word(&self) -> &'static str {
        match self {
            Failure::NotFound => "not_found",
            Failure::Keychain => "keychain",
            Failure::FullDiskAccess => "full_disk_access",
            Failure::Unreadable => "unreadable",
        }
    }
}

#[derive(Default)]
struct Harvest {
    cookies: Vec<WebCookie>,
    skipped: usize,
}

struct Chromium {
    key: &'static str,
    name: &'static str,
    dir: &'static str,
    service: &'static str,
}

const CHROMIUM: &[Chromium] = &[
    Chromium { key: "chrome", name: "Google Chrome", dir: "Google/Chrome", service: "Chrome Safe Storage" },
    Chromium { key: "chrome-beta", name: "Chrome Beta", dir: "Google/Chrome Beta", service: "Chrome Safe Storage" },
    Chromium { key: "chrome-canary", name: "Chrome Canary", dir: "Google/Chrome Canary", service: "Chrome Safe Storage" },
    Chromium { key: "chromium", name: "Chromium", dir: "Chromium", service: "Chromium Safe Storage" },
    Chromium { key: "arc", name: "Arc", dir: "Arc/User Data", service: "Arc Safe Storage" },
    Chromium { key: "brave", name: "Brave", dir: "BraveSoftware/Brave-Browser", service: "Brave Safe Storage" },
    Chromium { key: "edge", name: "Microsoft Edge", dir: "Microsoft Edge", service: "Microsoft Edge Safe Storage" },
    Chromium { key: "vivaldi", name: "Vivaldi", dir: "Vivaldi", service: "Vivaldi Safe Storage" },
    Chromium { key: "opera", name: "Opera", dir: "com.operasoftware.Opera", service: "Opera Safe Storage" },
    Chromium { key: "dia", name: "Dia", dir: "Dia/User Data", service: "Dia Safe Storage" },
    Chromium { key: "comet", name: "Comet", dir: "Comet", service: "Comet Safe Storage" },
];

const CHROMIUM_EPOCH_OFFSET: f64 = 11_644_473_600.0;
const MAC_EPOCH_OFFSET: f64 = 978_307_200.0;

pub fn install(host: &ScriptHost) {
    host.async_action("browser_import.sources", |_| async {
        let found = off_thread(sources).await.ok_or("failed")?;
        Ok(Value::List(found.iter().map(source_value).collect()))
    });
    host.async_action("browser_import.run", |arg| async move {
        let id = arg.field("source").map(text).unwrap_or_default();
        let profile = arg.field("profile").map(text).unwrap_or_default();
        if id.is_empty() || profile.is_empty() {
            return Err("invalid".into());
        }
        let filter: Vec<String> = match arg.field("sites") {
            Some(Value::List(list)) => list.iter().map(text).filter_map(|s| normalize_site(&s)).collect(),
            _ => Vec::new(),
        };
        let read = off_thread(move || {
            let source = sources().into_iter().find(|s| s.id == id).ok_or(Failure::NotFound)?;
            read_source(&source, &filter, now())
        })
        .await
        .ok_or("failed")?;
        let harvest = match read {
            Ok(harvest) => harvest,
            Err(failure) => return Ok(outcome(0, 0, &[], Some(failure.word()), None)),
        };
        let sites = sites_of(&harvest.cookies);
        let skipped = harvest.skipped;
        if harvest.cookies.is_empty() {
            return Ok(outcome(0, skipped, &sites, None, None));
        }
        let (tx, mut rx) = zgx::task::latest();
        store(&profile, harvest.cookies, move |result| {
            tx.send(result);
        });
        Ok(match rx.recv().await {
            Some(Ok(stored)) => outcome(stored, skipped, &sites, None, None),
            Some(Err(detail)) => outcome(0, skipped, &sites, Some("store"), Some(&detail)),
            None => outcome(0, skipped, &sites, Some("store"), None),
        })
    });
}

fn source_value(s: &Source) -> Value {
    Value::record([
        ("id", Value::from(s.id.as_str())),
        ("browser", Value::from(s.browser.as_str())),
        ("profile", Value::from(s.profile.as_str())),
        ("label", Value::from(s.label.as_str())),
        ("kind", Value::from(s.kind.word())),
    ])
}

fn outcome(stored: usize, skipped: usize, sites: &[String], error: Option<&str>, detail: Option<&str>) -> Value {
    let mut fields = vec![
        ("stored", Value::Num(stored as f64)),
        ("skipped", Value::Num(skipped as f64)),
        ("sites", Value::List(sites.iter().map(|s| Value::from(s.as_str())).collect())),
    ];
    if let Some(error) = error {
        fields.push(("error", Value::from(error)));
    }
    if let Some(detail) = detail {
        fields.push(("detail", Value::from(detail)));
    }
    Value::record(fields)
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from).filter(|p| p.is_absolute())
}

fn sources() -> Vec<Source> {
    if !cfg!(target_os = "macos") {
        return Vec::new();
    }
    let Some(home) = home() else { return Vec::new() };
    let support = home.join("Library/Application Support");
    let mut found = Vec::new();
    for browser in CHROMIUM {
        found.extend(chromium_sources(browser, &support.join(browser.dir)));
    }
    found.extend(firefox_sources(&support.join("Firefox")));
    if Path::new("/Applications/Safari.app").exists() || Path::new("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app").exists() {
        found.push(Source {
            id: "safari".into(),
            browser: "Safari".into(),
            profile: String::new(),
            label: "Safari".into(),
            kind: Kind::Safari,
            path: home.join("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
        });
    }
    found
}

fn chromium_cookies(profile_dir: &Path) -> Option<PathBuf> {
    [profile_dir.join("Network/Cookies"), profile_dir.join("Cookies")]
        .into_iter()
        .find(|p| p.is_file())
}

fn chromium_sources(browser: &Chromium, root: &Path) -> Vec<Source> {
    if !root.is_dir() {
        return Vec::new();
    }
    let names: serde_json::Value = std::fs::read(root.join("Local State"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    let cache = &names["profile"]["info_cache"];
    let mut dirs: BTreeSet<String> = BTreeSet::new();
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name == "Default" || name.starts_with("Profile ") || cache.get(&name).is_some() {
                dirs.insert(name);
            }
        }
    }
    let mut found: Vec<(String, String, PathBuf)> = Vec::new();
    for dir in dirs {
        if let Some(path) = chromium_cookies(&root.join(&dir)) {
            let shown = cache[&dir]["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(&dir).to_string();
            found.push((dir, shown, path));
        }
    }
    if found.is_empty() {
        if let Some(path) = chromium_cookies(root) {
            found.push(("Default".into(), "Default".into(), path));
        }
    }
    let single = found.len() == 1;
    found
        .into_iter()
        .map(|(dir, shown, path)| Source {
            id: format!("{}:{dir}", browser.key),
            browser: browser.name.into(),
            label: if single { browser.name.into() } else { format!("{} — {shown}", browser.name) },
            profile: dir,
            kind: Kind::Chromium(browser.service),
            path,
        })
        .collect()
}

fn firefox_sources(root: &Path) -> Vec<Source> {
    let mut named: Vec<(PathBuf, String)> = Vec::new();
    if let Ok(ini) = std::fs::read_to_string(root.join("profiles.ini")) {
        let mut name: Option<String> = None;
        let mut path: Option<String> = None;
        let mut relative = true;
        let mut flush = |name: &mut Option<String>, path: &mut Option<String>, relative: &mut bool| {
            if let Some(p) = path.take() {
                let full = if *relative { root.join(&p) } else { PathBuf::from(&p) };
                named.push((full, name.take().unwrap_or(p)));
            }
            *name = None;
            *relative = true;
        };
        for line in ini.lines().map(str::trim) {
            if line.starts_with('[') {
                flush(&mut name, &mut path, &mut relative);
            } else if let Some(v) = line.strip_prefix("Name=") {
                name = Some(v.to_string());
            } else if let Some(v) = line.strip_prefix("Path=") {
                path = Some(v.to_string());
            } else if let Some(v) = line.strip_prefix("IsRelative=") {
                relative = v != "0";
            }
        }
        flush(&mut name, &mut path, &mut relative);
    }
    if let Ok(entries) = std::fs::read_dir(root.join("Profiles")) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !named.iter().any(|(p, _)| p == &path) {
                let dir = entry.file_name().to_string_lossy().into_owned();
                let shown = dir.split_once('.').map(|(_, n)| n.to_string()).unwrap_or(dir);
                named.push((path, shown));
            }
        }
    }
    let found: Vec<(String, String, PathBuf)> = named
        .into_iter()
        .filter_map(|(dir, shown)| {
            let db = dir.join("cookies.sqlite");
            let key = dir.file_name()?.to_string_lossy().into_owned();
            db.is_file().then_some((key, shown, db))
        })
        .collect();
    let single = found.len() == 1;
    found
        .into_iter()
        .map(|(key, shown, path)| Source {
            id: format!("firefox:{key}"),
            browser: "Firefox".into(),
            label: if single { "Firefox".into() } else { format!("Firefox — {shown}") },
            profile: key,
            kind: Kind::Firefox,
            path,
        })
        .collect()
}

fn read_source(source: &Source, filter: &[String], now: f64) -> Result<Harvest, Failure> {
    let mut harvest = match source.kind {
        Kind::Chromium(service) => read_chromium(&source.path, filter, now, || keychain_password(service))?,
        Kind::Firefox => read_firefox(&source.path, filter, now)?,
        Kind::Safari => read_safari(&source.path, now)?,
    };
    harvest.cookies.retain(|c| wanted(&c.domain, filter));
    Ok(harvest)
}

fn keychain_password(service: &str) -> Result<Vec<u8>, Failure> {
    let out = Command::new("/usr/bin/security")
        .args(["find-generic-password", "-w", "-s", service])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|_| Failure::Keychain)?;
    if !out.status.success() {
        return Err(Failure::Keychain);
    }
    let mut password = out.stdout;
    while matches!(password.last(), Some(b'\n' | b'\r')) {
        password.pop();
    }
    if password.is_empty() {
        return Err(Failure::Keychain);
    }
    Ok(password)
}

fn io_failure(e: &std::io::Error) -> Failure {
    match e.kind() {
        std::io::ErrorKind::NotFound => Failure::NotFound,
        std::io::ErrorKind::PermissionDenied => Failure::FullDiskAccess,
        _ => Failure::Unreadable,
    }
}

struct TempCopy {
    dir: PathBuf,
    db: PathBuf,
}

impl TempCopy {
    fn new(original: &Path) -> Result<Self, Failure> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("naive-import-{}-{stamp}", std::process::id()));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&dir).map_err(|_| Failure::Unreadable)?;
        let copy = TempCopy { db: dir.join("cookies.db"), dir };
        std::fs::copy(original, &copy.db).map_err(|e| io_failure(&e))?;
        for suffix in ["-wal", "-journal"] {
            let mut side = original.as_os_str().to_owned();
            side.push(suffix);
            let side = PathBuf::from(side);
            if side.is_file() {
                let mut to = copy.db.as_os_str().to_owned();
                to.push(suffix);
                let _ = std::fs::copy(&side, PathBuf::from(to));
            }
        }
        Ok(copy)
    }

    fn open(&self) -> Result<Connection, Failure> {
        Connection::open(&self.db).map_err(|_| Failure::Unreadable)
    }
}

impl Drop for TempCopy {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct ChromiumRow {
    host: String,
    name: String,
    value: String,
    encrypted: Vec<u8>,
    path: String,
    expires_utc: i64,
    secure: bool,
    http_only: bool,
    same_site: i64,
}

fn read_chromium(
    path: &Path,
    filter: &[String],
    now: f64,
    password: impl FnOnce() -> Result<Vec<u8>, Failure>,
) -> Result<Harvest, Failure> {
    let copy = TempCopy::new(path)?;
    let conn = copy.open()?;
    let version: i64 = conn
        .query_row("SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'version'", [], |r| r.get(0))
        .unwrap_or(0);
    let mut stmt = conn
        .prepare("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies")
        .map_err(|_| Failure::Unreadable)?;
    let rows: Vec<ChromiumRow> = stmt
        .query_map([], |r| {
            Ok(ChromiumRow {
                host: r.get(0)?,
                name: r.get(1)?,
                value: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                encrypted: r.get::<_, Option<Vec<u8>>>(3)?.unwrap_or_default(),
                path: r.get(4)?,
                expires_utc: r.get(5)?,
                secure: r.get::<_, i64>(6)? != 0,
                http_only: r.get::<_, i64>(7)? != 0,
                same_site: r.get(8)?,
            })
        })
        .map_err(|_| Failure::Unreadable)?
        .filter_map(Result::ok)
        .filter(|row| wanted(&row.host, filter))
        .filter(|row| chromium_time(row.expires_utc).is_none_or(|at| at > now))
        .collect();
    drop(stmt);
    drop(conn);
    drop(copy);
    let key = if rows.iter().any(|r| !r.encrypted.is_empty()) {
        Some(chromium_key(&password()?))
    } else {
        None
    };
    let mut harvest = Harvest::default();
    for row in rows {
        let value = if row.encrypted.is_empty() {
            Some(row.value)
        } else {
            key.as_ref().and_then(|k| chromium_decrypt(k, &row.encrypted, version >= 24))
        };
        let Some(value) = value else {
            harvest.skipped += 1;
            continue;
        };
        harvest.cookies.push(WebCookie {
            name: row.name,
            value,
            domain: row.host,
            path: row.path,
            expires: chromium_time(row.expires_utc),
            secure: row.secure,
            http_only: row.http_only,
            same_site: chromium_same_site(row.same_site),
        });
    }
    Ok(harvest)
}

fn chromium_key(password: &[u8]) -> [u8; 16] {
    let mut key = [0u8; 16];
    pbkdf2::pbkdf2_hmac::<sha1::Sha1>(password, b"saltysalt", 1003, &mut key);
    key
}

fn chromium_decrypt(key: &[u8; 16], data: &[u8], hashed_host: bool) -> Option<String> {
    let body = data.strip_prefix(b"v10").or_else(|| data.strip_prefix(b"v11"))?;
    let plain = cbc::Decryptor::<aes::Aes128>::new(key.into(), &[b' '; 16].into())
        .decrypt_padded_vec_mut::<Pkcs7>(body)
        .ok()?;
    let plain = if hashed_host { plain.get(32..)?.to_vec() } else { plain };
    String::from_utf8(plain).ok()
}

fn chromium_time(micros: i64) -> Option<f64> {
    (micros > 0).then(|| micros as f64 / 1_000_000.0 - CHROMIUM_EPOCH_OFFSET)
}

fn chromium_same_site(value: i64) -> Option<String> {
    match value {
        0 => Some("none".into()),
        1 => Some("lax".into()),
        2 => Some("strict".into()),
        _ => None,
    }
}

fn read_firefox(path: &Path, filter: &[String], now: f64) -> Result<Harvest, Failure> {
    let copy = TempCopy::new(path)?;
    let conn = copy.open()?;
    let mut stmt = conn
        .prepare("SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies")
        .map_err(|_| Failure::Unreadable)?;
    let mut harvest = Harvest::default();
    let rows = stmt
        .query_map([], |r| {
            let secure = r.get::<_, i64>(5)? != 0;
            Ok(WebCookie {
                domain: r.get(0)?,
                name: r.get(1)?,
                value: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                path: r.get(3)?,
                expires: firefox_time(r.get(4)?),
                secure,
                http_only: r.get::<_, i64>(6)? != 0,
                same_site: firefox_same_site(r.get(7)?, secure),
            })
        })
        .map_err(|_| Failure::Unreadable)?;
    for row in rows {
        match row {
            Ok(c) if !wanted(&c.domain, filter) => {}
            Ok(c) if c.expires.is_some_and(|at| at <= now) => {}
            Ok(c) => harvest.cookies.push(c),
            Err(_) => harvest.skipped += 1,
        }
    }
    Ok(harvest)
}

fn firefox_time(expiry: i64) -> Option<f64> {
    match expiry {
        e if e <= 0 => None,
        e if e > 100_000_000_000 => Some(e as f64 / 1000.0),
        e => Some(e as f64),
    }
}

fn firefox_same_site(value: i64, secure: bool) -> Option<String> {
    match value {
        0 if secure => Some("none".into()),
        1 => Some("lax".into()),
        2 => Some("strict".into()),
        _ => None,
    }
}

fn read_safari(primary: &Path, now: f64) -> Result<Harvest, Failure> {
    let legacy = primary
        .ancestors()
        .nth(7)
        .map(|home| home.join("Library/Cookies/Cookies.binarycookies"));
    let mut failure = Failure::NotFound;
    for path in std::iter::once(primary.to_path_buf()).chain(legacy) {
        match std::fs::read(&path) {
            Ok(bytes) => return parse_binarycookies(&bytes, now),
            Err(e) => {
                let f = io_failure(&e);
                if f != Failure::NotFound {
                    failure = f;
                }
            }
        }
    }
    Err(failure)
}

fn u32_be(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

fn u32_le(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

fn f64_le(b: &[u8], at: usize) -> Option<f64> {
    Some(f64::from_le_bytes(b.get(at..at + 8)?.try_into().ok()?))
}

fn c_string(b: &[u8], at: usize) -> Option<String> {
    let rest = b.get(at..)?;
    let end = rest.iter().position(|&c| c == 0)?;
    String::from_utf8(rest[..end].to_vec()).ok()
}

fn parse_binarycookies(bytes: &[u8], now: f64) -> Result<Harvest, Failure> {
    if bytes.get(..4) != Some(b"cook") {
        return Err(Failure::Unreadable);
    }
    let pages = u32_be(bytes, 4).ok_or(Failure::Unreadable)? as usize;
    let mut sizes = Vec::with_capacity(pages.min(4096));
    for i in 0..pages {
        sizes.push(u32_be(bytes, 8 + i * 4).ok_or(Failure::Unreadable)? as usize);
    }
    let mut harvest = Harvest::default();
    let mut start = 8 + pages * 4;
    for size in sizes {
        let page = bytes.get(start..start + size).ok_or(Failure::Unreadable)?;
        start += size;
        if u32_be(page, 0) != Some(0x0000_0100) {
            return Err(Failure::Unreadable);
        }
        let count = u32_le(page, 4).ok_or(Failure::Unreadable)? as usize;
        for i in 0..count {
            let Some(cookie) = u32_le(page, 8 + i * 4).and_then(|at| parse_safari_cookie(page, at as usize)) else {
                harvest.skipped += 1;
                continue;
            };
            if cookie.expires.is_some_and(|at| at <= now) {
                continue;
            }
            harvest.cookies.push(cookie);
        }
    }
    Ok(harvest)
}

fn parse_safari_cookie(page: &[u8], at: usize) -> Option<WebCookie> {
    let size = u32_le(page, at)? as usize;
    let cookie = page.get(at..at + size)?;
    let flags = u32_le(cookie, 8)?;
    let field = |offset: usize| u32_le(cookie, offset).and_then(|o| c_string(cookie, o as usize));
    let expiry = f64_le(cookie, 40)?;
    Some(WebCookie {
        domain: field(16)?,
        name: field(20)?,
        path: field(24)?,
        value: field(28)?,
        expires: (expiry > 0.0).then_some(expiry + MAC_EPOCH_OFFSET),
        secure: flags & 1 != 0,
        http_only: flags & 4 != 0,
        same_site: None,
    })
}

fn normalize_site(raw: &str) -> Option<String> {
    let s = raw.trim().to_ascii_lowercase();
    let s = s.split_once("://").map(|(_, rest)| rest).unwrap_or(&s);
    let s = s.split(['/', '?', '#', ':']).next().unwrap_or("");
    let s = s.trim_start_matches('.');
    (!s.is_empty()).then(|| s.to_string())
}

fn wanted(domain: &str, filter: &[String]) -> bool {
    if filter.is_empty() {
        return true;
    }
    let host = domain.trim_start_matches('.').to_ascii_lowercase();
    filter.iter().any(|site| {
        host == *site
            || host.strip_suffix(site.as_str()).is_some_and(|h| h.ends_with('.'))
            || site.strip_suffix(host.as_str()).is_some_and(|s| s.ends_with('.'))
    })
}

fn site_of(domain: &str) -> String {
    let host = domain.trim_start_matches('.').to_ascii_lowercase();
    let labels: Vec<&str> = host.split('.').filter(|l| !l.is_empty()).collect();
    let n = labels.len();
    if n <= 2 {
        return labels.join(".");
    }
    let keep = if labels[n - 1].len() == 2 && labels[n - 2].len() <= 3 { 3 } else { 2 };
    labels[n - keep.min(n)..].join(".")
}

fn sites_of(cookies: &[WebCookie]) -> Vec<String> {
    cookies
        .iter()
        .map(|c| site_of(&c.domain))
        .filter(|s| !s.is_empty())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::BlockEncryptMut;

    fn encrypt(key: &[u8; 16], plain: &[u8]) -> Vec<u8> {
        let mut out = b"v10".to_vec();
        out.extend(
            cbc::Encryptor::<aes::Aes128>::new(key.into(), &[b' '; 16].into()).encrypt_padded_vec_mut::<Pkcs7>(plain),
        );
        out
    }

    #[test]
    fn chromium_values_decrypt_with_the_keychain_derived_key() {
        let key = chromium_key(b"peanuts");
        let sealed = encrypt(&key, b"session-token-123");
        assert_eq!(chromium_decrypt(&key, &sealed, false).as_deref(), Some("session-token-123"));
        assert_eq!(chromium_decrypt(&chromium_key(b"wrong"), &sealed, false), None);
        assert_eq!(chromium_decrypt(&key, b"plain", false), None);
    }

    #[test]
    fn chromium_key_matches_the_known_pbkdf2_vector() {
        let key = chromium_key(b"peanuts");
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "d9a09d499b4e1b7461f28e67972c6dbd");
    }

    #[test]
    fn version_24_values_drop_the_host_hash() {
        let key = chromium_key(b"secret");
        let mut plain = vec![7u8; 32];
        plain.extend_from_slice(b"abc");
        let sealed = encrypt(&key, &plain);
        assert_eq!(chromium_decrypt(&key, &sealed, true).as_deref(), Some("abc"));
        assert_eq!(chromium_decrypt(&key, &encrypt(&key, b"short"), true), None);
    }

    #[test]
    fn chromium_time_is_unix_seconds() {
        assert_eq!(chromium_time(0), None);
        assert_eq!(chromium_time(11_644_473_600_000_000), Some(0.0));
        assert_eq!(chromium_time(13_300_000_000_000_000), Some(1_655_526_400.0));
        assert_eq!(chromium_same_site(-1), None);
        assert_eq!(chromium_same_site(1).as_deref(), Some("lax"));
        assert_eq!(chromium_same_site(2).as_deref(), Some("strict"));
        assert_eq!(chromium_same_site(0).as_deref(), Some("none"));
    }

    #[test]
    fn chromium_database_rows_become_cookies() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("Cookies");
        let key = chromium_key(b"pw");
        let conn = Connection::open(&db).unwrap();
        conn.execute_batch(
            "CREATE TABLE meta (key TEXT, value TEXT);
             INSERT INTO meta VALUES ('version', '24');
             CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
               expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER);",
        )
        .unwrap();
        let mut hashed = vec![0u8; 32];
        hashed.extend_from_slice(b"secret");
        let future = (2_000_000_000.0 + CHROMIUM_EPOCH_OFFSET) as i64 * 1_000_000;
        let insert = "INSERT INTO cookies VALUES (?1, ?2, '', ?3, '/', ?4, 1, 1, 1)";
        conn.execute(insert, rusqlite::params![".github.com", "sid", encrypt(&key, &hashed), future]).unwrap();
        conn.execute(insert, rusqlite::params![".old.com", "gone", encrypt(&key, &hashed), 1_000_000i64]).unwrap();
        conn.execute(insert, rusqlite::params!["x.com", "bad", b"v10garbage".to_vec(), 0i64]).unwrap();
        drop(conn);
        let harvest = read_chromium(&db, &[], 1_900_000_000.0, || Ok(b"pw".to_vec())).unwrap();
        assert_eq!(harvest.skipped, 1);
        assert_eq!(harvest.cookies.len(), 1);
        let c = &harvest.cookies[0];
        assert_eq!((c.name.as_str(), c.value.as_str(), c.domain.as_str()), ("sid", "secret", ".github.com"));
        assert_eq!(c.expires, Some(2_000_000_000.0));
        assert!(c.secure && c.http_only);
        assert_eq!(c.same_site.as_deref(), Some("lax"));
        let filtered = read_chromium(&db, &["gitlab.com".into()], 1_900_000_000.0, || Err(Failure::Keychain)).unwrap();
        assert!(filtered.cookies.is_empty());
    }

    #[test]
    fn firefox_rows_map_to_cookies() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("cookies.sqlite");
        let conn = Connection::open(&db).unwrap();
        conn.execute_batch(
            "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT, path TEXT,
               expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER);
             INSERT INTO moz_cookies (name, value, host, path, expiry, isSecure, isHttpOnly, sameSite)
               VALUES ('a', '1', '.example.com', '/', 2000000000, 1, 0, 2),
                      ('b', '2', 'mail.example.com', '/inbox', 2000000000000, 0, 1, 0),
                      ('c', '3', '.expired.org', '/', 1000, 0, 0, 1),
                      ('d', '4', 'other.net', '/', 2000000000, 1, 0, 0);",
        )
        .unwrap();
        drop(conn);
        let harvest = read_firefox(&db, &[], 1_900_000_000.0).unwrap();
        let by_name = |n: &str| harvest.cookies.iter().find(|c| c.name == n);
        assert_eq!(harvest.cookies.len(), 3);
        let a = by_name("a").unwrap();
        assert_eq!((a.value.as_str(), a.domain.as_str(), a.expires), ("1", ".example.com", Some(2_000_000_000.0)));
        assert!(a.secure && !a.http_only);
        assert_eq!(a.same_site.as_deref(), Some("strict"));
        let b = by_name("b").unwrap();
        assert_eq!((b.path.as_str(), b.expires, b.same_site.clone()), ("/inbox", Some(2_000_000_000.0), None));
        assert!(b.http_only);
        assert_eq!(by_name("d").unwrap().same_site.as_deref(), Some("none"));
        assert!(by_name("c").is_none());
        let only = read_firefox(&db, &["example.com".into()], 1_900_000_000.0).unwrap();
        assert_eq!(sites_of(&only.cookies), vec!["example.com".to_string()]);
        assert_eq!(only.cookies.len(), 2);
    }

    fn safari_cookie(flags: u32, domain: &str, name: &str, path: &str, value: &str, expiry: f64) -> Vec<u8> {
        let mut strings = Vec::new();
        let mut offsets = Vec::new();
        for s in [domain, name, path, value] {
            offsets.push(56 + strings.len() as u32);
            strings.extend_from_slice(s.as_bytes());
            strings.push(0);
        }
        let mut c = Vec::new();
        c.extend((56 + strings.len() as u32).to_le_bytes());
        c.extend(0u32.to_le_bytes());
        c.extend(flags.to_le_bytes());
        c.extend(0u32.to_le_bytes());
        for o in offsets {
            c.extend(o.to_le_bytes());
        }
        c.extend([0u8; 8]);
        c.extend(expiry.to_le_bytes());
        c.extend(0f64.to_le_bytes());
        c.extend(strings);
        c
    }

    #[test]
    fn binarycookies_parse() {
        let cookies = [
            safari_cookie(5, ".apple.com", "dslang", "/", "US-EN", 1_000_000_000.0),
            safari_cookie(0, "news.ycombinator.com", "user", "/", "pg", 1.0),
        ];
        let header = 8 + cookies.len() * 4 + 4;
        let mut page = vec![0, 0, 1, 0];
        page.extend((cookies.len() as u32).to_le_bytes());
        let mut at = header;
        for c in &cookies {
            page.extend((at as u32).to_le_bytes());
            at += c.len();
        }
        page.extend(0u32.to_le_bytes());
        for c in &cookies {
            page.extend(c);
        }
        let mut file = b"cook".to_vec();
        file.extend(1u32.to_be_bytes());
        file.extend((page.len() as u32).to_be_bytes());
        file.extend(&page);
        file.extend([0u8; 8]);
        let harvest = parse_binarycookies(&file, 1_500_000_000.0).unwrap();
        assert_eq!(harvest.cookies.len(), 1);
        let c = &harvest.cookies[0];
        assert_eq!((c.domain.as_str(), c.name.as_str(), c.path.as_str(), c.value.as_str()), (".apple.com", "dslang", "/", "US-EN"));
        assert_eq!(c.expires, Some(1_978_307_200.0));
        assert!(c.secure && c.http_only);
        assert!(parse_binarycookies(b"nope", 0.0).is_err());
        file.truncate(20);
        assert!(parse_binarycookies(&file, 0.0).is_err());
    }

    #[test]
    fn sites_are_matched_and_named_by_their_registrable_part() {
        assert_eq!(site_of(".mail.google.com"), "google.com");
        assert_eq!(site_of("www.bbc.co.uk"), "bbc.co.uk");
        assert_eq!(normalize_site(" https://GitHub.com/login ").as_deref(), Some("github.com"));
        let f = vec!["mail.google.com".to_string()];
        assert!(wanted(".google.com", &f));
        assert!(wanted("mail.google.com", &f));
        assert!(!wanted("evilgoogle.com", &f));
        assert!(!wanted("docs.google.com", &f));
    }
}
