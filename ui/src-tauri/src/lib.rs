mod sidecar;

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

use serde_json::{json, Value};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

#[tauri::command]
async fn list_libraries() -> Result<Value, String> {
    sidecar::call("list_libraries", json!({}))
        .await
        .map_err(|e| e.to_string())
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
        .setup(|_app| {
            let (ruby_bin, sidecar_script, libraries_root) = resolve_sidecar_paths()?;
            // tokio::process::Command needs a running reactor; setup() runs before one exists.
            tauri::async_runtime::block_on(async move {
                sidecar::init(ruby_bin, sidecar_script, libraries_root)
            })?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![list_libraries, open_library_window])
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
