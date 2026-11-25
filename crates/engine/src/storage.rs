use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use futures::{StreamExt, stream};
use serde::{Deserialize, Serialize};
use naive_proto::Chat;

use crate::EngineError;
use crate::repos::{Repos, canonical_lossy};
use crate::workspace_host::WorkspaceHost;

const CHAT_INDEX_FILE: &str = "storage-chat-cwds.json";
const JOURNAL_SUFFIXES: &[&str] = &["jsonl", "resume", "shutdown", "stopped"];

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUsage {
    pub updates: u64,
    pub templates: u64,
    pub plugins: u64,
    pub logs: u64,
    pub uploads: u64,
    pub other: u64,
}

impl AppUsage {
    fn total(&self) -> u64 {
        self.updates + self.templates + self.plugins + self.logs + self.uploads + self.other
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectUsage {
    pub name: String,
    pub repo_path: Option<String>,
    pub worktrees: u64,
    pub worktree_count: u32,
    pub journals: u64,
    pub total: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageUsage {
    pub computed_at: i64,
    pub total: u64,
    pub root: String,
    pub app: AppUsage,
    pub projects: Vec<ProjectUsage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatState {
    Active,
    Archived,
    Deleted,
    None,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageWorktree {
    pub path: String,
    pub repo_path: String,
    pub project: String,
    pub name: String,
    pub branch: Option<String>,
    pub bytes: Option<u64>,
    pub modified_at: Option<i64>,
    pub chat_id: Option<String>,
    pub chat_title: Option<String>,
    pub chat_state: ChatState,
    pub dirty: bool,
    pub unpushed: Option<u32>,
    pub missing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CleanAction {
    StaleWorktrees,
    DeletedChatData,
    ArchivedChats,
    StagedUpdate,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanOutcome {
    pub removed: u32,
    pub freed_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct IndexedChat {
    cwd: String,
    #[serde(default)]
    title: Option<String>,
}

#[derive(Default)]
struct Cache {
    usage: Option<StorageUsage>,
    sizes: HashMap<PathBuf, u64>,
}

struct StorageInner {
    data_dir: PathBuf,
    cache: Mutex<Cache>,
    computing: tokio::sync::Mutex<()>,
    index: Mutex<()>,
}

/// One per data dir, shared by every RPC service the engine hands out.
#[derive(Clone)]
pub struct Storage {
    inner: Arc<StorageInner>,
}

#[derive(Debug, Clone)]
struct Discovered {
    path: PathBuf,
    repo_path: Option<PathBuf>,
    branch: Option<String>,
    missing: bool,
}

impl Storage {
    pub fn for_data_dir(data_dir: &Path) -> Self {
        static ALL: OnceLock<Mutex<HashMap<PathBuf, Storage>>> = OnceLock::new();
        let mut all = ALL
            .get_or_init(Default::default)
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        all.entry(data_dir.to_path_buf())
            .or_insert_with(|| Storage {
                inner: Arc::new(StorageInner {
                    data_dir: data_dir.to_path_buf(),
                    cache: Mutex::new(Cache::default()),
                    computing: tokio::sync::Mutex::new(()),
                    index: Mutex::new(()),
                }),
            })
            .clone()
    }

    fn cache(&self) -> std::sync::MutexGuard<'_, Cache> {
        self.inner
            .cache
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    pub fn invalidate(&self, removed: Option<&Path>) {
        let mut cache = self.cache();
        cache.usage = None;
        if let Some(removed) = removed {
            let removed = canonical_lossy(removed);
            cache.sizes.retain(|path, _| !path.starts_with(&removed));
        }
    }

    /// Boot pass: prune stale worktree registrations (never folders) and keep
    /// the chat→cwd index current so a deleted chat's worktree reads as such.
    pub fn start(&self, repos: Repos, workspace: WorkspaceHost) {
        let storage = self.clone();
        let mut chats = workspace.watch_chats();
        tokio::spawn(async move {
            for repo in storage.repos_with_worktrees(&repos, &workspace).await {
                if let Err(error) = repos.prune_worktrees(&repo).await {
                    tracing::debug!(repo = %repo.display(), %error, "boot worktree prune skipped");
                }
            }
            loop {
                let snapshot = chats.borrow_and_update().clone();
                let storage = storage.clone();
                let root = canonical_lossy(&repos.worktrees_root());
                let device = workspace.device_id().to_string();
                let _ = tokio::task::spawn_blocking(move || {
                    storage.record_chats(&snapshot, &root, &device)
                })
                .await;
                if chats.changed().await.is_err() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        });
    }

    fn index_path(&self) -> PathBuf {
        self.inner.data_dir.join(CHAT_INDEX_FILE)
    }

    fn read_index(&self) -> BTreeMap<String, IndexedChat> {
        std::fs::read_to_string(self.index_path())
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    fn record_chats(&self, chats: &[Chat], root: &Path, device_id: &str) {
        let _guard = self
            .inner
            .index
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let before = self.read_index();
        let mut index = before.clone();
        for chat in chats {
            let Some(cwd) = chat.cwd.as_deref() else {
                continue;
            };
            if chat.device_id != device_id || !canonical_lossy(Path::new(cwd)).starts_with(root) {
                continue;
            }
            index.insert(
                chat.id.clone(),
                IndexedChat {
                    cwd: cwd.to_string(),
                    title: chat.title.clone(),
                },
            );
        }
        index.retain(|_, chat| Path::new(&chat.cwd).exists());
        let changed = index.len() != before.len()
            || index.iter().any(|(id, chat)| {
                before
                    .get(id)
                    .is_none_or(|old| old.cwd != chat.cwd || old.title != chat.title)
            });
        if changed && let Ok(json) = serde_json::to_vec(&index) {
            let tmp = self.index_path().with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(&tmp, self.index_path());
            }
        }
    }

    async fn repos_with_worktrees(&self, repos: &Repos, workspace: &WorkspaceHost) -> Vec<PathBuf> {
        let discovered = discover(repos, workspace).await;
        let mut seen = HashSet::new();
        discovered
            .into_iter()
            .filter_map(|wt| wt.repo_path)
            .filter(|repo| seen.insert(repo.clone()))
            .collect()
    }

    pub async fn usage(
        &self,
        repos: &Repos,
        workspace: &WorkspaceHost,
        store_root: Option<PathBuf>,
        refresh: bool,
    ) -> Result<StorageUsage, EngineError> {
        if !refresh && let Some(usage) = self.cache().usage.clone() {
            return Ok(usage);
        }
        let _computing = self.inner.computing.lock().await;
        if !refresh && let Some(usage) = self.cache().usage.clone() {
            return Ok(usage);
        }
        let discovered = discover(repos, workspace).await;
        let root = repos.worktrees_root();
        let chats = workspace.read_chats().unwrap_or_default();
        let spaces = workspace.read_spaces().unwrap_or_default();
        let data_dir = self.inner.data_dir.clone();
        let (usage, sizes) = tokio::task::spawn_blocking(move || {
            compute_usage(
                &data_dir,
                &root,
                store_root.as_deref(),
                &discovered,
                &chats,
                &spaces,
            )
        })
        .await
        .map_err(|e| EngineError::Other(e.to_string()))?;
        let mut cache = self.cache();
        cache.usage = Some(usage.clone());
        cache.sizes = sizes;
        Ok(usage)
    }

    pub async fn worktrees(
        &self,
        repos: &Repos,
        workspace: &WorkspaceHost,
    ) -> Result<Vec<StorageWorktree>, EngineError> {
        let discovered = discover(repos, workspace).await;
        let root = canonical_lossy(&repos.worktrees_root());
        let device = workspace.device_id().to_string();
        let chats: Vec<Chat> = workspace
            .read_chats()
            .unwrap_or_default()
            .into_iter()
            .filter(|chat| chat.device_id == device)
            .collect();
        let index = self.read_index();
        let sizes = self.cache().sizes.clone();
        let mut bases: HashMap<PathBuf, Option<String>> = HashMap::new();
        for repo in discovered.iter().filter_map(|wt| wt.repo_path.clone()) {
            if !bases.contains_key(&repo) {
                let base = repos.default_base(&repo).await;
                bases.insert(repo, base);
            }
        }
        let mut rows: Vec<StorageWorktree> = stream::iter(discovered)
            .map(|wt| {
                let base = wt
                    .repo_path
                    .as_ref()
                    .and_then(|repo| bases.get(repo).cloned().flatten());
                let (chats, index, sizes, root) = (&chats, &index, &sizes, &root);
                async move {
                    let (dirty, unpushed) = if wt.missing {
                        (false, None)
                    } else {
                        (
                            repos
                                .worktree_dirty(&wt.path)
                                .await
                                .unwrap_or(wt.repo_path.is_some()),
                            repos.worktree_unpushed(&wt.path, base.as_deref()).await,
                        )
                    };
                    let (chat_id, chat_title, chat_state) =
                        chat_for(&wt.path, chats, index, |id| workspace.chat_deleted(id));
                    StorageWorktree {
                        path: wt.path.to_string_lossy().into_owned(),
                        repo_path: wt
                            .repo_path
                            .as_ref()
                            .map(|p| p.to_string_lossy().into_owned())
                            .unwrap_or_default(),
                        project: project_of(&wt.path, root),
                        name: wt
                            .path
                            .file_name()
                            .map(|n| n.to_string_lossy().into_owned())
                            .unwrap_or_default(),
                        branch: wt.branch.clone(),
                        bytes: sizes.get(&wt.path).copied(),
                        modified_at: modified_at(&wt.path),
                        chat_id,
                        chat_title,
                        chat_state,
                        dirty,
                        unpushed,
                        missing: wt.missing,
                    }
                }
            })
            .buffer_unordered(8)
            .collect()
            .await;
        rows.sort_by(|a, b| a.project.cmp(&b.project).then_with(|| a.name.cmp(&b.name)));
        Ok(rows)
    }

    pub async fn remove_worktree(
        &self,
        repos: &Repos,
        workspace: &WorkspaceHost,
        terminals: &crate::terminals::Terminals,
        path: &Path,
        delete_branch: bool,
        force: bool,
    ) -> Result<Option<u64>, EngineError> {
        let root = canonical_lossy(&repos.worktrees_root());
        let target = canonical_lossy(path);
        if target == root
            || !target.starts_with(&root)
            || path
                .components()
                .any(|c| c == std::path::Component::ParentDir)
        {
            return Err(EngineError::Other(
                "Only worktrees under the worktrees folder can be removed".into(),
            ));
        }
        let found = discover(repos, workspace)
            .await
            .into_iter()
            .find(|wt| wt.path == target)
            .ok_or_else(|| EngineError::Other("Worktree not found".into()))?;
        if !found.missing
            && !force
            && repos
                .worktree_dirty(&found.path)
                .await
                .unwrap_or(found.repo_path.is_some())
        {
            return Err(EngineError::Other(
                "Worktree has uncommitted changes".into(),
            ));
        }
        let freed = self
            .remove_discovered(repos, terminals, &found, delete_branch)
            .await?;
        Ok(freed)
    }

    async fn remove_discovered(
        &self,
        repos: &Repos,
        terminals: &crate::terminals::Terminals,
        wt: &Discovered,
        delete_branch: bool,
    ) -> Result<Option<u64>, EngineError> {
        let freed = if wt.missing {
            Some(0)
        } else {
            let cached = self.cache().sizes.get(&wt.path).copied();
            match cached {
                Some(bytes) => Some(bytes),
                None => {
                    let path = wt.path.clone();
                    tokio::task::spawn_blocking(move || dir_size(&path, &HashSet::new()))
                        .await
                        .ok()
                }
            }
        };
        terminals.close_under(&wt.path);
        match &wt.repo_path {
            Some(repo) if repo.exists() => {
                repos.remove_worktree(repo, &wt.path, delete_branch).await?;
            }
            _ => {
                let path = wt.path.clone();
                tokio::task::spawn_blocking(move || std::fs::remove_dir_all(path))
                    .await
                    .map_err(|e| EngineError::Other(e.to_string()))??;
            }
        }
        self.invalidate(Some(&wt.path));
        Ok(freed)
    }

    pub async fn clean_stale_worktrees(
        &self,
        repos: &Repos,
        workspace: &WorkspaceHost,
        terminals: &crate::terminals::Terminals,
    ) -> Result<CleanOutcome, EngineError> {
        let rows = self.worktrees(repos, workspace).await?;
        let discovered: HashMap<PathBuf, Discovered> = discover(repos, workspace)
            .await
            .into_iter()
            .map(|wt| (wt.path.clone(), wt))
            .collect();
        let mut outcome = CleanOutcome::default();
        let mut touched = HashSet::new();
        for row in rows {
            if row.chat_state == ChatState::Active || row.dirty {
                continue;
            }
            let Some(wt) = discovered
                .get(Path::new(&row.path))
                .filter(|wt| wt.repo_path.is_some())
            else {
                continue;
            };
            // Commits that exist only on the branch stay reachable: keep it.
            let delete_branch = row.unpushed == Some(0);
            match self
                .remove_discovered(repos, terminals, wt, delete_branch)
                .await
            {
                Ok(freed) => {
                    outcome.removed += 1;
                    outcome.freed_bytes += freed.unwrap_or(0);
                    if let Some(repo) = &wt.repo_path {
                        touched.insert(repo.clone());
                    }
                }
                Err(error) => {
                    tracing::warn!(path = %row.path, %error, "stale worktree removal failed")
                }
            }
        }
        for repo in discovered.values().filter_map(|wt| wt.repo_path.clone()) {
            touched.insert(repo);
        }
        for repo in touched {
            let _ = repos.prune_worktrees(&repo).await;
        }
        Ok(outcome)
    }

    pub async fn clean_deleted_chat_data(
        &self,
        workspace: &WorkspaceHost,
        journals: PathBuf,
    ) -> Result<CleanOutcome, EngineError> {
        let live: HashSet<String> = workspace
            .read_chats()
            .unwrap_or_default()
            .iter()
            .map(|chat| sanitize_id(&chat.id))
            .collect();
        let synced = workspace.registry_synced();
        let Ok(entries) = std::fs::read_dir(&journals) else {
            return Ok(CleanOutcome::default());
        };
        let mut doomed = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
                continue;
            }
            let (Some(stem), Some(ext)) = (
                path.file_stem().and_then(|s| s.to_str()),
                path.extension().and_then(|s| s.to_str()),
            ) else {
                continue;
            };
            if !JOURNAL_SUFFIXES.contains(&ext) || live.contains(stem) {
                continue;
            }
            if synced || workspace.chat_deleted(stem) {
                doomed.push(path);
            }
        }
        let outcome = tokio::task::spawn_blocking(move || {
            let mut outcome = CleanOutcome::default();
            for path in doomed {
                let bytes = file_bytes(&path);
                if std::fs::remove_file(&path).is_ok() {
                    outcome.removed += 1;
                    outcome.freed_bytes += bytes;
                }
            }
            outcome
        })
        .await
        .map_err(|e| EngineError::Other(e.to_string()))?;
        self.invalidate(None);
        Ok(outcome)
    }

    pub fn archived_chats_older_than(&self, workspace: &WorkspaceHost, days: u32) -> Vec<String> {
        let cutoff = chrono::Utc::now() - chrono::Duration::days(i64::from(days));
        let device = workspace.device_id();
        workspace
            .read_chats()
            .unwrap_or_default()
            .into_iter()
            .filter(|chat| {
                chat.archived
                    && chat.device_id == device
                    && chat.last_message_at.unwrap_or(chat.created_at) < cutoff
            })
            .map(|chat| chat.id)
            .collect()
    }

    pub async fn clean_staged_updates(&self) -> Result<CleanOutcome, EngineError> {
        let updates = self.inner.data_dir.join("updates");
        let outcome = tokio::task::spawn_blocking(move || {
            let mut outcome = CleanOutcome::default();
            let Ok(entries) = std::fs::read_dir(&updates) else {
                return outcome;
            };
            let current = naive_update::app_version();
            for entry in entries.flatten() {
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().into_owned();
                // A newer version's folder is a stage waiting to apply (or still downloading).
                if naive_update::version_newer(&name, current)
                    || naive_update::process_runs_from(&path)
                {
                    continue;
                }
                let bytes = if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                    let bytes = dir_size(&path, &HashSet::new());
                    if std::fs::remove_dir_all(&path).is_err() {
                        continue;
                    }
                    bytes
                } else {
                    let bytes = file_bytes(&path);
                    if std::fs::remove_file(&path).is_err() {
                        continue;
                    }
                    bytes
                };
                outcome.removed += 1;
                outcome.freed_bytes += bytes;
            }
            outcome
        })
        .await
        .map_err(|e| EngineError::Other(e.to_string()))?;
        self.invalidate(None);
        Ok(outcome)
    }
}

pub fn journal_bytes(journals: &Path, chat_id: &str) -> u64 {
    let stem = sanitize_id(chat_id);
    JOURNAL_SUFFIXES
        .iter()
        .map(|ext| file_bytes(&journals.join(format!("{stem}.{ext}"))))
        .sum()
}

fn sanitize_id(chat_id: &str) -> String {
    chat_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn chat_for(
    path: &Path,
    chats: &[Chat],
    index: &BTreeMap<String, IndexedChat>,
    deleted: impl Fn(&str) -> bool,
) -> (Option<String>, Option<String>, ChatState) {
    let inside = |cwd: &str| canonical_lossy(Path::new(cwd)).starts_with(path);
    let mut best: Option<&Chat> = None;
    for chat in chats
        .iter()
        .filter(|chat| chat.cwd.as_deref().is_some_and(inside))
    {
        let better = match best {
            None => true,
            Some(current) => {
                (current.archived && !chat.archived)
                    || (current.archived == chat.archived
                        && chat.last_message_at.unwrap_or(chat.created_at)
                            > current.last_message_at.unwrap_or(current.created_at))
            }
        };
        if better {
            best = Some(chat);
        }
    }
    if let Some(chat) = best {
        let state = if chat.archived {
            ChatState::Archived
        } else {
            ChatState::Active
        };
        return (Some(chat.id.clone()), chat.title.clone(), state);
    }
    for (id, chat) in index {
        if inside(&chat.cwd) && deleted(id) {
            return (Some(id.clone()), chat.title.clone(), ChatState::Deleted);
        }
    }
    (None, None, ChatState::None)
}

fn project_of(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .ok()
        .and_then(|rest| rest.components().next())
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .or_else(|| {
            path.parent()
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().into_owned())
        })
        .unwrap_or_default()
}

fn modified_at(path: &Path) -> Option<i64> {
    let mut latest = std::fs::metadata(path).and_then(|m| m.modified()).ok();
    if let Some(gitdir) = linked_gitdir(path) {
        for file in ["index", "HEAD"] {
            if let Ok(time) = std::fs::metadata(gitdir.join(file)).and_then(|m| m.modified()) {
                latest = Some(latest.map_or(time, |l| l.max(time)));
            }
        }
    }
    latest
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
}

fn linked_gitdir(worktree: &Path) -> Option<PathBuf> {
    let raw = std::fs::read_to_string(worktree.join(".git")).ok()?;
    let gitdir = raw
        .lines()
        .find_map(|line| line.strip_prefix("gitdir:"))?
        .trim();
    let gitdir = PathBuf::from(gitdir);
    Some(if gitdir.is_absolute() {
        gitdir
    } else {
        worktree.join(gitdir)
    })
}

/// The main checkout a linked worktree belongs to, read from its `.git` file.
fn owning_repo(worktree: &Path) -> Option<PathBuf> {
    let gitdir = linked_gitdir(worktree)?;
    let common = std::fs::read_to_string(gitdir.join("commondir"))
        .ok()
        .map(|rel| {
            let rel = PathBuf::from(rel.trim());
            if rel.is_absolute() {
                rel
            } else {
                gitdir.join(rel)
            }
        })?;
    let common = std::fs::canonicalize(common).ok()?;
    if common.file_name().is_some_and(|n| n == ".git") {
        common.parent().map(Path::to_path_buf)
    } else {
        Some(common)
    }
}

async fn discover(repos: &Repos, workspace: &WorkspaceHost) -> Vec<Discovered> {
    let root = canonical_lossy(&repos.worktrees_root());
    let scanned: Vec<PathBuf> = {
        let root = root.clone();
        tokio::task::spawn_blocking(move || {
            let mut dirs = Vec::new();
            for project in std::fs::read_dir(&root).into_iter().flatten().flatten() {
                if !project.file_type().is_ok_and(|kind| kind.is_dir()) {
                    continue;
                }
                for wt in std::fs::read_dir(project.path())
                    .into_iter()
                    .flatten()
                    .flatten()
                {
                    if wt.file_type().is_ok_and(|kind| kind.is_dir()) {
                        dirs.push(wt.path());
                    }
                }
            }
            dirs
        })
        .await
        .unwrap_or_default()
    };
    let mut candidates: Vec<PathBuf> = repos
        .known_repo_paths()
        .into_iter()
        .map(PathBuf::from)
        .collect();
    let device = workspace.device_id().to_string();
    candidates.extend(
        workspace
            .read_spaces()
            .unwrap_or_default()
            .into_iter()
            .filter(|space| space.device_id == device)
            .map(|space| PathBuf::from(space.path)),
    );
    let owners: HashMap<PathBuf, PathBuf> = scanned
        .iter()
        .filter_map(|dir| Some((dir.clone(), owning_repo(dir)?)))
        .collect();
    candidates.extend(owners.values().cloned());
    let mut seen = HashSet::new();
    let mut found: BTreeMap<PathBuf, Discovered> = BTreeMap::new();
    for repo in candidates {
        let Ok(repo) = std::fs::canonicalize(&repo) else {
            continue;
        };
        if !seen.insert(repo.clone()) || repo.starts_with(&root) {
            continue;
        }
        let Ok(entries) = repos.list_worktrees(&repo).await else {
            continue;
        };
        for entry in entries {
            if entry.main {
                continue;
            }
            let path = canonical_lossy(&entry.path);
            if path == root || !path.starts_with(&root) {
                continue;
            }
            let missing = !path.exists();
            found.entry(path.clone()).or_insert(Discovered {
                path,
                repo_path: Some(repo.clone()),
                branch: entry.branch,
                missing,
            });
        }
    }
    for dir in scanned {
        let path = canonical_lossy(&dir);
        if found.contains_key(&path) {
            continue;
        }
        let repo_path = owners.get(&dir).cloned().filter(|repo| repo.exists());
        found.insert(
            path.clone(),
            Discovered {
                path,
                repo_path,
                branch: None,
                missing: false,
            },
        );
    }
    found.into_values().collect()
}

fn compute_usage(
    data_dir: &Path,
    worktrees_root: &Path,
    store_root: Option<&Path>,
    discovered: &[Discovered],
    chats: &[Chat],
    spaces: &[naive_proto::Space],
) -> (StorageUsage, HashMap<PathBuf, u64>) {
    let root = canonical_lossy(worktrees_root);
    let data = canonical_lossy(data_dir);
    let mut skip = HashSet::new();
    skip.insert(root.clone());
    let mut app = AppUsage::default();
    let mut projects: BTreeMap<String, ProjectUsage> = BTreeMap::new();
    let mut sizes = HashMap::new();
    let project = |projects: &mut BTreeMap<String, ProjectUsage>, name: &str| {
        projects
            .entry(name.to_string())
            .or_insert_with(|| ProjectUsage {
                name: name.to_string(),
                repo_path: None,
                worktrees: 0,
                worktree_count: 0,
                journals: 0,
                total: 0,
            });
    };
    for dir in std::fs::read_dir(&root).into_iter().flatten().flatten() {
        if !dir.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let name = dir.file_name().to_string_lossy().into_owned();
        project(&mut projects, &name);
        let mut total = 0;
        let mut count = 0;
        for child in std::fs::read_dir(dir.path())
            .into_iter()
            .flatten()
            .flatten()
        {
            let bytes = if child.file_type().is_ok_and(|kind| kind.is_dir()) {
                count += 1;
                let bytes = dir_size(&child.path(), &HashSet::new());
                sizes.insert(canonical_lossy(&child.path()), bytes);
                bytes
            } else {
                file_bytes(&child.path())
            };
            total += bytes;
        }
        if let Some(entry) = projects.get_mut(&name) {
            entry.worktrees = total;
            entry.worktree_count = count;
        }
    }
    for wt in discovered {
        let name = project_of(&wt.path, &root);
        if let (Some(entry), Some(repo)) = (projects.get_mut(&name), &wt.repo_path)
            && entry.repo_path.is_none()
        {
            entry.repo_path = Some(repo.to_string_lossy().into_owned());
        }
    }
    let space_paths: HashMap<&str, &str> = spaces
        .iter()
        .map(|s| (s.id.as_str(), s.path.as_str()))
        .collect();
    let chat_project: HashMap<String, String> = chats
        .iter()
        .filter_map(|chat| {
            let from_cwd = chat.cwd.as_deref().and_then(|cwd| {
                let cwd = canonical_lossy(Path::new(cwd));
                cwd.starts_with(&root).then(|| project_of(&cwd, &root))
            });
            let from_space = || {
                chat.space_id
                    .as_deref()
                    .and_then(|id| space_paths.get(id))
                    .and_then(|path| Path::new(path).file_name())
                    .map(|n| n.to_string_lossy().into_owned())
            };
            Some((sanitize_id(&chat.id), from_cwd.or_else(from_space)?))
        })
        .collect();
    let mut store_roots: Vec<PathBuf> = Vec::new();
    for org in std::fs::read_dir(data.join("orgs"))
        .into_iter()
        .flatten()
        .flatten()
    {
        for user in std::fs::read_dir(org.path())
            .into_iter()
            .flatten()
            .flatten()
        {
            if user.file_type().is_ok_and(|kind| kind.is_dir()) {
                store_roots.push(user.path());
            }
        }
    }
    for profile in std::fs::read_dir(data.join("profiles"))
        .into_iter()
        .flatten()
        .flatten()
    {
        if profile.file_type().is_ok_and(|kind| kind.is_dir()) {
            store_roots.push(profile.path());
        }
    }
    if let Some(store) = store_root {
        let store = canonical_lossy(store);
        if !store_roots.iter().any(|p| canonical_lossy(p) == store) {
            store_roots.push(store);
        }
    }
    for store in &store_roots {
        let canonical = canonical_lossy(store);
        skip.insert(canonical.clone());
        let mut inner_skip = skip.clone();
        inner_skip.insert(canonical.join("uploads"));
        inner_skip.insert(canonical.join("journals"));
        app.uploads += dir_size(&canonical.join("uploads"), &skip);
        app.other += dir_size(&canonical, &inner_skip);
        for entry in std::fs::read_dir(canonical.join("journals"))
            .into_iter()
            .flatten()
            .flatten()
        {
            let path = entry.path();
            let bytes = if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                dir_size(&path, &skip)
            } else {
                file_bytes(&path)
            };
            let owner = path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|stem| chat_project.get(stem));
            match owner {
                Some(name) => {
                    project(&mut projects, name);
                    if let Some(entry) = projects.get_mut(name) {
                        entry.journals += bytes;
                    }
                }
                None => app.other += bytes,
            }
        }
    }
    for entry in std::fs::read_dir(&data).into_iter().flatten().flatten() {
        let path = canonical_lossy(&entry.path());
        let name = entry.file_name().to_string_lossy().into_owned();
        if skip.contains(&path) || name == "orgs" || name == "profiles" {
            continue;
        }
        let bytes = if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            dir_size(&path, &skip)
        } else {
            file_bytes(&path)
        };
        match name.as_str() {
            "updates" => app.updates += bytes,
            "templates" => app.templates += bytes,
            "plugins" => app.plugins += bytes,
            "logs" => app.logs += bytes,
            "uploads" => app.uploads += bytes,
            _ => app.other += bytes,
        }
    }
    for dir in ["orgs", "profiles"] {
        let mut leftovers_skip = skip.clone();
        leftovers_skip.extend(store_roots.iter().map(|p| canonical_lossy(p)));
        app.other += dir_size(&data.join(dir), &leftovers_skip);
    }
    for (name, space_path) in spaces.iter().filter_map(|s| {
        Path::new(&s.path)
            .file_name()
            .map(|n| (n.to_string_lossy().into_owned(), s.path.clone()))
    }) {
        if let Some(entry) = projects.get_mut(&name)
            && entry.repo_path.is_none()
        {
            entry.repo_path = Some(space_path);
        }
    }
    let mut projects: Vec<ProjectUsage> = projects
        .into_values()
        .map(|mut p| {
            p.total = p.worktrees + p.journals;
            p
        })
        .filter(|p| p.total > 0 || p.worktree_count > 0)
        .collect();
    projects.sort_by(|a, b| b.total.cmp(&a.total).then_with(|| a.name.cmp(&b.name)));
    let total = app.total() + projects.iter().map(|p| p.total).sum::<u64>();
    (
        StorageUsage {
            computed_at: chrono::Utc::now().timestamp_millis(),
            total,
            root: data_dir.to_string_lossy().into_owned(),
            app,
            projects,
        },
        sizes,
    )
}

fn file_bytes(path: &Path) -> u64 {
    std::fs::symlink_metadata(path)
        .map(|m| disk_bytes(&m))
        .unwrap_or(0)
}

fn disk_bytes(meta: &std::fs::Metadata) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        meta.blocks() * 512
    }
    #[cfg(not(unix))]
    {
        meta.len()
    }
}

/// Bytes under `path` without following symlinks, skipping `skip` subtrees.
fn dir_size(path: &Path, skip: &HashSet<PathBuf>) -> u64 {
    let mut total = 0;
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if dir != path && skip.contains(&dir) {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if meta.is_dir() {
                let child = entry.path();
                if !skip.contains(&child) {
                    stack.push(child);
                }
            } else {
                total += disk_bytes(&meta);
            }
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dir_size_skips_subtrees_and_symlinks() {
        let tmp = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(tmp.path().join("a/b")).expect("dirs");
        std::fs::write(tmp.path().join("a/one"), vec![1u8; 10_000]).expect("one");
        std::fs::write(tmp.path().join("a/b/two"), vec![1u8; 10_000]).expect("two");
        #[cfg(unix)]
        std::os::unix::fs::symlink(tmp.path().join("a"), tmp.path().join("link")).expect("link");
        let all = dir_size(tmp.path(), &HashSet::new());
        let skip: HashSet<PathBuf> = [tmp.path().join("a/b")].into_iter().collect();
        let partial = dir_size(tmp.path(), &skip);
        assert!(all >= 20_000);
        assert!(partial < all && partial >= 10_000);
    }
}
