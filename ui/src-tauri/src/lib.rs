mod sidecar;

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

fn sidecar_error_payload(e: sidecar::SidecarError) -> String {
    let v = match e {
        sidecar::SidecarError::Rpc { code, message } => json!({ "code": code, "message": message }),
        err => json!({ "code": null, "message": err.to_string() }),
    };
    serde_json::to_string(&v).unwrap_or_else(|_| "unknown sidecar error".into())
}

#[tauri::command]
async fn list_libraries() -> Result<Value, String> {
    sidecar::call("list_libraries", json!({})).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_library(name: String) -> Result<Value, String> {
    sidecar::call("get_library", json!({ "name": name })).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_clip_transcripts(library: String, video: String) -> Result<Value, String> {
    sidecar::call("get_clip_transcripts", json!({ "library": library, "video": video }))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_or_generate_thumbnail(library: String, video: String) -> Result<Value, String> {
    sidecar::call("get_or_generate_thumbnail", json!({ "library": library, "video": video }))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn allow_video_paths(app: tauri::AppHandle, root: String) -> Result<(), String> {
    if root.is_empty() {
        return Err("root cannot be empty".into());
    }
    let root_path = Path::new(&root);
    if !root_path.is_absolute() {
        return Err("root must be an absolute path".into());
    }
    app.asset_protocol_scope()
        .allow_directory(root_path, true)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn inspect_video_paths(paths: Vec<String>) -> Result<Value, String> {
    sidecar::call("inspect_video_paths", json!({ "paths": paths }))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_library(
    name: String,
    language: String,
    language_code: String,
    refinement: bool,
    videos: Value,
) -> Result<Value, String> {
    sidecar::call(
        "create_library",
        json!({
            "name": name,
            "language": language,
            "language_code": language_code,
            "refinement": refinement,
            "videos": videos
        }),
    )
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
async fn has_api_key() -> Result<Value, String> {
    sidecar::call("has_api_key", json!({})).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn set_api_key(key: String) -> Result<Value, String> {
    sidecar::call("set_api_key", json!({ "key": key }))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn start_analysis(library: String) -> Result<Value, String> {
    sidecar::call("start_analysis", json!({ "library": library }))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn cancel_job(job_id: String) -> Result<Value, String> {
    sidecar::call("cancel_job", json!({ "job_id": job_id }))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn apply_transcript_edit(library: String, clip: String, edit: Value) -> Result<Value, String> {
    sidecar::call(
        "apply_transcript_edit",
        json!({ "library": library, "clip": clip, "edit": edit }),
    )
    .await
    .map_err(sidecar_error_payload)
}

#[tauri::command]
async fn find_transcript_matches(
    library: String,
    tokens: Vec<String>,
    scope: String,
    clip: Option<String>,
) -> Result<Value, String> {
    sidecar::call(
        "find_transcript_matches",
        json!({ "library": library, "tokens": tokens, "scope": scope, "clip": clip }),
    )
    .await
    .map_err(sidecar_error_payload)
}

#[tauri::command]
async fn apply_library_replace(
    library: String,
    old_tokens: Vec<String>,
    new_tokens: Vec<String>,
    trust: bool,
) -> Result<Value, String> {
    sidecar::call(
        "apply_library_replace",
        json!({
            "library": library,
            "old_tokens": old_tokens,
            "new_tokens": new_tokens,
            "trust": trust
        }),
    )
    .await
    .map_err(sidecar_error_payload)
}

#[tauri::command]
async fn open_new_project_window(app: tauri::AppHandle) -> Result<(), String> {
    let label = "new-project";
    if let Some(existing) = app.get_webview_window(label) {
        existing.set_focus().map_err(|e| e.to_string())?;
        return Ok(());
    }
    WebviewWindowBuilder::new(&app, label, WebviewUrl::App("index.html#/new-project".into()))
        .title("New Project")
        .inner_size(880.0, 720.0)
        .min_inner_size(640.0, 540.0)
        .build()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn open_library_window(app: tauri::AppHandle, name: String) -> Result<(), String> {
    let label = library_window_label(&name);

    if let Some(existing) = app.get_webview_window(&label) {
        existing.set_focus().map_err(|e| e.to_string())?;
        return Ok(());
    }

    let url = format!("index.html#/library/{}", urlencoding::encode(&name));
    WebviewWindowBuilder::new(&app, &label, WebviewUrl::App(url.into()))
        .title(&name)
        .inner_size(1100.0, 720.0)
        .min_inner_size(720.0, 480.0)
        .build()
        .map_err(|e| e.to_string())?;

    Ok(())
}

fn library_window_label(name: &str) -> String {
    // Tauri labels accept only [A-Za-z0-9_-]. sanitize alone collapses distinct
    // names ("A B", "A/B", "A?B" → "A_B"); a hash suffix keeps labels unique.
    let mut hasher = DefaultHasher::new();
    name.hash(&mut hasher);
    format!("library-{}-{:x}", sanitize_label(name), hasher.finish())
}

fn sanitize_label(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let (ruby_bin, sidecar_script, libraries_root) = resolve_sidecar_paths()?;

            // Grant assetProtocol scope to the libraries root so generated
            // thumbnails (libraries/<name>/thumbnails/*.jpg) load via convertFileSrc.
            // Per-library video paths are granted later via `allow_video_paths`.
            app.asset_protocol_scope()
                .allow_directory(&libraries_root, true)?;

            let app_handle = app.handle().clone();
            // tokio::process::Command needs a running reactor; setup() runs before one exists.
            tauri::async_runtime::block_on(async move {
                sidecar::init(
                    app_handle,
                    ruby_bin,
                    sidecar_script,
                    libraries_root,
                )
            })?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_libraries,
            get_library,
            get_clip_transcripts,
            get_or_generate_thumbnail,
            allow_video_paths,
            open_library_window,
            open_new_project_window,
            inspect_video_paths,
            create_library,
            has_api_key,
            set_api_key,
            start_analysis,
            cancel_job,
            apply_transcript_edit,
            find_transcript_matches,
            apply_library_replace
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn resolve_sidecar_paths() -> Result<(PathBuf, PathBuf, PathBuf), Box<dyn std::error::Error>> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let ui_dir = manifest_dir.parent().ok_or("ui dir not found")?;
    let repo_root = ui_dir.parent().ok_or("repo root not found")?;

    let ruby_bin = std::env::var("BUTTERCUT_RUBY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("ruby"));

    let sidecar_script = ui_dir.join("sidecar").join("buttercut_ui_sidecar.rb");
    let libraries_root = std::env::var("BUTTERCUT_LIBRARIES_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root.join("libraries"));

    Ok((ruby_bin, sidecar_script, libraries_root))
}
