use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use naive_engine::{EngineCore, HarnessRegistry};
use naive_rpc::methods;

async fn git(cwd: &Path, args: &[&str]) -> String {
    let output = tokio::process::Command::new("git")
        .args(args)
        .current_dir(cwd)
        .env("GIT_AUTHOR_NAME", "test")
        .env("GIT_AUTHOR_EMAIL", "test@test")
        .env("GIT_COMMITTER_NAME", "test")
        .env("GIT_COMMITTER_EMAIL", "test@test")
        .output()
        .await
        .expect("git spawns");
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn row<'a>(rows: &'a serde_json::Value, path: &str) -> &'a serde_json::Value {
    let want = std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
    rows.as_array()
        .expect("rows")
        .iter()
        .find(|row| {
            let got = PathBuf::from(row["path"].as_str().expect("path"));
            got == want || got.file_name() == want.file_name()
        })
        .unwrap_or_else(|| panic!("no row for {path} in {rows:#}"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn storage_rpcs_list_remove_and_clean_worktrees() {
    let tmp = tempfile::tempdir().expect("tempdir");
    unsafe { std::env::set_var("NAIVE_WORKTREES_DIR", tmp.path().join("worktrees")) };
    let data_dir = tmp.path().join("data");
    std::fs::create_dir_all(&data_dir).expect("data dir");
    let core = EngineCore::assemble(
        &data_dir,
        Arc::new(HarnessRegistry::new()),
        naive_proto::HarnessId::Mock,
        None,
    )
    .expect("engine assembles");
    let client = naive_rpc::memory_client(core.rpc_service());

    let created = client
        .call(methods::CREATE_REPO, serde_json::json!({ "name": "demo" }))
        .await
        .expect("CreateRepo");
    let repo_path = created["path"].as_str().expect("repo path").to_string();
    let repo_dir = PathBuf::from(&repo_path);
    std::fs::write(repo_dir.join("file.txt"), "hello\n").expect("seed");
    git(&repo_dir, &["add", "."]).await;
    git(&repo_dir, &["commit", "-m", "seed"]).await;

    let mut paths = Vec::new();
    for _ in 0..5 {
        let worktree = client
            .call(
                methods::CREATE_WORKTREE,
                serde_json::json!({ "repoPath": repo_path, "branch": "main" }),
            )
            .await
            .expect("CreateWorktree");
        paths.push(worktree["path"].as_str().expect("path").to_string());
    }
    let [active, archived, stale, missing, deleted] = <[String; 5]>::try_from(paths).unwrap();

    core.workspace
        .create_chat(
            "chat-active",
            None,
            Some(&core.device_id),
            None,
            Some(active.clone()),
        )
        .expect("active chat");
    core.workspace
        .create_chat(
            "chat-archived",
            None,
            Some(&core.device_id),
            None,
            Some(archived.clone()),
        )
        .expect("archived chat");
    core.workspace
        .set_chat_archived("chat-archived", true)
        .expect("archive");
    core.workspace
        .create_chat(
            "chat-deleted",
            None,
            Some(&core.device_id),
            None,
            Some(deleted.clone()),
        )
        .expect("deleted chat");
    std::fs::write(PathBuf::from(&archived).join("scratch.txt"), "wip\n").expect("dirty");
    let missing_branch = git(Path::new(&missing), &["branch", "--show-current"]).await;
    std::fs::remove_dir_all(&missing).expect("remove missing dir");

    let index = data_dir.join("storage-chat-cwds.json");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !std::fs::read_to_string(&index).is_ok_and(|raw| raw.contains("chat-deleted")) {
        assert!(
            tokio::time::Instant::now() < deadline,
            "chat index never recorded"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    core.workspace
        .delete_chat("chat-deleted")
        .expect("delete chat");

    let rows = client
        .call(methods::LIST_STORAGE_WORKTREES, serde_json::json!({}))
        .await
        .expect("ListStorageWorktrees");
    assert_eq!(rows.as_array().map(Vec::len), Some(5), "{rows:#}");
    assert_eq!(row(&rows, &active)["chatState"], "active");
    assert_eq!(row(&rows, &active)["chatId"], "chat-active");
    assert_eq!(row(&rows, &active)["dirty"], false);
    assert_eq!(row(&rows, &active)["project"], "demo");
    assert_eq!(row(&rows, &active)["unpushed"], 0);
    assert!(
        row(&rows, &active)["branch"]
            .as_str()
            .unwrap()
            .starts_with("naive/")
    );
    assert_eq!(row(&rows, &archived)["chatState"], "archived");
    assert_eq!(row(&rows, &archived)["dirty"], true);
    assert_eq!(row(&rows, &stale)["chatState"], "none");
    assert_eq!(row(&rows, &stale)["missing"], false);
    assert_eq!(row(&rows, &missing)["missing"], true);
    assert_eq!(row(&rows, &deleted)["chatState"], "deleted");
    assert_eq!(row(&rows, &deleted)["chatId"], "chat-deleted");

    let refused = client
        .call(
            methods::REMOVE_WORKTREE,
            serde_json::json!({ "path": archived }),
        )
        .await
        .expect_err("dirty worktree refused");
    assert!(
        refused
            .to_string()
            .contains("Worktree has uncommitted changes"),
        "{refused}"
    );
    assert!(PathBuf::from(&archived).exists());
    let outside = client
        .call(
            methods::REMOVE_WORKTREE,
            serde_json::json!({ "path": repo_path }),
        )
        .await;
    assert!(
        outside.is_err(),
        "the main checkout is outside the worktrees root"
    );
    assert!(repo_dir.join("file.txt").exists());

    let removed = client
        .call(
            methods::REMOVE_WORKTREE,
            serde_json::json!({ "path": missing }),
        )
        .await
        .expect("RemoveWorktree missing");
    assert_eq!(removed["freedBytes"], 0);
    let branches = git(&repo_dir, &["branch", "--list", &missing_branch]).await;
    assert!(
        branches.is_empty(),
        "a gone worktree's branch is deleted: {branches}"
    );

    let cleaned = client
        .call(
            methods::CLEAN_STORAGE,
            serde_json::json!({ "action": "staleWorktrees" }),
        )
        .await
        .expect("CleanStorage staleWorktrees");
    assert_eq!(cleaned["removed"], 2, "{cleaned:#}");
    assert!(!PathBuf::from(&stale).exists());
    assert!(!PathBuf::from(&deleted).exists());
    assert!(PathBuf::from(&active).exists());
    assert!(
        PathBuf::from(&archived).exists(),
        "dirty worktrees are skipped"
    );

    let forced = client
        .call(
            methods::REMOVE_WORKTREE,
            serde_json::json!({ "path": archived, "force": true }),
        )
        .await
        .expect("forced RemoveWorktree");
    assert!(forced["freedBytes"].as_u64().is_some());
    assert!(!PathBuf::from(&archived).exists());

    let usage = client
        .call(
            methods::GET_STORAGE_USAGE,
            serde_json::json!({ "refresh": true }),
        )
        .await
        .expect("GetStorageUsage");
    let demo = usage["projects"]
        .as_array()
        .expect("projects")
        .iter()
        .find(|p| p["name"] == "demo")
        .unwrap_or_else(|| panic!("demo project in {usage:#}"));
    assert_eq!(demo["worktreeCount"], 1);
    assert!(demo["worktrees"].as_u64().unwrap() > 0);
    assert!(usage["total"].as_u64().unwrap() >= demo["total"].as_u64().unwrap());
    let rows = client
        .call(methods::LIST_STORAGE_WORKTREES, serde_json::json!({}))
        .await
        .expect("ListStorageWorktrees after usage");
    assert!(row(&rows, &active)["bytes"].as_u64().is_some());

    let journals = core
        .uploads
        .dir()
        .parent()
        .expect("store root")
        .join("journals");
    std::fs::create_dir_all(&journals).expect("journals");
    std::fs::write(journals.join("gone-chat.jsonl"), "{}\n").expect("orphan journal");
    std::fs::write(journals.join("gone-chat.resume"), "1").expect("orphan sidecar");
    std::fs::write(journals.join("chat-active.jsonl"), "{}\n").expect("live journal");
    let cleaned = client
        .call(
            methods::CLEAN_STORAGE,
            serde_json::json!({ "action": "deletedChatData" }),
        )
        .await
        .expect("CleanStorage deletedChatData");
    assert_eq!(cleaned["removed"], 2, "{cleaned:#}");
    assert!(journals.join("chat-active.jsonl").exists());
    assert!(!journals.join("gone-chat.jsonl").exists());

    core.workspace
        .create_chat("chat-old", None, Some(&core.device_id), None, None)
        .expect("old chat");
    core.workspace
        .set_chat_archived("chat-old", true)
        .expect("archive old");
    let old = chrono::Utc::now().timestamp_millis() - 90 * 24 * 3600 * 1000;
    core.workspace
        .set_chat_activity("chat-old", Some(old), Some(old))
        .expect("backdate");
    let cleaned = client
        .call(
            methods::CLEAN_STORAGE,
            serde_json::json!({ "action": "archivedChats", "olderThanDays": 30 }),
        )
        .await
        .expect("CleanStorage archivedChats");
    assert_eq!(cleaned["removed"], 1, "{cleaned:#}");
    assert!(core.workspace.chat_deleted("chat-old"));
    assert!(
        !core.workspace.chat_deleted("chat-archived"),
        "recent archived chats stay"
    );

    std::fs::create_dir_all(data_dir.join("updates/0.0.1/Naive.app")).expect("old stage");
    std::fs::create_dir_all(data_dir.join("updates/999.0.0")).expect("pending stage");
    let cleaned = client
        .call(
            methods::CLEAN_STORAGE,
            serde_json::json!({ "action": "stagedUpdate" }),
        )
        .await
        .expect("CleanStorage stagedUpdate");
    assert_eq!(cleaned["removed"], 1, "{cleaned:#}");
    assert!(!data_dir.join("updates/0.0.1").exists());
    assert!(data_dir.join("updates/999.0.0").exists());
}
