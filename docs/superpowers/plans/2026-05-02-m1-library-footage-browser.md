# M1 — Library Footage Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the M0 Library window placeholder with a read-only footage browser: clip grid on the left, screenplay-style interleaved transcript on the right with an inline player and click-to-scrub.

**Architecture:** Same three tiers as M0 (React → Tauri Rust → Ruby sidecar over JSON-RPC stdio). M1 adds three sidecar methods, four Tauri commands, an assetProtocol scope mechanism, and a multi-component Library route. Video and thumbnails load directly via Tauri's `assetProtocol` (no IPC streaming).

**Tech Stack:** Tauri 2 (Rust), React 19 + TypeScript + Vite, Ruby 3+ stdlib, ffmpeg (shell-out from sidecar), RSpec for sidecar tests, plain `cargo check` for Rust verification.

**Source spec:** `docs/superpowers/specs/2026-05-02-m1-library-footage-browser-design.md`

---

## File map

**New:**
- `ui/sidecar/spec/spec_helper.rb` — minimal rspec config
- `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb` — rspec coverage for the three new methods
- `ui/sidecar/spec/fixtures/library_fixture.rb` — helper that builds a tmpdir library
- `ui/sidecar/Rakefile` — `rake spec` task wiring
- `ui/src/routes/library/index.tsx` — Library window entry, owns data hooks
- `ui/src/routes/library/ClipGrid.tsx` — left pane, grid of cards
- `ui/src/routes/library/ClipCard.tsx` — single card with lazy thumbnail
- `ui/src/routes/library/StageZone.tsx` — top-right player + summary
- `ui/src/routes/library/TranscriptZone.tsx` — bottom-right interleaved transcript
- `ui/src/routes/library/types.ts` — TS shapes mirroring sidecar JSON
- `ui/src/routes/library/library.css` — all Library window styles
- `ui/src/routes/library/useThumbnail.ts` — IntersectionObserver hook
- `ui/src/routes/library/interleave.ts` — interleave audio+visual segments

**Modified:**
- `ui/sidecar/buttercut_ui_sidecar.rb` — add `get_library`, `get_clip_transcripts`, `get_or_generate_thumbnail`
- `ui/src-tauri/Cargo.toml` — add `urlencoding` already present; add nothing new
- `ui/src-tauri/src/lib.rs` — three new RPC wrappers, `allow_video_paths` command, startup asset scope grant for libraries root, store `libraries_root` so the command can validate
- `ui/src-tauri/tauri.conf.json` — enable `assetProtocol`, add `media-src` to CSP
- `ui/src-tauri/capabilities/default.json` — add asset protocol permissions
- `ui/src/ipc/sidecar.ts` — typed wrappers for the new commands
- `ui/src/main.tsx` — import path update for `./routes/library`

**Deleted:**
- `ui/src/routes/library.tsx` (replaced by the directory)
- `ui/src/routes/library.css` (replaced by the directory's library.css)

---

## Task 1: RSpec scaffolding for the sidecar

**Files:**
- Create: `ui/sidecar/Rakefile`
- Create: `ui/sidecar/spec/spec_helper.rb`
- Create: `ui/sidecar/spec/fixtures/library_fixture.rb`

- [ ] **Step 1: Create `ui/sidecar/Rakefile`**

```ruby
require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
task default: :spec
```

- [ ] **Step 2: Create `ui/sidecar/spec/spec_helper.rb`**

```ruby
$LOAD_PATH.unshift File.expand_path("..", __dir__)

RSpec.configure do |c|
  c.expect_with(:rspec) { |e| e.syntax = :expect }
  c.disable_monkey_patching!
  c.warnings = true
  c.order = :random
end
```

- [ ] **Step 3: Create `ui/sidecar/spec/fixtures/library_fixture.rb`**

```ruby
require "fileutils"
require "tmpdir"
require "yaml"

module LibraryFixture
  def self.build(libraries_root, name:, videos: [], footage_summary: "")
    lib_dir = File.join(libraries_root, name)
    FileUtils.mkdir_p(File.join(lib_dir, "transcripts"))
    FileUtils.mkdir_p(File.join(lib_dir, "summaries"))
    FileUtils.mkdir_p(File.join(lib_dir, "thumbnails"))

    yaml = {
      "library_name" => name,
      "language" => "english",
      "footage_summary" => footage_summary,
      "videos" => videos.map do |v|
        {
          "path" => v[:path],
          "duration" => v[:duration] || "00:00:30",
          "transcript" => v[:transcript] || "",
          "visual_transcript" => v[:visual_transcript] || "",
          "summary" => v[:summary] || ""
        }
      end
    }
    File.write(File.join(lib_dir, "library.yaml"), YAML.dump(yaml))
    lib_dir
  end

  def self.write_audio_transcript(lib_dir, basename, segments:)
    path = File.join(lib_dir, "transcripts", basename)
    File.write(path, JSON.generate({ language: "en", video_path: "n/a", segments: segments }))
    path
  end

  def self.write_visual_transcript(lib_dir, basename, segments:)
    path = File.join(lib_dir, "transcripts", basename)
    File.write(path, JSON.generate({ language: "en", video_path: "n/a", segments: segments }))
    path
  end

  def self.write_summary(lib_dir, basename, body:)
    path = File.join(lib_dir, "summaries", basename)
    File.write(path, body)
    path
  end
end
```

- [ ] **Step 4: Verify rake spec runs (with no specs yet)**

Run: `cd ui/sidecar && bundle exec rake spec 2>&1 || rake spec 2>&1`

Expected: `0 examples, 0 failures` (rspec must already be available via the gem's Gemfile — the gem already declares it). If `rake` is missing, run `gem install rake rspec` once.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/Rakefile ui/sidecar/spec/
git commit -m "M1: rspec scaffold for the UI sidecar"
```

---

## Task 2: Sidecar `get_library`

**Files:**
- Create test: `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb`
- Modify: `ui/sidecar/buttercut_ui_sidecar.rb`

- [ ] **Step 1: Write the failing test**

Create `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb`:

```ruby
require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require_relative "fixtures/library_fixture"
require_relative "../buttercut_ui_sidecar"

RSpec.describe ButtercutUiSidecar do
  def call(libraries_root, method, params = {})
    io_in = StringIO.new(JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params) + "\n")
    io_out = StringIO.new
    ButtercutUiSidecar.run(libraries_root: libraries_root, io_in: io_in, io_out: io_out)
    JSON.parse(io_out.string.lines.last)
  end

  describe "get_library" do
    it "returns library metadata, video list, has_* flags, and the longest common parent" do
      Dir.mktmpdir do |root|
        videos_root = File.join(root, "footage")
        FileUtils.mkdir_p(videos_root)
        video_a = File.join(videos_root, "a.mp4")
        video_b = File.join(videos_root, "b.mp4")
        File.write(video_a, "x")
        File.write(video_b, "x")

        lib = LibraryFixture.build(root,
          name: "demo",
          footage_summary: "Demo footage.",
          videos: [
            { path: video_a, duration: "00:00:10", transcript: "a.json", visual_transcript: "visual_a.json", summary: "summary_a.md" },
            { path: video_b, duration: "00:00:20", transcript: "", visual_transcript: "visual_b.json", summary: "" }
          ])

        result = call(root, "get_library", { name: "demo" })

        expect(result["error"]).to be_nil
        r = result["result"]
        expect(r["name"]).to eq("demo")
        expect(r["footage_summary"]).to eq("Demo footage.")
        expect(r["video_paths_root"]).to eq(videos_root)
        expect(r["videos"].length).to eq(2)

        v0 = r["videos"][0]
        expect(v0["filename"]).to eq("a.mp4")
        expect(v0["path"]).to eq(video_a)
        expect(v0["duration_seconds"]).to eq(10)
        expect(v0["has_audio_transcript"]).to be true
        expect(v0["has_visual_transcript"]).to be true
        expect(v0["has_summary"]).to be true

        v1 = r["videos"][1]
        expect(v1["filename"]).to eq("b.mp4")
        expect(v1["duration_seconds"]).to eq(20)
        expect(v1["has_audio_transcript"]).to be false
        expect(v1["has_visual_transcript"]).to be true
        expect(v1["has_summary"]).to be false
      end
    end

    it "returns an RPC error when the library does not exist" do
      Dir.mktmpdir do |root|
        result = call(root, "get_library", { name: "missing" })
        expect(result["error"]).not_to be_nil
        expect(result["error"]["message"]).to match(/missing/)
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui/sidecar && rake spec`
Expected: 2 failures — `unknown method: get_library` and "missing" message check.

- [ ] **Step 3: Implement `get_library`**

Edit `ui/sidecar/buttercut_ui_sidecar.rb`. Update the `dispatch` method:

```ruby
  def dispatch(method, params)
    case method
    when "ping"           then "pong"
    when "list_libraries" then list_libraries
    when "get_library"    then get_library(params.fetch("name"))
    else raise UnknownMethod, "unknown method: #{method}"
    end
  end
```

Add new private methods (after `summarize_library`):

```ruby
  def get_library(name)
    yaml_path = @libraries_root.join(name, "library.yaml")
    raise ArgumentError, "library not found: #{name}" unless yaml_path.file?

    data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    videos = (data["videos"] || []).map { |v| video_entry(v) }

    {
      name: data["library_name"] || name,
      footage_summary: data["footage_summary"] || "",
      video_paths_root: longest_common_parent(videos.map { |v| v[:path] }),
      videos: videos
    }
  end

  def video_entry(v)
    path = v["path"].to_s
    {
      filename: File.basename(path),
      path: path,
      duration_seconds: parse_duration(v["duration"]),
      has_audio_transcript: present?(v["transcript"]),
      has_visual_transcript: present?(v["visual_transcript"]),
      has_summary: present?(v["summary"])
    }
  end

  def present?(value)
    !value.nil? && !value.to_s.empty?
  end

  def parse_duration(value)
    return 0 if value.nil? || value.to_s.empty?
    parts = value.to_s.split(":").map(&:to_f)
    case parts.length
    when 3 then (parts[0] * 3600 + parts[1] * 60 + parts[2]).to_i
    when 2 then (parts[0] * 60 + parts[1]).to_i
    else parts[0].to_i
    end
  end

  def longest_common_parent(paths)
    return "" if paths.empty?
    parents = paths.map { |p| File.dirname(p).split(File::SEPARATOR) }
    common = parents.first.dup
    parents.each do |segs|
      common.length.times do |i|
        if segs[i] != common[i]
          common = common[0...i]
          break
        end
      end
    end
    common.join(File::SEPARATOR)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ui/sidecar && rake spec`
Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/buttercut_ui_sidecar.rb ui/sidecar/spec/buttercut_ui_sidecar_spec.rb
git commit -m "M1: sidecar get_library"
```

---

## Task 3: Sidecar `get_clip_transcripts`

**Files:**
- Modify test: `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb`
- Modify: `ui/sidecar/buttercut_ui_sidecar.rb`

- [ ] **Step 1: Write the failing test**

Append to the `RSpec.describe ButtercutUiSidecar do` block in `buttercut_ui_sidecar_spec.rb`:

```ruby
  describe "get_clip_transcripts" do
    it "returns audio json, visual json, and summary text when all present" do
      Dir.mktmpdir do |root|
        lib = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json", visual_transcript: "visual_a.json", summary: "summary_a.md" }])
        LibraryFixture.write_audio_transcript(lib, "a.json", segments: [{ start: 0, end: 1, text: "hi" }])
        LibraryFixture.write_visual_transcript(lib, "visual_a.json", segments: [{ start: 0, end: 1, visual: "scene" }])
        LibraryFixture.write_summary(lib, "summary_a.md", body: "Overview.")

        r = call(root, "get_clip_transcripts", { library: "demo", video: "a.mp4" })["result"]
        expect(r["audio"]["segments"].first["text"]).to eq("hi")
        expect(r["visual"]["segments"].first["visual"]).to eq("scene")
        expect(r["summary"]).to eq("Overview.")
      end
    end

    it "returns null for any missing artifact" do
      Dir.mktmpdir do |root|
        LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/b.mp4" }])
        r = call(root, "get_clip_transcripts", { library: "demo", video: "b.mp4" })["result"]
        expect(r["audio"]).to be_nil
        expect(r["visual"]).to be_nil
        expect(r["summary"]).to be_nil
      end
    end

    it "returns an RPC error when the video filename is not in the library" do
      Dir.mktmpdir do |root|
        LibraryFixture.build(root, name: "demo", videos: [{ path: "/x/a.mp4" }])
        r = call(root, "get_clip_transcripts", { library: "demo", video: "missing.mp4" })
        expect(r["error"]["message"]).to match(/missing\.mp4/)
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui/sidecar && rake spec`
Expected: 3 new failures — `unknown method: get_clip_transcripts`.

- [ ] **Step 3: Implement `get_clip_transcripts`**

In the `dispatch` method, add:

```ruby
    when "get_clip_transcripts"
      get_clip_transcripts(params.fetch("library"), params.fetch("video"))
```

Add the new private method:

```ruby
  def get_clip_transcripts(library, video)
    yaml_path = @libraries_root.join(library, "library.yaml")
    raise ArgumentError, "library not found: #{library}" unless yaml_path.file?

    data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    entry = (data["videos"] || []).find { |v| File.basename(v["path"].to_s) == video }
    raise ArgumentError, "video not found in #{library}: #{video}" if entry.nil?

    lib_dir = @libraries_root.join(library)
    {
      audio: read_json_if_set(lib_dir.join("transcripts"), entry["transcript"]),
      visual: read_json_if_set(lib_dir.join("transcripts"), entry["visual_transcript"]),
      summary: read_text_if_set(lib_dir.join("summaries"), entry["summary"])
    }
  end

  def read_json_if_set(dir, name)
    return nil unless present?(name)
    path = dir.join(name)
    return nil unless path.file?
    JSON.parse(path.read)
  rescue JSON::ParserError => e
    raise "transcript parse error in #{path}: #{e.message}"
  end

  def read_text_if_set(dir, name)
    return nil unless present?(name)
    path = dir.join(name)
    path.file? ? path.read : nil
  end
```

Add `require "json"` at the top of the file if not already present (it is — keep it).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ui/sidecar && rake spec`
Expected: 5 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/buttercut_ui_sidecar.rb ui/sidecar/spec/buttercut_ui_sidecar_spec.rb
git commit -m "M1: sidecar get_clip_transcripts"
```

---

## Task 4: Sidecar `get_or_generate_thumbnail`

**Files:**
- Modify test: `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb`
- Modify: `ui/sidecar/buttercut_ui_sidecar.rb`

- [ ] **Step 1: Write the failing test**

Append to the spec:

```ruby
  describe "get_or_generate_thumbnail" do
    it "returns the cached path on second call without re-shelling out" do
      Dir.mktmpdir do |root|
        lib = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4" }])

        # Pre-place the cached thumbnail to avoid needing ffmpeg in CI.
        cached = File.join(lib, "thumbnails", "a.jpg")
        File.write(cached, "fake-jpg-bytes")

        r = call(root, "get_or_generate_thumbnail", { library: "demo", video: "a.mp4" })["result"]
        expect(r["path"]).to eq(cached)
      end
    end

    it "shells out to ffmpeg on cache miss when ffmpeg is available", skip: !system("which ffmpeg > /dev/null 2>&1") do
      Dir.mktmpdir do |root|
        # Create a 1-second silent test video using ffmpeg.
        videos_root = File.join(root, "footage")
        FileUtils.mkdir_p(videos_root)
        video = File.join(videos_root, "tiny.mp4")
        system("ffmpeg -y -loglevel error -f lavfi -i color=c=red:s=64x64:d=2 -pix_fmt yuv420p #{video}")

        LibraryFixture.build(root, name: "demo", videos: [{ path: video }])
        r = call(root, "get_or_generate_thumbnail", { library: "demo", video: "tiny.mp4" })["result"]

        expect(File.file?(r["path"])).to be true
        expect(File.size(r["path"])).to be > 0
      end
    end

    it "returns an RPC error when the source video file is missing" do
      Dir.mktmpdir do |root|
        LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/nonexistent/missing.mp4" }])
        r = call(root, "get_or_generate_thumbnail", { library: "demo", video: "missing.mp4" })
        expect(r["error"]["message"]).to match(/missing\.mp4/)
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui/sidecar && rake spec`
Expected: 3 new failures (one may skip if ffmpeg absent — that's fine).

- [ ] **Step 3: Implement `get_or_generate_thumbnail`**

In the `dispatch` method, add:

```ruby
    when "get_or_generate_thumbnail"
      get_or_generate_thumbnail(params.fetch("library"), params.fetch("video"))
```

Add the new private method:

```ruby
  def get_or_generate_thumbnail(library, video)
    yaml_path = @libraries_root.join(library, "library.yaml")
    raise ArgumentError, "library not found: #{library}" unless yaml_path.file?

    data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    entry = (data["videos"] || []).find { |v| File.basename(v["path"].to_s) == video }
    raise ArgumentError, "video not found in #{library}: #{video}" if entry.nil?

    cache_dir = @libraries_root.join(library, "thumbnails")
    cache_dir.mkpath
    out_path = cache_dir.join("#{File.basename(video, ".*")}.jpg")
    return { path: out_path.to_s } if out_path.file?

    source = Pathname.new(entry["path"].to_s)
    raise "source video missing: #{video} (expected at #{source})" unless source.file?

    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-ss", "1", "-i", source.to_s,
           "-frames:v", "1", "-q:v", "4", out_path.to_s]
    ok = system(*cmd)
    raise "ffmpeg failed for #{video}" unless ok && out_path.file?

    { path: out_path.to_s }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ui/sidecar && rake spec`
Expected: 8 examples, 0 failures (or 7 + 1 skipped if ffmpeg absent).

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/buttercut_ui_sidecar.rb ui/sidecar/spec/buttercut_ui_sidecar_spec.rb
git commit -m "M1: sidecar get_or_generate_thumbnail"
```

---

## Task 5: Tauri config — assetProtocol + CSP

**Files:**
- Modify: `ui/src-tauri/tauri.conf.json`
- Modify: `ui/src-tauri/capabilities/default.json`

- [ ] **Step 1: Edit `ui/src-tauri/tauri.conf.json`**

Replace the entire `"security"` block (currently `"security": { "csp": { ... } }`) with:

```json
    "security": {
      "csp": {
        "default-src": "'self' ipc: http://ipc.localhost",
        "img-src": "'self' asset: http://asset.localhost data:",
        "media-src": "'self' asset: http://asset.localhost",
        "font-src": "'self' data:",
        "style-src": "'self' 'unsafe-inline'",
        "connect-src": "'self' ipc: http://ipc.localhost"
      },
      "assetProtocol": {
        "enable": true,
        "scope": []
      }
    }
```

- [ ] **Step 2: Edit `ui/src-tauri/capabilities/default.json`**

Add asset-protocol permissions to the `permissions` array:

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "description": "Capabilities for all ButterCut windows",
  "windows": ["main", "library-*"],
  "permissions": [
    "core:default",
    "opener:default",
    "core:webview:allow-create-webview-window",
    "core:window:allow-set-title",
    "core:asset:default",
    "core:asset:allow-read"
  ]
}
```

- [ ] **Step 3: Verify cargo check is still green**

Run: `cd ui/src-tauri && cargo check --message-format=short 2>&1 | tail -5`
Expected: `Finished 'dev' profile`. If a permission name is wrong, `cargo check` will error with a parsable message — adjust the permission identifiers per the suggestion.

- [ ] **Step 4: Commit**

```bash
git add ui/src-tauri/tauri.conf.json ui/src-tauri/capabilities/default.json
git commit -m "M1: enable assetProtocol and widen CSP for media playback"
```

---

## Task 6: Tauri Rust — RPC wrappers, `allow_video_paths`, startup scope grant

**Files:**
- Modify: `ui/src-tauri/src/lib.rs`

- [ ] **Step 1: Replace `lib.rs` with the M1 version**

Open `ui/src-tauri/src/lib.rs` and replace the entire file with:

```rust
mod sidecar;

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{json, Value};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

struct LibrariesRoot(Mutex<PathBuf>);

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
        .setup(|app| {
            let (ruby_bin, sidecar_script, libraries_root) = resolve_sidecar_paths()?;

            // Grant assetProtocol scope to the libraries root so generated
            // thumbnails (libraries/<name>/thumbnails/*.jpg) load via convertFileSrc.
            // Per-library video paths are granted later via `allow_video_paths`.
            app.asset_protocol_scope()
                .allow_directory(&libraries_root, true)?;

            app.manage(LibrariesRoot(Mutex::new(libraries_root.clone())));

            // tokio::process::Command needs a running reactor; setup() runs before one exists.
            tauri::async_runtime::block_on(async move {
                sidecar::init(ruby_bin, sidecar_script, libraries_root)
            })?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_libraries,
            get_library,
            get_clip_transcripts,
            get_or_generate_thumbnail,
            allow_video_paths,
            open_library_window
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
```

- [ ] **Step 2: Verify cargo check passes**

Run: `cd ui/src-tauri && cargo check --message-format=short 2>&1 | tail -10`
Expected: `Finished 'dev' profile`. If `asset_protocol_scope()` returns a different type than expected (Tauri 2 API has shifted between minor versions), check `tauri::scope::fs::Scope` docs. If `allow_directory` requires a different signature, adjust the calls in both the setup hook and `allow_video_paths` to match.

- [ ] **Step 3: Smoke-test the new commands via the sidecar directly**

Run:
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"get_library","params":{"name":"march-30-workout"}}' \
  | ruby ui/sidecar/buttercut_ui_sidecar.rb libraries | head -c 300; echo
```
Expected: a JSON object containing `"video_paths_root"` and 11 `videos`, each with `filename`, `path`, `duration_seconds`, and the three `has_*` flags.

- [ ] **Step 4: Commit**

```bash
git add ui/src-tauri/src/lib.rs
git commit -m "M1: tauri commands for library detail, transcripts, thumbnails, asset scope"
```

---

## Task 7: Frontend types + IPC wrappers

**Files:**
- Create: `ui/src/routes/library/types.ts`
- Modify: `ui/src/ipc/sidecar.ts`

- [ ] **Step 1: Create `ui/src/routes/library/types.ts`**

```typescript
export interface VideoEntry {
  filename: string;
  path: string;
  duration_seconds: number;
  has_audio_transcript: boolean;
  has_visual_transcript: boolean;
  has_summary: boolean;
}

export interface LibraryDetail {
  name: string;
  footage_summary: string;
  video_paths_root: string;
  videos: VideoEntry[];
}

export interface AudioWord {
  word: string;
  start: number;
  end: number;
}

export interface AudioSegment {
  start: number;
  end: number;
  text: string;
  words?: AudioWord[];
}

export interface VisualSegment {
  start: number;
  end: number;
  visual: string;
  text?: string;
  b_roll?: boolean;
}

export interface ClipTranscripts {
  audio: { language?: string; segments: AudioSegment[] } | null;
  visual: { language?: string; segments: VisualSegment[] } | null;
  summary: string | null;
}
```

- [ ] **Step 2: Extend `ui/src/ipc/sidecar.ts`**

Replace the file's contents with:

```typescript
import { invoke } from "@tauri-apps/api/core";
import type { ClipTranscripts, LibraryDetail } from "../routes/library/types";

export interface LibrarySummary {
  name: string;
  video_count: number;
  last_touched_at: string;
}

export async function listLibraries(): Promise<LibrarySummary[]> {
  return invoke<LibrarySummary[]>("list_libraries");
}

export async function openLibraryWindow(name: string): Promise<void> {
  await invoke("open_library_window", { name });
}

export async function getLibrary(name: string): Promise<LibraryDetail> {
  return invoke<LibraryDetail>("get_library", { name });
}

export async function getClipTranscripts(library: string, video: string): Promise<ClipTranscripts> {
  return invoke<ClipTranscripts>("get_clip_transcripts", { library, video });
}

export async function getOrGenerateThumbnail(library: string, video: string): Promise<{ path: string }> {
  return invoke<{ path: string }>("get_or_generate_thumbnail", { library, video });
}

export async function allowVideoPaths(root: string): Promise<void> {
  await invoke("allow_video_paths", { root });
}
```

- [ ] **Step 3: Verify the frontend still type-checks**

Run: `cd ui && pnpm build 2>&1 | tail -10`
Expected: `built in NNNms`. The build will succeed even though no consumer imports the new types yet.

- [ ] **Step 4: Commit**

```bash
git add ui/src/routes/library/types.ts ui/src/ipc/sidecar.ts
git commit -m "M1: typed IPC wrappers for library detail, transcripts, thumbnails"
```

---

## Task 8: Replace M0 Library placeholder with directory + bare data hook

**Files:**
- Delete: `ui/src/routes/library.tsx`, `ui/src/routes/library.css`
- Create: `ui/src/routes/library/index.tsx`
- Create: `ui/src/routes/library/library.css`
- Modify: `ui/src/main.tsx`

- [ ] **Step 1: Delete the M0 placeholder**

```bash
rm ui/src/routes/library.tsx ui/src/routes/library.css
```

- [ ] **Step 2: Create `ui/src/routes/library/library.css`** (initial — components will append)

```css
.library {
  min-height: 100vh;
  display: grid;
  grid-template-columns: 340px 1fr;
  background: var(--bg);
  color: var(--text);
}

.library__loading,
.library__error {
  grid-column: 1 / -1;
  padding: 64px 72px;
  font-family: var(--mono);
  font-size: 12px;
  color: var(--text-muted);
}

.library__error pre {
  margin-top: 12px;
  padding: 12px 14px;
  background: var(--surface);
  border: 1px solid var(--hairline);
  border-radius: 4px;
  color: var(--accent-warm);
  white-space: pre-wrap;
}
```

- [ ] **Step 3: Create `ui/src/routes/library/index.tsx`**

```tsx
import { useEffect, useState } from "react";
import { allowVideoPaths, getLibrary } from "../../ipc/sidecar";
import type { LibraryDetail } from "./types";
import "./library.css";

type LoadState =
  | { kind: "loading" }
  | { kind: "ready"; library: LibraryDetail; selected: string }
  | { kind: "error"; message: string };

export default function Library({ name }: { name: string }) {
  const [state, setState] = useState<LoadState>({ kind: "loading" });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const library = await getLibrary(name);
        if (library.video_paths_root) {
          await allowVideoPaths(library.video_paths_root);
        }
        if (cancelled) return;
        const selected = library.videos[0]?.filename ?? "";
        setState({ kind: "ready", library, selected });
      } catch (err) {
        if (!cancelled) setState({ kind: "error", message: String(err) });
      }
    })();
    return () => { cancelled = true; };
  }, [name]);

  if (state.kind === "loading") {
    return <main className="library"><p className="library__loading">Loading {name}…</p></main>;
  }
  if (state.kind === "error") {
    return (
      <main className="library">
        <div className="library__error">
          <p>Couldn't load library "{name}".</p>
          <pre>{state.message}</pre>
        </div>
      </main>
    );
  }

  return (
    <main className="library">
      <p className="library__loading">Loaded {state.library.videos.length} clips. Selected: {state.selected || "(none)"}.</p>
    </main>
  );
}
```

- [ ] **Step 4: Update `ui/src/main.tsx`**

The M0 import path is `./routes/library`. After deleting `library.tsx` and creating `library/index.tsx`, the same import path resolves to the directory's index. Verify the existing import line is exactly:

```typescript
import Library from "./routes/library";
```

If it reads `./routes/library.tsx` or `./routes/library/index`, normalize to `./routes/library`.

- [ ] **Step 5: Verify the build still works and the placeholder text changed**

Run: `cd ui && pnpm build 2>&1 | tail -5`
Expected: `built in NNNms`.

- [ ] **Step 6: Commit**

```bash
git add ui/src/routes/library/ ui/src/main.tsx
git rm ui/src/routes/library.tsx ui/src/routes/library.css
git commit -m "M1: library route directory + bare data hook (loads detail, grants asset scope)"
```

---

## Task 9: ClipCard with lazy thumbnail (`useThumbnail` hook)

**Files:**
- Create: `ui/src/routes/library/useThumbnail.ts`
- Create: `ui/src/routes/library/ClipCard.tsx`
- Modify: `ui/src/routes/library/library.css`

- [ ] **Step 1: Create `ui/src/routes/library/useThumbnail.ts`**

```typescript
import { useEffect, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { getOrGenerateThumbnail } from "../../ipc/sidecar";

type ThumbState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "ready"; src: string }
  | { kind: "error" };

// Lazily resolves a clip thumbnail. Uses IntersectionObserver so cards out
// of view don't trigger ffmpeg shell-outs.
export function useThumbnail(library: string, video: string) {
  const [state, setState] = useState<ThumbState>({ kind: "idle" });
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let cancelled = false;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          observer.disconnect();
          setState({ kind: "loading" });
          getOrGenerateThumbnail(library, video)
            .then(({ path }) => {
              if (!cancelled) setState({ kind: "ready", src: convertFileSrc(path) });
            })
            .catch(() => {
              if (!cancelled) setState({ kind: "error" });
            });
        }
      },
      { rootMargin: "200px" }
    );
    observer.observe(el);
    return () => {
      cancelled = true;
      observer.disconnect();
    };
  }, [library, video]);

  return { ref, state };
}
```

- [ ] **Step 2: Create `ui/src/routes/library/ClipCard.tsx`**

```tsx
import type { VideoEntry } from "./types";
import { useThumbnail } from "./useThumbnail";

interface Props {
  library: string;
  video: VideoEntry;
  selected: boolean;
  onSelect: () => void;
}

export default function ClipCard({ library, video, selected, onSelect }: Props) {
  const { ref, state } = useThumbnail(library, video.filename);
  const fullyAnalyzed = video.has_audio_transcript && video.has_visual_transcript && video.has_summary;
  const partiallyAnalyzed = video.has_audio_transcript || video.has_visual_transcript || video.has_summary;
  const dotClass = fullyAnalyzed ? "clip-card__dot--full" : partiallyAnalyzed ? "clip-card__dot--partial" : "clip-card__dot--none";

  return (
    <button
      ref={ref as unknown as React.RefObject<HTMLButtonElement>}
      className={`clip-card ${selected ? "clip-card--selected" : ""}`}
      onClick={onSelect}
      aria-pressed={selected}
    >
      <div className="clip-card__thumb" data-state={state.kind}>
        {state.kind === "ready" && <img src={state.src} alt="" />}
      </div>
      <div className="clip-card__meta">
        <span className="clip-card__name">{video.filename}</span>
        <span className="clip-card__row">
          <span className="clip-card__duration">{formatDuration(video.duration_seconds)}</span>
          <span className={`clip-card__dot ${dotClass}`} aria-label={analysisLabel(video)} />
        </span>
      </div>
    </button>
  );
}

function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}

function analysisLabel(v: VideoEntry): string {
  const parts: string[] = [];
  if (v.has_audio_transcript) parts.push("audio");
  if (v.has_visual_transcript) parts.push("visual");
  if (v.has_summary) parts.push("summary");
  return parts.length === 0 ? "not analyzed" : `analyzed: ${parts.join(", ")}`;
}
```

- [ ] **Step 3: Append to `ui/src/routes/library/library.css`**

```css
.clip-grid {
  padding: 16px 12px;
  border-right: 1px solid var(--hairline);
  overflow-y: auto;
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
  align-content: start;
}

.clip-card {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 8px;
  padding: 0 0 8px;
  background: var(--surface);
  border: 1px solid var(--hairline);
  border-radius: 4px;
  text-align: left;
  overflow: hidden;
  transition: border-color 120ms ease, background 120ms ease;
}

.clip-card:hover {
  border-color: var(--accent-dim);
  background: var(--surface-raised);
}

.clip-card--selected {
  border-color: var(--accent);
  background: var(--surface-raised);
}

.clip-card:focus-visible {
  outline: 1px solid var(--accent);
  outline-offset: 2px;
}

.clip-card__thumb {
  width: 100%;
  aspect-ratio: 16 / 9;
  background: var(--bg);
  position: relative;
  overflow: hidden;
}

.clip-card__thumb[data-state="loading"]::after,
.clip-card__thumb[data-state="idle"]::after {
  content: "";
  position: absolute;
  inset: 0;
  background: linear-gradient(90deg, transparent, rgba(224, 165, 90, 0.06), transparent);
  animation: shimmer 1.6s linear infinite;
}

.clip-card__thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

@keyframes shimmer {
  0% { transform: translateX(-100%); }
  100% { transform: translateX(100%); }
}

.clip-card__meta {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 0 10px;
}

.clip-card__name {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.clip-card__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.clip-card__duration {
  font-family: var(--mono);
  font-size: 10px;
  color: var(--text-muted);
}

.clip-card__dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
}

.clip-card__dot--full { background: var(--accent-dim); }
.clip-card__dot--partial { background: var(--accent); }
.clip-card__dot--none { background: var(--hairline); }
```

- [ ] **Step 4: Verify build**

Run: `cd ui && pnpm build 2>&1 | tail -5`
Expected: `built in NNNms`.

- [ ] **Step 5: Commit**

```bash
git add ui/src/routes/library/
git commit -m "M1: ClipCard with IntersectionObserver-driven lazy thumbnail"
```

---

## Task 10: ClipGrid + wire selection into Library

**Files:**
- Create: `ui/src/routes/library/ClipGrid.tsx`
- Modify: `ui/src/routes/library/index.tsx`

- [ ] **Step 1: Create `ui/src/routes/library/ClipGrid.tsx`**

```tsx
import ClipCard from "./ClipCard";
import type { VideoEntry } from "./types";

interface Props {
  library: string;
  videos: VideoEntry[];
  selected: string;
  onSelect: (filename: string) => void;
}

export default function ClipGrid({ library, videos, selected, onSelect }: Props) {
  return (
    <div className="clip-grid" role="listbox" aria-label="clips">
      {videos.map((v) => (
        <ClipCard
          key={v.filename}
          library={library}
          video={v}
          selected={v.filename === selected}
          onSelect={() => onSelect(v.filename)}
        />
      ))}
    </div>
  );
}
```

- [ ] **Step 2: Replace the placeholder body in `ui/src/routes/library/index.tsx`**

Replace the current `return (...)` for `state.kind === "ready"` with:

```tsx
  return (
    <main className="library">
      <ClipGrid
        library={state.library.name}
        videos={state.library.videos}
        selected={state.selected}
        onSelect={(filename) => setState({ kind: "ready", library: state.library, selected: filename })}
      />
      <div className="library__detail">
        <p className="library__loading">Detail pane for: {state.selected || "(none)"}</p>
      </div>
    </main>
  );
```

Add the ClipGrid import at the top:

```typescript
import ClipGrid from "./ClipGrid";
```

- [ ] **Step 3: Append to `ui/src/routes/library/library.css`**

```css
.library__detail {
  display: grid;
  grid-template-rows: minmax(220px, 40%) 1fr;
  min-height: 0;
}
```

- [ ] **Step 4: Verify build**

Run: `cd ui && pnpm build 2>&1 | tail -5`
Expected: `built in NNNms`.

- [ ] **Step 5: Commit**

```bash
git add ui/src/routes/library/
git commit -m "M1: ClipGrid + selection wired through Library state"
```

---

## Task 11: StageZone — player + library footage_summary

**Files:**
- Create: `ui/src/routes/library/StageZone.tsx`
- Modify: `ui/src/routes/library/index.tsx`

- [ ] **Step 1: Create `ui/src/routes/library/StageZone.tsx`**

```tsx
import { forwardRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import type { VideoEntry } from "./types";

interface Props {
  video: VideoEntry | undefined;
  footageSummary: string;
}

const StageZone = forwardRef<HTMLVideoElement, Props>(function StageZone({ video, footageSummary }, ref) {
  const [errored, setErrored] = useState(false);

  if (!video) {
    return <div className="stage stage--empty"><p>No clip selected.</p></div>;
  }

  const src = convertFileSrc(video.path);

  return (
    <div className="stage">
      <div className="stage__player">
        {errored ? (
          <div className="stage__missing">
            <p>Can't find the video file.</p>
            <p className="stage__missing-path">Expected at: <code>{video.path}</code></p>
          </div>
        ) : (
          <video
            ref={ref}
            key={video.path}
            src={src}
            controls
            preload="metadata"
            onError={() => setErrored(true)}
          />
        )}
      </div>
      {footageSummary && <FootageSummary text={footageSummary} />}
    </div>
  );
});

function FootageSummary({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className={`stage__summary ${expanded ? "stage__summary--expanded" : ""}`}>
      <p>{text}</p>
      <button className="stage__summary-toggle" onClick={() => setExpanded((v) => !v)}>
        {expanded ? "Show less" : "Show more"}
      </button>
    </div>
  );
}

export default StageZone;
```

- [ ] **Step 2: Update `ui/src/routes/library/index.tsx` to render StageZone and hold a video ref**

Add the import and a ref. Full replacement of the file's `return` for `ready` state:

Add at top of file:

```typescript
import { useRef } from "react";
import StageZone from "./StageZone";
```

And alongside the existing `useState<LoadState>(...)`, add:

```typescript
  const videoRef = useRef<HTMLVideoElement | null>(null);
```

Replace the `state.kind === "ready"` return block with:

```tsx
  const selectedVideo = state.library.videos.find((v) => v.filename === state.selected);

  return (
    <main className="library">
      <ClipGrid
        library={state.library.name}
        videos={state.library.videos}
        selected={state.selected}
        onSelect={(filename) => setState({ kind: "ready", library: state.library, selected: filename })}
      />
      <div className="library__detail">
        <StageZone ref={videoRef} video={selectedVideo} footageSummary={state.library.footage_summary} />
        <div className="transcript-zone">
          <p className="library__loading">Transcript zone placeholder.</p>
        </div>
      </div>
    </main>
  );
```

- [ ] **Step 3: Append to `ui/src/routes/library/library.css`**

```css
.stage {
  display: grid;
  grid-template-rows: 1fr auto;
  gap: 16px;
  padding: 24px 32px 16px;
  border-bottom: 1px solid var(--hairline);
  min-height: 0;
}

.stage--empty {
  align-items: center;
  justify-items: center;
  color: var(--text-muted);
  font-family: var(--mono);
  font-size: 11px;
  letter-spacing: 0.18em;
  text-transform: uppercase;
}

.stage__player {
  background: black;
  border-radius: 4px;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 0;
}

.stage__player video {
  width: 100%;
  height: 100%;
  max-height: 100%;
  object-fit: contain;
  background: black;
}

.stage__missing {
  padding: 32px;
  color: var(--accent-warm);
  font-family: var(--mono);
  font-size: 12px;
  text-align: center;
}

.stage__missing-path {
  margin-top: 8px;
  color: var(--text-muted);
}

.stage__missing-path code {
  font-family: var(--mono);
  color: var(--text);
  word-break: break-all;
}

.stage__summary {
  font-family: var(--display);
  font-style: italic;
  font-size: 14px;
  line-height: 1.5;
  color: var(--text-muted);
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.stage__summary p {
  margin: 0;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.stage__summary--expanded p {
  -webkit-line-clamp: unset;
  overflow: visible;
}

.stage__summary-toggle {
  align-self: flex-start;
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--accent);
  padding: 0;
}
```

- [ ] **Step 4: Verify build**

Run: `cd ui && pnpm build 2>&1 | tail -5`
Expected: `built in NNNms`.

- [ ] **Step 5: Commit**

```bash
git add ui/src/routes/library/
git commit -m "M1: StageZone with assetProtocol player + footage summary disclosure"
```

---

## Task 12: Interleave helper + TranscriptZone

**Files:**
- Create: `ui/src/routes/library/interleave.ts`
- Create: `ui/src/routes/library/TranscriptZone.tsx`
- Modify: `ui/src/routes/library/index.tsx`

- [ ] **Step 1: Create `ui/src/routes/library/interleave.ts`**

```typescript
import type { AudioSegment, VisualSegment } from "./types";

export interface InterleavedRow {
  visual: VisualSegment;
  audio: AudioSegment[];
}

// Groups every audio segment whose start falls inside a visual segment's
// [start, end) interval underneath that visual row. Audio segments that fall
// outside any visual segment are dropped (rare in practice; if it happens
// we'd rather show nothing than orphaned dialogue with no scene context).
export function interleave(visual: VisualSegment[], audio: AudioSegment[]): InterleavedRow[] {
  return visual.map((v) => ({
    visual: v,
    audio: audio.filter((a) => a.start >= v.start && a.start < v.end)
  }));
}

export function formatTimestamp(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}
```

- [ ] **Step 2: Create `ui/src/routes/library/TranscriptZone.tsx`**

```tsx
import { useEffect, useState } from "react";
import { getClipTranscripts } from "../../ipc/sidecar";
import type { ClipTranscripts } from "./types";
import { formatTimestamp, interleave, InterleavedRow } from "./interleave";

interface Props {
  library: string;
  video: string | null;
  onSeek: (seconds: number) => void;
}

type LoadState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "ready"; transcripts: ClipTranscripts }
  | { kind: "error"; message: string };

export default function TranscriptZone({ library, video, onSeek }: Props) {
  const [state, setState] = useState<LoadState>({ kind: "idle" });

  useEffect(() => {
    if (!video) {
      setState({ kind: "idle" });
      return;
    }
    let cancelled = false;
    setState({ kind: "loading" });
    getClipTranscripts(library, video)
      .then((transcripts) => { if (!cancelled) setState({ kind: "ready", transcripts }); })
      .catch((err) => { if (!cancelled) setState({ kind: "error", message: String(err) }); });
    return () => { cancelled = true; };
  }, [library, video]);

  if (state.kind === "idle" || !video) {
    return <div className="transcript-zone transcript-zone--empty">No clip selected.</div>;
  }
  if (state.kind === "loading") {
    return <div className="transcript-zone transcript-zone--empty">Loading transcripts…</div>;
  }
  if (state.kind === "error") {
    return (
      <div className="transcript-zone transcript-zone--empty">
        <p>Couldn't load transcripts.</p>
        <pre>{state.message}</pre>
      </div>
    );
  }

  const visualSegments = state.transcripts.visual?.segments ?? [];
  const audioSegments = state.transcripts.audio?.segments ?? [];

  if (visualSegments.length === 0 && audioSegments.length === 0) {
    return <div className="transcript-zone transcript-zone--empty">This clip hasn't been analyzed yet.</div>;
  }

  const rows = interleave(visualSegments, audioSegments);

  return (
    <div className="transcript-zone">
      {rows.map((row, i) => (
        <Row key={i} row={row} onSeek={onSeek} />
      ))}
    </div>
  );
}

function Row({ row, onSeek }: { row: InterleavedRow; onSeek: (s: number) => void }) {
  return (
    <div className="row">
      <button className="row__visual" onClick={() => onSeek(row.visual.start)}>
        <span className="row__time">[{formatTimestamp(row.visual.start)}]</span>
        <span className="row__visual-text">{row.visual.visual}</span>
        {row.visual.b_roll && <span className="row__chip">b-roll</span>}
      </button>
      {row.audio.map((seg, j) => (
        <AudioRow key={j} segment={seg} onSeek={onSeek} />
      ))}
    </div>
  );
}

function AudioRow({ segment, onSeek }: { segment: import("./types").AudioSegment; onSeek: (s: number) => void }) {
  if (segment.words && segment.words.length > 0) {
    return (
      <p className="row__audio">
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.words.map((w, i) => (
          <button key={i} className="row__word" onClick={() => onSeek(w.start)}>{w.word}</button>
        ))}
      </p>
    );
  }
  return (
    <p className="row__audio">
      <button className="row__audio-text" onClick={() => onSeek(segment.start)}>
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.text}
      </button>
    </p>
  );
}
```

- [ ] **Step 3: Append to `ui/src/routes/library/library.css`**

```css
.transcript-zone {
  overflow-y: auto;
  padding: 20px 32px 48px;
  display: flex;
  flex-direction: column;
  gap: 24px;
}

.transcript-zone--empty {
  font-family: var(--display);
  font-style: italic;
  font-size: 14px;
  color: var(--text-muted);
  padding: 32px;
}

.transcript-zone--empty pre {
  margin-top: 12px;
  padding: 12px 14px;
  background: var(--surface);
  border: 1px solid var(--hairline);
  border-radius: 4px;
  color: var(--accent-warm);
  font-family: var(--mono);
  font-size: 11px;
  font-style: normal;
  white-space: pre-wrap;
}

.row {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.row__visual {
  display: flex;
  align-items: baseline;
  gap: 12px;
  text-align: left;
  padding: 4px 0;
  width: 100%;
  color: var(--text);
  border-radius: 2px;
}

.row__visual:hover { background: var(--surface); }
.row__visual:focus-visible { outline: 1px solid var(--accent); outline-offset: 2px; }

.row__time {
  font-family: var(--mono);
  font-size: 10px;
  color: var(--text-faint);
  flex-shrink: 0;
}

.row__visual-text {
  font-family: var(--display);
  font-style: italic;
  font-size: 15px;
  line-height: 1.5;
  color: var(--text);
}

.row__chip {
  font-family: var(--mono);
  font-size: 9px;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--text-faint);
  border: 1px solid var(--hairline);
  border-radius: 2px;
  padding: 1px 5px;
  align-self: center;
}

.row__audio {
  margin: 0 0 0 24px;
  font-size: 13px;
  line-height: 1.6;
  color: var(--text);
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  align-items: baseline;
}

.row__word,
.row__audio-text {
  font: inherit;
  color: inherit;
  background: none;
  border: none;
  padding: 0 2px;
  cursor: pointer;
}

.row__word:hover,
.row__audio-text:hover { color: var(--accent); }
```

- [ ] **Step 4: Wire TranscriptZone into `ui/src/routes/library/index.tsx`**

Replace the placeholder div for the transcript zone with the component. Add the import:

```typescript
import TranscriptZone from "./TranscriptZone";
```

Replace:

```tsx
        <div className="transcript-zone">
          <p className="library__loading">Transcript zone placeholder.</p>
        </div>
```

with:

```tsx
        <TranscriptZone
          library={state.library.name}
          video={state.selected || null}
          onSeek={(seconds) => {
            const v = videoRef.current;
            if (v) v.currentTime = seconds;
          }}
        />
```

- [ ] **Step 5: Verify build**

Run: `cd ui && pnpm build 2>&1 | tail -5`
Expected: `built in NNNms`.

- [ ] **Step 6: Commit**

```bash
git add ui/src/routes/library/
git commit -m "M1: TranscriptZone with screenplay-style interleaved rows + click-to-scrub"
```

---

## Task 13: End-to-end verification + readme touch-up

**Files:**
- Modify: `ui/README.md`

- [ ] **Step 1: Verify Rust + Ruby + frontend all green**

Run, in order:

```bash
cd ui/sidecar && rake spec 2>&1 | tail -5
cd ../src-tauri && cargo check --message-format=short 2>&1 | tail -5
cd .. && pnpm build 2>&1 | tail -5
```

Expected outputs respectively: `8 examples` (or 7 + 1 skipped), `Finished 'dev' profile`, `built in NNNms`.

- [ ] **Step 2: Manual run-through against `march-30-workout`**

Run: `cd ui && pnpm tauri dev`

In the open app:

1. Click the `march-30-workout` card → Library window opens.
2. Grid shows 11 cards. Thumbnails appear lazily as you scroll (or all at once for the small library — that's fine).
3. First card auto-selected. Player loads `curls-shrugs.mp4`. Native controls play / pause / scrub.
4. Click a different card → player + transcript update.
5. The transcript zone shows three visual rows for `curls-shrugs.mp4`. No audio rows (silent corpus). Click a visual row → player jumps to that timestamp.
6. The footage summary appears under the player; "Show more" expands it.
7. Close the Library window and re-open from the Projects screen → same first-clip selected (no persistence).
8. Open a second library window for the same library (M0 should focus the existing window — confirm).

If any of the above fails, fix the relevant component before continuing — the manual pass is a gate, not informational.

- [ ] **Step 3: Empty-state coverage**

In a separate terminal:

```bash
cp libraries/march-30-workout/library.yaml libraries/march-30-workout/library.yaml.bak
```

Edit `libraries/march-30-workout/library.yaml`: pick one video and set its `visual_transcript:` to `""`. Pick a second video and change its `path:` to `/tmp/nonexistent.mp4`.

Restart `pnpm tauri dev`.

- The clip with cleared `visual_transcript` should show "This clip hasn't been analyzed yet." in the transcript zone (audio is also empty).
- The clip with the bogus path should show "Can't find the video file. Expected at: `/tmp/nonexistent.mp4`" in the stage zone.

Restore the file:

```bash
mv libraries/march-30-workout/library.yaml.bak libraries/march-30-workout/library.yaml
```

- [ ] **Step 4: Update `ui/README.md`**

In the "For M0 the sidecar exposes:" list, replace the M0-only line with the M1 surface. Open the file and replace:

```markdown
For M0 the sidecar exposes:

- `ping` → `"pong"`
- `list_libraries` → `[{name, video_count, last_touched_at}]`
```

with:

```markdown
The sidecar exposes:

- `ping` → `"pong"`
- `list_libraries` → `[{name, video_count, last_touched_at}]`
- `get_library(name)` → library detail with video list, summary, common video parent dir
- `get_clip_transcripts(library, video)` → audio + visual + summary (any may be null)
- `get_or_generate_thumbnail(library, video)` → cached or freshly-extracted JPG path

Run sidecar tests with `cd ui/sidecar && rake spec` (requires `rspec` in PATH; ffmpeg-dependent test will skip if ffmpeg is absent).
```

- [ ] **Step 5: Commit and push**

```bash
git add ui/README.md
git commit -m "M1: document expanded sidecar surface in ui/README"
git push -u origin ui-m1-library-footage-browser
```

- [ ] **Step 6: Open the PR**

```bash
gh pr create --repo William-Hill/buttercut --base main --head ui-m1-library-footage-browser \
  --title "M1: Library footage browser (read-only clip grid + interleaved transcript)" \
  --body "$(cat <<'EOF'
Implements #16 (umbrella #14). Replaces the M0 Library window placeholder with a read-only footage browser: clip grid on the left, two-zone detail pane on the right (player + footage summary above, screenplay-style interleaved transcript below). Click a visual row or audio word to scrub the player.

Spec: `docs/superpowers/specs/2026-05-02-m1-library-footage-browser-design.md`
Plan: `docs/superpowers/plans/2026-05-02-m1-library-footage-browser.md`

## Sidecar additions

- `get_library(name)` — library detail + longest-common video parent for assetProtocol scope
- `get_clip_transcripts(library, video)` — audio + visual + summary (any may be null)
- `get_or_generate_thumbnail(library, video)` — cached, with ffmpeg shell-out on miss

## Tauri additions

- assetProtocol enabled with libraries-root scope at startup; per-library video paths granted via `allow_video_paths` on Library window open
- CSP gains `media-src 'self' asset: http://asset.localhost`
- New commands: get_library, get_clip_transcripts, get_or_generate_thumbnail, allow_video_paths

## Frontend

- `ui/src/routes/library/` directory: index, ClipGrid, ClipCard, StageZone, TranscriptZone, interleave helper, useThumbnail hook, types
- Empty states first-class — silent-gym corpus renders cleanly with no audio rows and no banner

## Test plan

- [ ] `cd ui/sidecar && rake spec` — green (8 examples; ffmpeg test skips if ffmpeg absent)
- [ ] `cd ui/src-tauri && cargo check` — green
- [ ] `cd ui && pnpm build` — green
- [ ] `pnpm tauri dev` against march-30-workout: grid renders, thumbnails generate lazily, player plays via assetProtocol, visual rows seek the player on click
- [ ] Hand-edit a video to clear `visual_transcript` → "hasn't been analyzed yet"
- [ ] Hand-edit a video's `path` to a nonexistent file → "Can't find the video file"
- [ ] Click-word-to-scrub verified manually against a hand-added talky fixture (the corpus is silent)
EOF
)"
```

- [ ] **Step 7: Note that PR is open**

The PR URL is the output of step 6. Reviewers (CodeRabbit, Codex) will run automatically. Address with `/respond-and-resolve` once they post.

---

## Self-Review

**Spec coverage check:**

- Sidecar `get_library` ✓ Task 2; `get_clip_transcripts` ✓ Task 3; `get_or_generate_thumbnail` ✓ Task 4
- Tauri assetProtocol enable + scope ✓ Task 5; CSP media-src ✓ Task 5; `allow_video_paths` validation ✓ Task 6 (validates absolute path); RPC wrappers ✓ Task 6; libraries-root startup grant ✓ Task 6
- Library window two-pane layout ✓ Tasks 8–12 (CSS in Task 8; grid in Task 10; stage in Task 11; transcript in Task 12)
- Clip card with thumb / filename / duration / dot ✓ Task 9
- Lazy thumbnail via IntersectionObserver ✓ Task 9 (`useThumbnail`)
- Stage zone player via `convertFileSrc` ✓ Task 11
- Footage summary with show-more ✓ Task 11
- Interleaved transcript with screenplay format ✓ Task 12 (`interleave.ts` + Row component)
- Click visual row → seek ✓ Task 12
- Click word → seek ✓ Task 12 (with fallback to segment.start when `words` missing)
- Empty states (footage_summary hidden, audio empty silent, visual missing message, video file missing message) ✓ Tasks 11–12, verified in Task 13 step 3
- No persistence ✓ Task 8 (selection not persisted)
- Multi-window scope additivity ✓ Task 6 (scope grants are additive by design of `allow_directory`)

**Placeholder scan:** None — every "verify" step has the exact command and expected output. No "implement later." All code is concrete.

**Type consistency check:** `VideoEntry`, `LibraryDetail`, `ClipTranscripts`, `AudioSegment`, `VisualSegment`, `AudioWord`, `InterleavedRow` are all defined once (types.ts / interleave.ts) and referenced consistently across components. Sidecar JSON keys (`filename`, `path`, `duration_seconds`, `has_audio_transcript`, `has_visual_transcript`, `has_summary`, `video_paths_root`, `footage_summary`) appear in both the Ruby implementation (Tasks 2–4) and the TS types (Task 7) with identical names.

**Decomposition check:** 13 tasks, each producing a single committable, independently-meaningful change. Bottom-up: sidecar tested before consumed, Rust commands before frontend wires them, components built and integrated one at a time. No task requires a sibling task to land first beyond explicit dependencies (e.g. Task 12 imports the interleave helper it creates in Step 1).
