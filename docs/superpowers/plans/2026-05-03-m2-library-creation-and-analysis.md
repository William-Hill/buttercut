# M2 — Library Creation + Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the New Project flow + streaming analysis progress UI so a non-terminal user can drag a folder, name a project, and watch the three-stage pipeline run to completion.

**Architecture:** Promote the Ruby sidecar from a thin YAML reader to the owner of the analysis pipeline (whisperx + ffmpeg subprocesses, Anthropic SDK calls for analyze + summarize). Stream per-file per-stage progress via JSON-RPC notifications, which the Rust reader forwards as Tauri events scoped per `job_id`. Frontend builds a five-step wizard window that morphs into a progress view after kickoff.

**Tech Stack:** Tauri 2 / Rust, Ruby 3 (stdlib + `concurrent-ruby` + `anthropic` SDK), React 19 + TS, plain CSS. Spec source: `docs/superpowers/specs/2026-05-03-m2-library-creation-and-analysis-design.md`.

**Working assumptions:**
- TDD with RSpec for every new Ruby module; tests live under `ui/sidecar/spec/lib/buttercut_ui_sidecar/`. Existing test pattern is in `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb` (StringIO + tmpdir + `LibraryFixture`).
- TDD with `cargo test` for non-trivial Rust pure-logic helpers; Tauri command wrappers are smoke-tested manually as in M0/M1.
- Frontend has no test harness; manual smoke testing matches M0/M1 conventions. Components are kept small and pure where possible.
- Branch is `ui-m2-library-creation-and-analysis` (already created from main).

---

## Handoff briefing — read this if you're picking up a single task cold

Each task below is self-contained: exact file paths, complete code, expected test output, and a commit message. You don't have to read the whole plan to execute one. But here's the surrounding context an outside agent (Cursor, Codex, fresh Claude) needs to make sense of any individual task:

**Repo:** `buttercut` — a Ruby gem for generating Final Cut Pro / Resolve XML, with a Tauri 2 desktop UI in `ui/`. The CLI workflow is driven by Claude Code via skills under `.claude/skills/`. M2 adds a New Project flow + streaming progress view to the desktop UI so non-terminal users can create and analyze libraries.

**Stack invariants — do not change:**
- Tauri 2 + React 19 + plain CSS. No Tailwind, no component libraries.
- `@fontsource/eb-garamond` (italic display) + `@fontsource/jetbrains-mono` (technical metadata).
- Tungsten amber `#e0a55a` accent on dark stage `#14141a`.
- Local Ruby sidecar over JSON-RPC stdio. Ruby ≥ 3, Bundler.
- Sidecar entrypoint: `ui/sidecar/buttercut_ui_sidecar.rb` (one class per file convention; see `CLAUDE.md` "Programming Style").
- Rust shell: `ui/src-tauri/src/lib.rs` (commands) + `ui/src-tauri/src/sidecar.rs` (JSON-RPC reader/writer + `init`).

**Architectural decisions locked in by the spec** (`docs/superpowers/specs/2026-05-03-m2-library-creation-and-analysis-design.md`):
1. **Streaming progress over JSON-RPC notifications** — sidecar emits payloads with no `id`; Rust reader recognizes them as notifications and forwards to Tauri events scoped per `job_id` (`sidecar-event:JOB_ID`).
2. **Sidecar owns the analysis pipeline** — calls whisperx + ffmpeg as subprocesses, calls Anthropic SDK directly for analyze + summarize. The CLI workflow continues to use Claude Code as parent. Two parents share prompt content via `ui/sidecar/prompts/*.md`.
3. **Plain-text API key in `libraries/settings.yaml`** (gitignored), with `ANTHROPIC_API_KEY` env override. Validated on save with a Haiku ping.
4. **Hard-stop cancellation** — `cancel_job` kills child PIDs (SIGTERM → SIGKILL after 2s) and aborts SDK calls. Artifacts are written via tempfile + atomic rename so partial state is never half-written.
5. **Concurrency caps as constants** — transcribe=2, analyze=8, summarize=10. No global rate limiter (the SDK retries 429s).

**Existing patterns to follow:**
- Ruby: one class per file; required args raise `ArgumentError` in `initialize`; CLI parsing in a bottom-of-file `if __FILE__ == $PROGRAM_NAME` block; exposed entry method (`Klass.run`/`Klass.create!`); spec at `spec/<same path>_spec.rb` using `Dir.mktmpdir` + `LibraryFixture` from `ui/sidecar/spec/fixtures/library_fixture.rb`.
- Rust: every Tauri command is `async fn`, returns `Result<Value, String>`, delegates to `sidecar::call(...)`; register the command in the `tauri::generate_handler![...]` list inside `run()`.
- TypeScript: typed wrappers in `ui/src/ipc/sidecar.ts`; React components default-exported from their file; CSS imported alongside the component (see `ui/src/routes/projects.tsx` + `projects.css`).

**Don't:** add Co-Authored-By or Claude attribution to commits; skip git hooks (`--no-verify`); use `git add .`/`git add -A` (be explicit); add Tailwind, shadcn, or other styling libs; modify `lib/buttercut/` (the gem core) unless the task explicitly says so.

**Pre-existing failures to ignore:** `spec/buttercut/fcpx_spec.rb` may have failures unrelated to M2 — don't try to fix them.

**When stuck on a task:** re-read the spec section it implements (referenced at the top of each Phase). The spec's "Decisions log" answers most "but why this way?" questions. If the spec doesn't cover it, add a brief note to the PR description rather than expanding scope.

---

## File Structure

### New Ruby files (sidecar)
```
ui/sidecar/lib/buttercut_ui_sidecar/
├── limits.rb               # parallelism caps as constants
├── settings_store.rb       # libraries/settings.yaml + ENV layering for the API key
├── notifier.rb             # writes JSON-RPC notifications to stdout (mutex-guarded)
├── video_inspector.rb      # ffprobe-backed inspect_video_paths
├── library_creator.rb      # atomic create_library
├── anthropic_client.rb     # thin SDK wrapper with abort + Haiku ping for validation
├── job_registry.rb         # in-memory job_id → AnalysisJob
├── analysis_job.rb         # cancel token, child PID + abort handle registry, worker pools
└── stages/
    ├── transcribe.rb
    ├── analyze.rb
    └── summarize.rb

ui/sidecar/prompts/
├── analyze_video.md        # extracted creative content (shared with CLI)
└── summarize_video.md

ui/sidecar/spec/lib/buttercut_ui_sidecar/
├── limits_spec.rb
├── settings_store_spec.rb
├── notifier_spec.rb
├── video_inspector_spec.rb
├── library_creator_spec.rb
└── analysis_job_spec.rb    # narrow: cancellation semantics, registry behavior
```

### Modified Ruby files
```
ui/sidecar/buttercut_ui_sidecar.rb   # dispatch new methods, hold notifier, hold registry
.claude/skills/analyze-video/agent_prompt.md     # delegate to ui/sidecar/prompts/analyze_video.md
.claude/skills/summarize-video/agent_prompt.md   # delegate to ui/sidecar/prompts/summarize_video.md
```

### Modified Rust files
```
ui/src-tauri/src/sidecar.rs   # Notification deserializer, AppHandle, emit events
ui/src-tauri/src/lib.rs       # new commands + new_project window
ui/src-tauri/Cargo.toml       # no new deps expected
ui/src-tauri/tauri.conf.json  # additional capability if needed for events
```

### New TypeScript / React files
```
ui/src/ipc/events.ts                          # typed listen helper
ui/src/routes/new-project/
├── index.tsx                                 # window root + phase switch
├── state.ts                                  # setup phase reducer + types
├── jobReducer.ts                             # progress phase reducer + types
├── api-key-modal.tsx
├── steps/
│   ├── pick-footage.tsx
│   ├── name.tsx
│   ├── language.tsx
│   ├── refinement.tsx
│   └── confirm.tsx
├── progress/
│   ├── progress-view.tsx
│   ├── clip-row.tsx
│   └── artifact-preview.tsx
└── new-project.css
```

### Modified TypeScript / React files
```
ui/src/ipc/sidecar.ts        # new typed wrappers for the new RPCs
ui/src/main.tsx              # route on /new-project hash
ui/src/routes/projects.tsx   # add "+ New Project" tile
ui/src/routes/projects.css   # tile styling
```

### Manifest changes
```
ui/sidecar/Gemfile           # add anthropic, concurrent-ruby
ui/sidecar/Gemfile.lock      # regenerated
```

---

## Phase 0 — Branch hygiene & dependency baseline

### Task 0.1: Add Ruby dependencies

**Files:**
- Create: `ui/sidecar/Gemfile`
- Create: `ui/sidecar/Gemfile.lock` (generated)

- [ ] **Step 1: Check whether a Gemfile exists**

```bash
ls ui/sidecar/Gemfile 2>&1
```
If it exists, skip to Step 3 and add the new gems to the existing file.

- [ ] **Step 2: Create Gemfile**

```ruby
# ui/sidecar/Gemfile
source "https://rubygems.org"

gem "concurrent-ruby", "~> 1.3"
gem "anthropic",       "~> 1.0"

group :development, :test do
  gem "rspec", "~> 3.13"
end
```

- [ ] **Step 3: Install**

Run: `cd ui/sidecar && bundle install`
Expected: lockfile generated, both gems resolved.

- [ ] **Step 4: Update Rakefile to load bundler**

Edit `ui/sidecar/Rakefile`:
```ruby
require "bundler/setup"
require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
task default: :spec
```

- [ ] **Step 5: Run baseline spec**

Run: `cd ui/sidecar && bundle exec rake spec`
Expected: existing M1 specs still pass.

- [ ] **Step 6: Commit**

```bash
git add ui/sidecar/Gemfile ui/sidecar/Gemfile.lock ui/sidecar/Rakefile
git commit -m "M2: add concurrent-ruby and anthropic SDK to the sidecar"
```

---

## Phase 1 — Sidecar foundation

### Task 1.1: Parallelism caps

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/limits.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/limits_spec.rb`

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/limits_spec.rb
require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/limits"

RSpec.describe ButtercutUiSidecar::Limits do
  it "matches the values declared in the SKILL.md files" do
    expect(described_class::TRANSCRIBE_PARALLELISM).to eq(2)
    expect(described_class::ANALYZE_PARALLELISM).to eq(8)
    expect(described_class::SUMMARIZE_PARALLELISM).to eq(10)
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/limits_spec.rb`
Expected: LoadError on the require.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/limits.rb
# frozen_string_literal: true

module ButtercutUiSidecar
  module Limits
    # Mirrors .claude/skills/<skill>/SKILL.md parent briefs.
    TRANSCRIBE_PARALLELISM = 2
    ANALYZE_PARALLELISM    = 8
    SUMMARIZE_PARALLELISM  = 10
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/limits_spec.rb`
Expected: 1 example, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/limits.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/limits_spec.rb
git commit -m "M2: extract parallelism caps into a single source"
```

---

### Task 1.2: Notifier (JSON-RPC notifications)

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/notifier.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/notifier_spec.rb`

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/notifier_spec.rb
require "spec_helper"
require "stringio"
require "json"
require_relative "../../../lib/buttercut_ui_sidecar/notifier"

RSpec.describe ButtercutUiSidecar::Notifier do
  it "writes a JSON-RPC 2.0 notification (no id) and flushes" do
    io = StringIO.new
    described_class.new(io: io).notify("file_started", job_id: "j1", video: "a.mp4", stage: "transcribe")

    line = io.string.lines.last
    payload = JSON.parse(line)
    expect(payload["jsonrpc"]).to eq("2.0")
    expect(payload).not_to have_key("id")
    expect(payload["method"]).to eq("file_started")
    expect(payload["params"]).to include("job_id" => "j1", "video" => "a.mp4", "stage" => "transcribe")
    expect(payload["params"]).to have_key("ts")
  end

  it "is safe to call concurrently — lines are not interleaved" do
    io = StringIO.new
    notifier = described_class.new(io: io)
    threads = 16.times.map do |i|
      Thread.new { 50.times { notifier.notify("ping", n: i) } }
    end
    threads.each(&:join)

    io.string.each_line do |line|
      expect { JSON.parse(line) }.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/notifier_spec.rb`
Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/notifier.rb
# frozen_string_literal: true

require "json"
require "time"

module ButtercutUiSidecar
  # Writes JSON-RPC 2.0 notifications (payloads without an `id`) on a shared
  # output stream — the same stream that carries request/response. The Rust
  # reader distinguishes them by the absence of `id`. A mutex serializes
  # writes so notifications and responses don't interleave at the byte level.
  class Notifier
    def initialize(io:, mutex: Mutex.new)
      @io = io
      @mutex = mutex
      @io.sync = true if @io.respond_to?(:sync=)
    end

    def notify(method, **params)
      params[:ts] ||= Time.now.utc.iso8601(3)
      line = JSON.generate(jsonrpc: "2.0", method: method, params: params)
      @mutex.synchronize do
        @io.puts(line)
      end
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/notifier_spec.rb`
Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/notifier.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/notifier_spec.rb
git commit -m "M2: notifier emits mutex-guarded JSON-RPC notifications"
```

---

### Task 1.3: Settings store (API key persistence)

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/settings_store.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/settings_store_spec.rb`

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/settings_store_spec.rb
require "spec_helper"
require "tmpdir"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/settings_store"

RSpec.describe ButtercutUiSidecar::SettingsStore do
  it "prefers ENV over the YAML file" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "settings.yaml"), YAML.dump("anthropic_api_key" => "from-yaml"))
      store = described_class.new(libraries_root: root, env: { "ANTHROPIC_API_KEY" => "from-env" })
      expect(store.api_key).to eq("from-env")
    end
  end

  it "falls back to settings.yaml when ENV is unset" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "settings.yaml"), YAML.dump("anthropic_api_key" => "from-yaml"))
      store = described_class.new(libraries_root: root, env: {})
      expect(store.api_key).to eq("from-yaml")
    end
  end

  it "returns nil when neither is set" do
    Dir.mktmpdir do |root|
      store = described_class.new(libraries_root: root, env: {})
      expect(store.api_key).to be_nil
    end
  end

  it "writes the key to settings.yaml without clobbering other fields" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "settings.yaml"), YAML.dump("editor" => "fcpx", "whisper_model" => "small"))
      store = described_class.new(libraries_root: root, env: {})
      store.write_api_key!("sk-abc")

      data = YAML.safe_load(File.read(File.join(root, "settings.yaml")))
      expect(data["editor"]).to eq("fcpx")
      expect(data["whisper_model"]).to eq("small")
      expect(data["anthropic_api_key"]).to eq("sk-abc")
    end
  end

  it "creates settings.yaml when missing" do
    Dir.mktmpdir do |root|
      store = described_class.new(libraries_root: root, env: {})
      store.write_api_key!("sk-xyz")
      data = YAML.safe_load(File.read(File.join(root, "settings.yaml")))
      expect(data["anthropic_api_key"]).to eq("sk-xyz")
    end
  end

  it "configured? reflects whether a key is available" do
    Dir.mktmpdir do |root|
      empty = described_class.new(libraries_root: root, env: {})
      expect(empty.configured?).to be false
      configured = described_class.new(libraries_root: root, env: { "ANTHROPIC_API_KEY" => "x" })
      expect(configured.configured?).to be true
    end
  end
end
```

- [ ] **Step 2: Run, verify fail.**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/settings_store_spec.rb`
Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/settings_store.rb
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "yaml"

module ButtercutUiSidecar
  class SettingsStore
    SETTINGS_FILENAME = "settings.yaml"

    def initialize(libraries_root:, env: ENV.to_h)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      @root = Pathname.new(libraries_root)
      @env = env
    end

    def api_key
      env_key = @env["ANTHROPIC_API_KEY"]
      return env_key unless env_key.nil? || env_key.empty?
      data = read_yaml
      key = data["anthropic_api_key"]
      key.nil? || key.empty? ? nil : key
    end

    def configured?
      !api_key.nil?
    end

    def write_api_key!(key)
      raise ArgumentError, "key required" if key.nil? || key.empty?
      data = read_yaml
      data["anthropic_api_key"] = key
      write_yaml(data)
    end

    private

    def settings_path
      @root.join(SETTINGS_FILENAME)
    end

    def read_yaml
      return {} unless settings_path.file?
      YAML.safe_load(settings_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    end

    def write_yaml(data)
      FileUtils.mkdir_p(@root)
      tmp = settings_path.to_s + ".tmp"
      File.write(tmp, YAML.dump(data))
      File.rename(tmp, settings_path.to_s)
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/settings_store_spec.rb`
Expected: 6 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/settings_store.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/settings_store_spec.rb
git commit -m "M2: settings store layers ENV over libraries/settings.yaml"
```

---

### Task 1.4: Anthropic client wrapper

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/anthropic_client.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/anthropic_client_spec.rb`

- [ ] **Step 1: Failing test (uses a stubbed transport)**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/anthropic_client_spec.rb
require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/anthropic_client"

RSpec.describe ButtercutUiSidecar::AnthropicClient do
  # The wrapper takes a client factory so tests can inject a fake.
  class FakeSdk
    def initialize(response: nil, raise_with: nil)
      @response = response
      @raise_with = raise_with
      @calls = []
    end
    attr_reader :calls

    def messages
      self
    end

    def create(**kwargs)
      @calls << kwargs
      raise @raise_with if @raise_with
      @response
    end
  end

  it "validates a key with a 1-token Haiku ping and returns true on success" do
    fake = FakeSdk.new(response: { "content" => [{ "type" => "text", "text" => "ok" }] })
    client = described_class.new(api_key: "sk-test", sdk: fake)
    expect(client.validate_key!).to be true
    expect(fake.calls.first[:model]).to match(/haiku/i)
    expect(fake.calls.first[:max_tokens]).to eq(1)
  end

  it "raises InvalidApiKey when the SDK raises an auth error" do
    fake = FakeSdk.new(raise_with: described_class::FakeAuthError.new("invalid x-api-key"))
    client = described_class.new(api_key: "sk-bad", sdk: fake, auth_error_classes: [described_class::FakeAuthError])
    expect { client.validate_key! }.to raise_error(ButtercutUiSidecar::AnthropicClient::InvalidApiKey, /invalid/)
  end
end
```

(`FakeAuthError` is just an alias for `RuntimeError` defined inside the wrapper for tests; in production, the auth-error class list comes from the `anthropic` gem.)

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/anthropic_client_spec.rb`
Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/anthropic_client.rb
# frozen_string_literal: true

module ButtercutUiSidecar
  # Thin wrapper around the anthropic gem. Holds the api_key, exposes
  # `validate_key!` (single Haiku ping) and `messages_create` (regular calls).
  # Auth errors surface as InvalidApiKey; everything else propagates.
  class AnthropicClient
    HAIKU_MODEL = "claude-haiku-4-5-20251001"
    VISION_MODEL = "claude-sonnet-4-6"

    class InvalidApiKey < StandardError; end
    class FakeAuthError < StandardError; end # used only in tests

    def initialize(api_key:, sdk: nil, auth_error_classes: nil)
      raise ArgumentError, "api_key required" if api_key.nil? || api_key.empty?
      @api_key = api_key
      @sdk = sdk || build_sdk(api_key)
      @auth_error_classes = auth_error_classes || default_auth_error_classes
    end

    def validate_key!
      @sdk.messages.create(
        model: HAIKU_MODEL,
        max_tokens: 1,
        messages: [{ role: "user", content: "ping" }]
      )
      true
    rescue *@auth_error_classes => e
      raise InvalidApiKey, e.message
    end

    def messages_create(**kwargs)
      @sdk.messages.create(**kwargs)
    rescue *@auth_error_classes => e
      raise InvalidApiKey, e.message
    end

    private

    def build_sdk(api_key)
      require "anthropic"
      Anthropic::Client.new(api_key: api_key)
    end

    def default_auth_error_classes
      classes = []
      begin
        require "anthropic"
        classes << Anthropic::AuthenticationError if defined?(Anthropic::AuthenticationError)
      rescue LoadError
        # fall through; tests inject explicit classes
      end
      classes
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/anthropic_client_spec.rb`
Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/anthropic_client.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/anthropic_client_spec.rb
git commit -m "M2: AnthropicClient wraps the SDK with validate_key! + InvalidApiKey"
```

---

## Phase 2 — Stateless RPCs (no worker pool yet)

### Task 2.1: Video inspector

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/video_inspector.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/video_inspector_spec.rb`

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/video_inspector_spec.rb
require "spec_helper"
require "tmpdir"
require_relative "../../../lib/buttercut_ui_sidecar/video_inspector"

RSpec.describe ButtercutUiSidecar::VideoInspector do
  it "rejects paths that do not exist" do
    result = described_class.new.inspect(["/no/such/file.mov"])
    expect(result[:accepted]).to be_empty
    expect(result[:rejected].first[:reason]).to eq("not_found")
  end

  it "rejects non-video files", skip: !system("which ffprobe > /dev/null 2>&1") do
    Dir.mktmpdir do |dir|
      txt = File.join(dir, "notes.txt")
      File.write(txt, "hello")
      result = described_class.new.inspect([txt])
      expect(result[:rejected].first[:reason]).to eq("not_video")
    end
  end

  it "accepts a real video and returns duration_seconds + size_bytes",
     skip: !system("which ffmpeg > /dev/null 2>&1 && which ffprobe > /dev/null 2>&1") do
    Dir.mktmpdir do |dir|
      video = File.join(dir, "tiny.mp4")
      system("ffmpeg -y -loglevel error -f lavfi -i color=c=red:s=64x64:d=2 -pix_fmt yuv420p #{video}")
      result = described_class.new.inspect([video])
      expect(result[:accepted].first[:path]).to eq(video)
      expect(result[:accepted].first[:duration_seconds]).to be > 0
      expect(result[:accepted].first[:size_bytes]).to be > 0
    end
  end
end
```

- [ ] **Step 2: Run, verify fail**

Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/video_inspector.rb
# frozen_string_literal: true

require "open3"
require "json"

module ButtercutUiSidecar
  class VideoInspector
    def inspect(paths)
      accepted = []
      rejected = []

      paths.each do |p|
        unless File.file?(p)
          rejected << { path: p, reason: "not_found" }
          next
        end

        info = probe(p)
        if info.nil?
          rejected << { path: p, reason: "not_video" }
        elsif info[:duration_seconds].to_f <= 0
          rejected << { path: p, reason: "zero_duration" }
        else
          accepted << { path: p, duration_seconds: info[:duration_seconds], size_bytes: File.size(p) }
        end
      end

      { accepted: accepted, rejected: rejected }
    end

    private

    def probe(path)
      cmd = ["ffprobe", "-v", "error", "-print_format", "json",
             "-show_format", "-show_streams", "-select_streams", "v:0", path]
      out, _err, status = Open3.capture3(*cmd)
      return nil unless status.success?
      data = JSON.parse(out) rescue nil
      return nil unless data && (data["streams"] || []).any? { |s| s["codec_type"] == "video" }
      duration = (data.dig("format", "duration") || 0).to_f
      { duration_seconds: duration }
    rescue StandardError
      nil
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Run: `bundle exec rspec spec/lib/buttercut_ui_sidecar/video_inspector_spec.rb`
Expected: 3 examples, 0 failures (some skipped if ffmpeg/ffprobe absent).

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/video_inspector.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/video_inspector_spec.rb
git commit -m "M2: VideoInspector wraps ffprobe and classifies rejections"
```

---

### Task 2.2: Library creator

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/library_creator.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/library_creator_spec.rb`

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/library_creator_spec.rb
require "spec_helper"
require "tmpdir"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/library_creator"

RSpec.describe ButtercutUiSidecar::LibraryCreator do
  def video(dir, name, duration: "00:00:05")
    path = File.join(dir, name)
    File.write(path, "x")
    { path: path, duration_seconds: 5 }
  end

  it "slugifies the name and creates the directory tree + library.yaml" do
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |footage|
        creator = described_class.new(libraries_root: root)
        result = creator.create!(
          name: "My Bike Series",
          language: "English",
          language_code: "en",
          refinement: true,
          videos: [video(footage, "a.mp4"), video(footage, "b.mp4")]
        )
        expect(result[:name]).to eq("my-bike-series")

        lib_dir = File.join(root, "my-bike-series")
        expect(File.directory?(File.join(lib_dir, "transcripts"))).to be true
        expect(File.directory?(File.join(lib_dir, "summaries"))).to be true

        data = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")), permitted_classes: [Date, Time])
        expect(data["library_name"]).to eq("my-bike-series")
        expect(data["language"]).to eq("English")
        expect(data["language_code"]).to eq("en")
        expect(data["transcript_refinement"]).to be true
        expect(data["videos"].length).to eq(2)
        expect(data["videos"].first["transcript"]).to eq("")
        expect(data["videos"].first["visual_transcript"]).to eq("")
        expect(data["videos"].first["summary"]).to eq("")
      end
    end
  end

  it "errors with library_exists when the slug already has a library.yaml" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "demo"))
      File.write(File.join(root, "demo", "library.yaml"), "library_name: demo")
      creator = described_class.new(libraries_root: root)
      expect {
        creator.create!(name: "Demo", language: "English", language_code: "en", refinement: false, videos: [])
      }.to raise_error(described_class::LibraryExists)
    end
  end

  it "rolls back on partial failure (e.g. yaml write fails)" do
    Dir.mktmpdir do |root|
      creator = described_class.new(libraries_root: root)
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(/library\.yaml/, anything).and_raise(Errno::EACCES, "denied")

      expect {
        creator.create!(name: "rollback", language: "English", language_code: "en", refinement: false, videos: [])
      }.to raise_error(Errno::EACCES)

      expect(File.directory?(File.join(root, "rollback"))).to be false
    end
  end
end
```

- [ ] **Step 2: Run, verify fail**

Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/library_creator.rb
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "yaml"
require "date"

module ButtercutUiSidecar
  class LibraryCreator
    class LibraryExists < StandardError; end

    def initialize(libraries_root:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      @root = Pathname.new(libraries_root)
    end

    def create!(name:, language:, language_code:, refinement:, videos:)
      slug = slugify(name)
      raise ArgumentError, "invalid name: #{name}" if slug.empty?

      lib_dir = @root.join(slug)
      raise LibraryExists, "library already exists: #{slug}" if lib_dir.join("library.yaml").file?

      created = false
      begin
        FileUtils.mkdir_p(lib_dir.join("transcripts"))
        FileUtils.mkdir_p(lib_dir.join("summaries"))
        created = true

        data = build_yaml(slug: slug, language: language, language_code: language_code,
                          refinement: refinement, videos: videos)
        File.write(lib_dir.join("library.yaml"), YAML.dump(data))
        { name: slug }
      rescue StandardError
        FileUtils.rm_rf(lib_dir) if created
        raise
      end
    end

    private

    def slugify(name)
      name.to_s.downcase.gsub(/\s+/, "-").gsub(/[^a-z0-9\-]/, "").gsub(/-+/, "-").gsub(/\A-|-\z/, "")
    end

    def build_yaml(slug:, language:, language_code:, refinement:, videos:)
      today = Date.today.iso8601
      {
        "library_name" => slug,
        "created_date" => today,
        "last_updated" => today,
        "language" => language,
        "language_code" => language_code,
        "editor" => nil,
        "transcript_refinement" => refinement,
        "user_context" => "",
        "footage_summary" => "No footage analyzed yet.",
        "videos" => videos.map do |v|
          {
            "path" => v[:path] || v["path"],
            "duration" => format_duration(v[:duration_seconds] || v["duration_seconds"]),
            "transcript" => "",
            "visual_transcript" => "",
            "summary" => ""
          }
        end
      }
    end

    def format_duration(seconds)
      return "00:00:00" if seconds.nil?
      s = seconds.to_i
      format("%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Expected: 3 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/library_creator.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/library_creator_spec.rb
git commit -m "M2: LibraryCreator atomically creates a library directory tree"
```

---

### Task 2.3: Wire `inspect_video_paths`, `create_library`, `set_api_key`, `has_api_key` into the dispatcher

**Files:**
- Modify: `ui/sidecar/buttercut_ui_sidecar.rb`
- Modify: `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb`

- [ ] **Step 1: Add specs to the existing top-level spec**

Append to `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb` (inside the existing `describe ButtercutUiSidecar do … end`):

```ruby
  describe "has_api_key" do
    it "returns false when no key is configured" do
      Dir.mktmpdir do |root|
        result = call(root, "has_api_key")
        expect(result["result"]).to eq({ "configured" => false })
      end
    end
  end

  describe "create_library" do
    it "creates a library and returns its slug" do
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |footage|
          v = File.join(footage, "a.mp4")
          File.write(v, "x")
          result = call(root, "create_library", {
            name: "My Lib",
            language: "English",
            language_code: "en",
            refinement: true,
            videos: [{ path: v, duration_seconds: 5 }]
          })
          expect(result["result"]).to eq({ "name" => "my-lib" })
          expect(File.file?(File.join(root, "my-lib", "library.yaml"))).to be true
        end
      end
    end
  end

  describe "inspect_video_paths" do
    it "rejects nonexistent paths" do
      Dir.mktmpdir do |root|
        result = call(root, "inspect_video_paths", { paths: ["/no/such/file.mov"] })
        expect(result["result"]["rejected"].first["reason"]).to eq("not_found")
      end
    end
  end
```

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rspec spec/buttercut_ui_sidecar_spec.rb`
Expected: failures on the three new contexts (`unknown method`).

- [ ] **Step 3: Wire into dispatcher**

Edit `ui/sidecar/buttercut_ui_sidecar.rb`. At the top, after existing requires:

```ruby
require_relative "lib/buttercut_ui_sidecar/limits"
require_relative "lib/buttercut_ui_sidecar/notifier"
require_relative "lib/buttercut_ui_sidecar/settings_store"
require_relative "lib/buttercut_ui_sidecar/anthropic_client"
require_relative "lib/buttercut_ui_sidecar/video_inspector"
require_relative "lib/buttercut_ui_sidecar/library_creator"
```

In `initialize`, add:

```ruby
@settings = ButtercutUiSidecar::SettingsStore.new(libraries_root: @libraries_root.to_s)
@notifier = ButtercutUiSidecar::Notifier.new(io: @io_out)
@inspector = ButtercutUiSidecar::VideoInspector.new
@creator = ButtercutUiSidecar::LibraryCreator.new(libraries_root: @libraries_root.to_s)
```

In `dispatch`, add cases:

```ruby
when "has_api_key"
  { configured: @settings.configured? }
when "set_api_key"
  set_api_key(params.fetch("key"))
when "inspect_video_paths"
  @inspector.inspect(params.fetch("paths"))
when "create_library"
  @creator.create!(
    name: params.fetch("name"),
    language: params.fetch("language"),
    language_code: params.fetch("language_code"),
    refinement: params.fetch("refinement"),
    videos: params.fetch("videos")
  )
```

Add the `set_api_key` private method:

```ruby
def set_api_key(key)
  client = ButtercutUiSidecar::AnthropicClient.new(api_key: key)
  client.validate_key!
  @settings.write_api_key!(key)
  { ok: true }
rescue ButtercutUiSidecar::AnthropicClient::InvalidApiKey => e
  raise StandardError, "invalid_api_key: #{e.message}"
end
```

Map `LibraryCreator::LibraryExists` to a specific RPC error code in `handle_line`:

```ruby
rescue ButtercutUiSidecar::LibraryCreator::LibraryExists => e
  respond_error(id: id, code: -32011, message: "library_exists: #{e.message}")
```

(Place that rescue clause before the generic `StandardError` rescue.)

- [ ] **Step 4: Run, verify pass**

Run: `cd ui/sidecar && bundle exec rake spec`
Expected: all M1 specs + the three new dispatcher contexts pass.

- [ ] **Step 5: Smoke-test from a shell**

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"has_api_key","params":{}}' | bundle exec ruby buttercut_ui_sidecar.rb /tmp
```
Expected: `{"jsonrpc":"2.0","id":1,"result":{"configured":false}}` (or `true` if you have ANTHROPIC_API_KEY exported).

- [ ] **Step 6: Commit**

```bash
git add ui/sidecar/buttercut_ui_sidecar.rb ui/sidecar/spec/buttercut_ui_sidecar_spec.rb
git commit -m "M2: dispatch has_api_key, set_api_key, inspect_video_paths, create_library"
```

---

## Phase 3 — Prompt extraction

### Task 3.1: Extract analyze + summarize prompt content

**Files:**
- Create: `ui/sidecar/prompts/analyze_video.md`
- Create: `ui/sidecar/prompts/summarize_video.md`
- Modify: `.claude/skills/analyze-video/agent_prompt.md`
- Modify: `.claude/skills/summarize-video/agent_prompt.md`

- [ ] **Step 1: Create `ui/sidecar/prompts/analyze_video.md`**

Pull out the *creative* sections from `.claude/skills/analyze-video/agent_prompt.md` — the description content, b-roll guidelines, dialogue/visual segment structure. **Do not** include Claude-Code-specific instructions ("use the Edit tool", "Read the JPG frames"). The shared prompt should describe **what** to produce, not the tooling. Concretely write:

```markdown
# Visual transcript instructions (shared)

You analyze video frames and produce visual descriptions paired with audio segments to form a "visual transcript." This file is read by both the CLI agent (Claude Code) and the desktop sidecar (Anthropic SDK).

## Output schema

The visual transcript JSON has the same top-level shape as the audio transcript: `{language, video_path, segments: [...]}`. Each segment is one of:

**Dialogue segment** — same shape as audio, plus a `visual` field:
```json
{
  "start": 2.917,
  "end": 7.586,
  "text": "Hey, good afternoon everybody.",
  "visual": "Man in red shirt speaking to camera in medium shot. Home office with bookshelf. Natural lighting.",
  "words": [...]
}
```

**B-roll segment** — inserted between dialogue when no one is speaking:
```json
{
  "start": 35.474,
  "end": 56.162,
  "text": "",
  "visual": "Green bicycle parked in front of building. Urban street with trees.",
  "b_roll": true,
  "words": []
}
```

## Description guidelines

- Maximum 3 sentences per `visual` field.
- First segment: detailed (subject, setting, shot type, lighting, camera style).
- Continuing shots: brief if similar; up to 3 sentences if drastically different.
- Describe what is visible, not interpretation. Avoid speculation.

## Frame sampling

- Videos ≤30s: sample one frame near the middle.
- Videos >30s: sample at start (~2s in), middle (duration/2), end (duration−2s).
- Subdivide further if start/middle/end show different subjects, settings, or angle changes.
- Stop subdividing when consecutive frames show only minor changes.
- Never sample more frequently than once per 30 seconds.
```

- [ ] **Step 2: Create `ui/sidecar/prompts/summarize_video.md`**

Same treatment for the summary content:

```markdown
# Video summary instructions (shared)

You produce a short markdown summary of a video from its visual transcript. This file is read by both the CLI agent (Claude Code, via skeleton + Edit) and the desktop sidecar (Anthropic SDK, plain text output).

## Output structure

The summary file has four sections, in order:

1. **Overview** — 2–3 sentences describing the narrative arc. Be specific. Avoid vague endings like "the clip ends with…" or "discusses something."
2. **Key visuals** — 3–6 bullets covering locations, distinctive shots, visual changes.
3. **Dialogue** — 0–3 quotes formatted as `> [MM:SS] "Quote"`. Skip filler ("um", "you know"). For clips under 30 seconds, often 0–1 quotes is enough; write `None` if nothing stands out.
4. **B-roll** — cutaway descriptions distinct from the main subject. For single-shot clips, write `None`. Do not speculate about how the footage could be used as b-roll elsewhere.

The CLI agent fills these into a pre-created skeleton via Edit; the sidecar emits them directly as a single markdown document.
```

- [ ] **Step 3: Update `.claude/skills/analyze-video/agent_prompt.md`**

Replace the section "Add visual descriptions" through the b-roll example with:

```markdown
## 3. Add visual descriptions

The output schema and description guidelines are defined in
`ui/sidecar/prompts/analyze_video.md` — read it before continuing.

**Read the JPG frames** from `tmp/frames/[video_name]/` using the Read tool, then **Edit** the file at `<visual_transcript_path>`. Do this incrementally — no script needed; just edit the JSON each time you read new frames.
```

Leave the rest of the file (frame extraction, cleanup, return) intact.

- [ ] **Step 4: Update `.claude/skills/summarize-video/agent_prompt.md`**

Replace the "Action 3 — Edit each placeholder" section's body with:

```markdown
## Action 3 — Edit each placeholder

The four sections (Overview, Key visuals, Dialogue, B-roll) are defined in
`ui/sidecar/prompts/summarize_video.md` — read it for the exact content rules.

Use the **Edit** tool four times to replace each `<!-- FILL_X -->` marker with the corresponding section's content:

- `<!-- FILL_OVERVIEW -->` → the Overview section.
- `<!-- FILL_KEY_VISUALS -->` → the Key visuals bullets.
- `<!-- FILL_DIALOGUE -->` → the Dialogue quotes (or `None`).
- `<!-- FILL_BROLL -->` → the B-roll list (or `None`).
```

- [ ] **Step 5: Verify the existing agent prompts still parse / run a dry sanity check**

Run: `head -30 .claude/skills/analyze-video/agent_prompt.md && head -30 .claude/skills/summarize-video/agent_prompt.md`
Expected: still well-formed markdown, no broken anchor references.

- [ ] **Step 6: Commit**

```bash
git add ui/sidecar/prompts/ .claude/skills/analyze-video/agent_prompt.md .claude/skills/summarize-video/agent_prompt.md
git commit -m "M2: extract analyze + summarize prompt content into shared files"
```

---

## Phase 4 — Analysis pipeline

### Task 4.1: JobRegistry

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/job_registry.rb`

- [ ] **Step 1: Failing test**

Create `ui/sidecar/spec/lib/buttercut_ui_sidecar/job_registry_spec.rb`:

```ruby
require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/job_registry"

RSpec.describe ButtercutUiSidecar::JobRegistry do
  it "stores, retrieves, and removes by job_id" do
    registry = described_class.new
    registry.put("j1", :payload)
    expect(registry.get("j1")).to eq(:payload)
    registry.delete("j1")
    expect(registry.get("j1")).to be_nil
  end

  it "is concurrent-safe" do
    registry = described_class.new
    threads = 32.times.map do |i|
      Thread.new { registry.put("j#{i}", i) }
    end
    threads.each(&:join)
    32.times { |i| expect(registry.get("j#{i}")).to eq(i) }
  end
end
```

- [ ] **Step 2: Run, verify fail.** Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/job_registry.rb
# frozen_string_literal: true

module ButtercutUiSidecar
  class JobRegistry
    def initialize
      @mutex = Mutex.new
      @jobs = {}
    end

    def put(id, job)
      @mutex.synchronize { @jobs[id] = job }
    end

    def get(id)
      @mutex.synchronize { @jobs[id] }
    end

    def delete(id)
      @mutex.synchronize { @jobs.delete(id) }
    end

    def each(&block)
      @mutex.synchronize { @jobs.values.dup }.each(&block)
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**. Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/job_registry.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/job_registry_spec.rb
git commit -m "M2: JobRegistry — mutex-guarded job_id table"
```

---

### Task 4.2: AnalysisJob (cancel token + child PID + abort handle registry)

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/analysis_job.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/analysis_job_spec.rb`

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/analysis_job_spec.rb
require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::AnalysisJob do
  it "starts uncanceled" do
    job = described_class.new(id: "j1", library: "demo")
    expect(job.canceled?).to be false
  end

  it "cancel! flips the token and is idempotent" do
    job = described_class.new(id: "j1", library: "demo")
    job.cancel!
    job.cancel!
    expect(job.canceled?).to be true
  end

  it "registers and signals child PIDs on cancel" do
    job = described_class.new(id: "j1", library: "demo")
    pid = Process.spawn("sleep", "60")
    job.register_pid(pid)
    job.cancel!
    # Reap the child to avoid zombies; Process.wait blocks until done.
    Process.wait(pid)
    expect($?.success?).to be false
  end

  it "registers and aborts in-flight handles on cancel" do
    job = described_class.new(id: "j1", library: "demo")
    aborted = false
    handle = Object.new
    handle.define_singleton_method(:abort!) { aborted = true }
    job.register_abortable(handle)
    job.cancel!
    expect(aborted).to be true
  end
end
```

- [ ] **Step 2: Run, verify fail.** Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/analysis_job.rb
# frozen_string_literal: true

require "concurrent"

module ButtercutUiSidecar
  class AnalysisJob
    attr_reader :id, :library

    def initialize(id:, library:)
      @id = id
      @library = library
      @cancel_flag = Concurrent::AtomicBoolean.new(false)
      @pids = Concurrent::Array.new
      @abortables = Concurrent::Array.new
      @library_yaml_mutex = Mutex.new
    end

    def canceled?
      @cancel_flag.true?
    end

    def cancel!
      return if @cancel_flag.true?
      @cancel_flag.make_true
      @pids.dup.each { |pid| terminate_pid(pid) }
      @abortables.dup.each do |h|
        h.abort! if h.respond_to?(:abort!)
      end
    end

    def register_pid(pid)
      @pids << pid
    end

    def unregister_pid(pid)
      @pids.delete(pid)
    end

    def register_abortable(handle)
      @abortables << handle
    end

    def unregister_abortable(handle)
      @abortables.delete(handle)
    end

    # Yields with the per-library yaml mutex held. Use for read-modify-write of library.yaml.
    def with_yaml_lock
      @library_yaml_mutex.synchronize { yield }
    end

    private

    def terminate_pid(pid)
      Process.kill("TERM", pid)
      sleep 2
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # already gone
    end
  end
end
```

- [ ] **Step 4: Run, verify pass.** Expected: 4 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/analysis_job.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/analysis_job_spec.rb
git commit -m "M2: AnalysisJob — cancel token, PID registry, abort handles, yaml mutex"
```

---

### Task 4.3: Stage — transcribe (whisperx subprocess only, no refinement yet)

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/stages/transcribe.rb`

This stage shells out to `whisperx`, runs the existing `prepare_audio_script.rb`, and writes `<basename>.json` into `transcripts/`. We do **not** TDD it against the real whisperx (too slow, requires the model). Instead we expose a single `run` method that takes the dependencies as arguments and unit-test the orchestration with a fake.

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/transcribe_spec.rb
require "spec_helper"
require "tmpdir"
require "json"
require_relative "../../../../lib/buttercut_ui_sidecar/stages/transcribe"
require_relative "../../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::Stages::Transcribe do
  it "runs whisperx, prepares the JSON, registers the PID for cancellation" do
    Dir.mktmpdir do |dir|
      video = File.join(dir, "tiny.mp4")
      File.write(video, "x")
      transcript_dir = File.join(dir, "transcripts")
      FileUtils.mkdir_p(transcript_dir)
      expected_output = File.join(transcript_dir, "tiny.json")

      shell = lambda do |argv, on_pid:|
        on_pid.call(12345)
        # simulate whisperx writing the file
        File.write(expected_output, JSON.generate({ language: "en", segments: [] }))
        [true, ""]
      end
      prep = ->(_path, _video) { } # no-op; output already valid

      job = ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo")
      stage = described_class.new(shell: shell, prepare: prep)

      result = stage.run(
        job: job,
        video_path: video,
        transcript_output_dir: transcript_dir,
        language_code: "en",
        whisper_model: "small"
      )

      expect(result[:transcript_path]).to eq(expected_output)
      expect(File.file?(expected_output)).to be true
    end
  end

  it "raises if whisperx returns failure" do
    Dir.mktmpdir do |dir|
      video = File.join(dir, "v.mp4"); File.write(video, "x")
      transcript_dir = File.join(dir, "transcripts"); FileUtils.mkdir_p(transcript_dir)
      shell = ->(_argv, on_pid:) { on_pid.call(1); [false, "boom"] }
      stage = described_class.new(shell: shell, prepare: ->(*) {})
      job = ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo")
      expect {
        stage.run(job: job, video_path: video, transcript_output_dir: transcript_dir,
                  language_code: "en", whisper_model: "small")
      }.to raise_error(/whisperx failed/)
    end
  end
end
```

- [ ] **Step 2: Run, verify fail.** Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/stages/transcribe.rb
# frozen_string_literal: true

require "open3"
require "pathname"

module ButtercutUiSidecar
  module Stages
    class Transcribe
      DEFAULT_PREPARE_SCRIPT = File.expand_path("../../../../../.claude/skills/transcribe-audio/prepare_audio_script.rb", __dir__)

      def initialize(shell: nil, prepare: nil, prepare_script: DEFAULT_PREPARE_SCRIPT)
        @shell = shell || method(:default_shell)
        @prepare = prepare || method(:default_prepare).curry[prepare_script]
      end

      # Returns { transcript_path: <abs path> } on success.
      def run(job:, video_path:, transcript_output_dir:, language_code:, whisper_model:)
        return cancel_result if job.canceled?

        argv = [
          "whisperx", video_path,
          "--language", language_code,
          "--model", whisper_model,
          "--compute_type", "float32",
          "--device", "cpu",
          "--output_format", "json",
          "--output_dir", transcript_output_dir
        ]

        ok, stderr = @shell.call(argv, on_pid: ->(pid) { job.register_pid(pid) })
        raise "whisperx failed: #{stderr.strip}" unless ok
        return cancel_result if job.canceled?

        basename = File.basename(video_path, ".*")
        json_path = File.join(transcript_output_dir, "#{basename}.json")
        raise "whisperx produced no output at #{json_path}" unless File.file?(json_path)

        @prepare.call(json_path, video_path)
        { transcript_path: json_path }
      end

      private

      def cancel_result
        { canceled: true }
      end

      def default_shell(argv, on_pid:)
        stdin, stdout_err, wait_thr = Open3.popen2e(*argv)
        stdin.close
        on_pid.call(wait_thr.pid)
        out = stdout_err.read
        wait_thr.value.success? ? [true, out] : [false, out]
      end

      def default_prepare(prepare_script, json_path, video_path)
        ok, err = run_simple("ruby", prepare_script, json_path, video_path)
        raise "prepare_audio_script failed: #{err.strip}" unless ok
      end

      def run_simple(*argv)
        out, status = Open3.capture2e(*argv)
        [status.success?, out]
      end
    end
  end
end
```

- [ ] **Step 4: Run, verify pass.** Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/stages/transcribe.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/transcribe_spec.rb
git commit -m "M2: transcribe stage — whisperx + prepare with cancellation hooks"
```

---

### Task 4.4: Stage — analyze (frame extraction + Anthropic vision call)

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/stages/analyze.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/analyze_spec.rb`

This stage:
1. Copies the audio transcript to `<visual_transcript_path>`.
2. Runs `prepare_visual_script.rb` to strip word-level timing.
3. Decides which timestamps to sample.
4. Shells out to ffmpeg to extract those frames.
5. Sends one Anthropic Messages call with all frames + the prompt from `prompts/analyze_video.md`.
6. Asks the model to return a JSON object mapping `{ "segments": [...] }` matching the prepared schema.
7. Writes the merged result to `<visual_transcript_path>.tmp` and atomically renames.
8. Cleans up frames.

- [ ] **Step 1: Failing test (mocked vision call)**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/analyze_spec.rb
require "spec_helper"
require "tmpdir"
require "json"
require_relative "../../../../lib/buttercut_ui_sidecar/stages/analyze"
require_relative "../../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::Stages::Analyze do
  let(:job) { ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo") }

  def setup_audio(dir, name: "a.json")
    path = File.join(dir, name)
    File.write(path, JSON.generate(language: "en", video_path: "/x/a.mp4",
      segments: [{ start: 0.0, end: 5.0, text: "hello", words: [] }]))
    path
  end

  it "writes the visual transcript with model-supplied descriptions" do
    Dir.mktmpdir do |dir|
      audio = setup_audio(dir)
      visual = File.join(dir, "visual_a.json")

      ffmpeg = ->(_video, _ts, out_path, on_pid:) { on_pid.call(rand(2**16)); File.write(out_path, "fakejpg"); true }
      vision = ->(_frames, _prompt) { { "segments" => [{ "start" => 0.0, "end" => 5.0, "text" => "hello", "visual" => "scene" }] } }

      stage = described_class.new(ffmpeg: ffmpeg, vision: vision)
      result = stage.run(job: job, video_path: "/x/a.mp4", audio_transcript_path: audio, visual_transcript_path: visual)

      expect(result[:visual_transcript_path]).to eq(visual)
      expect(File.file?(visual)).to be true
      data = JSON.parse(File.read(visual))
      expect(data["segments"].first["visual"]).to eq("scene")
    end
  end

  it "respects cancellation between frame extraction and vision call" do
    Dir.mktmpdir do |dir|
      audio = setup_audio(dir)
      visual = File.join(dir, "visual_a.json")

      ffmpeg = ->(_, _, out_path, on_pid:) { on_pid.call(1); File.write(out_path, "fakejpg"); true }
      vision = ->(_, _) { raise "should not call vision" }

      stage = described_class.new(ffmpeg: ffmpeg, vision: vision)
      job.cancel!
      result = stage.run(job: job, video_path: "/x/a.mp4", audio_transcript_path: audio, visual_transcript_path: visual)
      expect(result[:canceled]).to be true
      expect(File.file?(visual)).to be false
    end
  end
end
```

- [ ] **Step 2: Run, verify fail.** Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/stages/analyze.rb
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "base64"
require "pathname"

module ButtercutUiSidecar
  module Stages
    class Analyze
      def initialize(ffmpeg: nil, vision: nil, prompt_path: default_prompt_path)
        @ffmpeg = ffmpeg || method(:default_ffmpeg)
        @vision = vision # required when not in test mode
        @prompt_path = prompt_path
      end

      def run(job:, video_path:, audio_transcript_path:, visual_transcript_path:)
        return cancel_result if job.canceled?

        prepared = prepare_skeleton(audio_transcript_path)
        timestamps = sample_timestamps(prepared)
        frames = extract_frames(job, video_path, timestamps)
        return cancel_result if job.canceled?

        prompt = File.read(@prompt_path)
        response = @vision.call(frames, prompt + "\n\nHere is the prepared transcript skeleton (JSON):\n" + JSON.pretty_generate(prepared))
        return cancel_result if job.canceled?

        merged = merge_segments(prepared, response.fetch("segments"))
        atomic_write_json(visual_transcript_path, merged)

        cleanup_frames(frames)
        { visual_transcript_path: visual_transcript_path }
      end

      def self.default_prompt_path
        File.expand_path("../../../prompts/analyze_video.md", __dir__)
      end

      private

      def default_prompt_path
        self.class.default_prompt_path
      end

      def prepare_skeleton(audio_path)
        data = JSON.parse(File.read(audio_path))
        # Strip word-level timing to keep the visual transcript small (mirrors
        # .claude/skills/analyze-video/prepare_visual_script.rb).
        if data["segments"]
          data["segments"] = data["segments"].map do |s|
            s.dup.tap { |c| c.delete("words") }
          end
        end
        data
      end

      def sample_timestamps(prepared)
        duration = (prepared.dig("segments", -1, "end") || 0).to_f
        return [duration / 2.0] if duration <= 30
        [2.0, duration / 2.0, [duration - 2.0, 2.0].max]
      end

      def extract_frames(job, video_path, timestamps)
        tmp_dir = File.join(Dir.tmpdir, "buttercut-frames-#{job.id}-#{File.basename(video_path, ".*")}")
        FileUtils.mkdir_p(tmp_dir)
        frames = []
        timestamps.each_with_index do |ts, i|
          return frames if job.canceled?
          out = File.join(tmp_dir, "frame_#{i}.jpg")
          ok = @ffmpeg.call(video_path, ts, out, on_pid: ->(pid) { job.register_pid(pid) })
          frames << out if ok && File.file?(out)
        end
        frames
      end

      def merge_segments(prepared, response_segments)
        # Map response segments by start time to the skeleton; preserve any
        # fields the model didn't touch.
        by_start = response_segments.each_with_object({}) { |s, h| h[s["start"].to_f] = s }
        prepared["segments"] = prepared["segments"].map do |skel|
          rs = by_start[skel["start"].to_f] || {}
          skel.merge(rs.slice("visual", "b_roll"))
        end
        # Append any b-roll-only segments from the response that weren't in the skeleton.
        skel_starts = prepared["segments"].map { |s| s["start"].to_f }.to_set
        extras = response_segments.reject { |s| skel_starts.include?(s["start"].to_f) }
        prepared["segments"].concat(extras)
        prepared
      end

      def atomic_write_json(path, data)
        tmp = path + ".tmp"
        File.write(tmp, JSON.pretty_generate(data))
        File.rename(tmp, path)
      end

      def cleanup_frames(frames)
        return if frames.empty?
        FileUtils.rm_rf(File.dirname(frames.first))
      end

      def cancel_result
        { canceled: true }
      end

      def default_ffmpeg(video_path, timestamp, out_path, on_pid:)
        cmd = ["ffmpeg", "-ss", format_ts(timestamp), "-i", video_path,
               "-vframes", "1", "-vf", "scale=1280:-1", "-y", out_path]
        stdin, stdout_err, wait_thr = Open3.popen2e(*cmd)
        stdin.close
        on_pid.call(wait_thr.pid)
        stdout_err.read
        wait_thr.value.success?
      end

      def format_ts(seconds)
        s = seconds.to_f
        format("%02d:%02d:%06.3f", s / 3600, (s.to_i % 3600) / 60, s % 60)
      end
    end
  end
end
```

The `vision:` callable receives `(frames, prompt_with_skeleton)` and returns the parsed segments hash. The default production wiring passes a closure that calls `AnthropicClient.messages_create` with `model: VISION_MODEL`, `messages: [{ role: "user", content: <image blocks + text block> }]`, asks for JSON output, and parses the response. That wiring lives in the controller (Task 4.6) so the stage stays pure.

- [ ] **Step 4: Run, verify pass.** Expected: 2 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/stages/analyze.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/analyze_spec.rb
git commit -m "M2: analyze stage — frame sampling, vision call, atomic merge"
```

---

### Task 4.5: Stage — summarize (Anthropic Haiku call)

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/stages/summarize.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/summarize_spec.rb`

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/summarize_spec.rb
require "spec_helper"
require "tmpdir"
require "json"
require_relative "../../../../lib/buttercut_ui_sidecar/stages/summarize"
require_relative "../../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::Stages::Summarize do
  it "writes the markdown summary atomically using the supplied Haiku callable" do
    Dir.mktmpdir do |dir|
      visual = File.join(dir, "visual_a.json")
      File.write(visual, JSON.generate(language: "en", video_path: "/x/a.mp4", segments: [
        { start: 0.0, end: 5.0, text: "hello", visual: "scene" }
      ]))
      summary_path = File.join(dir, "summary_a.md")

      haiku = ->(_prompt) { "## Overview\n\nMan says hello.\n\n## Key visuals\n- scene\n\n## Dialogue\n\nNone\n\n## B-roll\n\nNone\n" }
      stage = described_class.new(haiku: haiku)
      job = ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo")

      result = stage.run(job: job, visual_transcript_path: visual, summary_output_path: summary_path)
      expect(result[:summary_path]).to eq(summary_path)
      expect(File.read(summary_path)).to include("## Overview")
    end
  end
end
```

- [ ] **Step 2: Run, verify fail.** Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/stages/summarize.rb
# frozen_string_literal: true

require "json"

module ButtercutUiSidecar
  module Stages
    class Summarize
      def initialize(haiku: nil, prompt_path: default_prompt_path)
        @haiku = haiku
        @prompt_path = prompt_path
      end

      def run(job:, visual_transcript_path:, summary_output_path:)
        return cancel_result if job.canceled?
        script = extract_script(visual_transcript_path)
        prompt = File.read(@prompt_path) + "\n\n## Visual transcript\n\n" + script
        markdown = @haiku.call(prompt)
        return cancel_result if job.canceled?
        atomic_write(summary_output_path, markdown)
        { summary_path: summary_output_path }
      end

      def self.default_prompt_path
        File.expand_path("../../../prompts/summarize_video.md", __dir__)
      end

      private

      def default_prompt_path
        self.class.default_prompt_path
      end

      def extract_script(visual_path)
        data = JSON.parse(File.read(visual_path))
        lines = []
        (data["segments"] || []).each do |s|
          ts = format_ts(s["start"].to_f)
          lines << "[VISUAL] #{s['visual']}" if s["visual"]
          lines << "[#{ts}] #{s['text']}" if s["text"] && !s["text"].empty?
        end
        lines.join("\n")
      end

      def format_ts(seconds)
        format("[%02d:%02d]", seconds.to_i / 60, seconds.to_i % 60)
      end

      def atomic_write(path, body)
        tmp = path + ".tmp"
        File.write(tmp, body)
        File.rename(tmp, path)
      end

      def cancel_result
        { canceled: true }
      end
    end
  end
end
```

- [ ] **Step 4: Run, verify pass.** Expected: 1 example, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/stages/summarize.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/stages/summarize_spec.rb
git commit -m "M2: summarize stage — Haiku call writes summary markdown atomically"
```

---

### Task 4.6: Analysis controller — pools, dispatch, yaml updates, notifications

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/analysis_controller.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/analysis_controller_spec.rb`

This is the orchestrator. Inputs: a `library_dir`, a `notifier`, an `AnthropicClient`, a `JobRegistry`. Outputs: starts a job, returns the `job_id`, drives the worker pools, emits notifications, updates `library.yaml` after each artifact. This is the biggest single piece — the test exercises the happy path with stub stages.

- [ ] **Step 1: Failing test**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/analysis_controller_spec.rb
require "spec_helper"
require "tmpdir"
require "json"
require "stringio"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/notifier"
require_relative "../../../lib/buttercut_ui_sidecar/job_registry"
require_relative "../../../lib/buttercut_ui_sidecar/analysis_controller"

RSpec.describe ButtercutUiSidecar::AnalysisController do
  def make_library(root, name: "demo", videos:)
    lib_dir = File.join(root, name)
    FileUtils.mkdir_p(File.join(lib_dir, "transcripts"))
    FileUtils.mkdir_p(File.join(lib_dir, "summaries"))
    File.write(File.join(lib_dir, "library.yaml"), YAML.dump(
      "library_name" => name, "language" => "English", "language_code" => "en",
      "transcript_refinement" => false, "videos" => videos.map { |v| { "path" => v, "duration" => "00:00:05" } }
    ))
    lib_dir
  end

  it "runs all three stages for one video and updates library.yaml" do
    Dir.mktmpdir do |root|
      v = File.join(root, "a.mp4")
      File.write(v, "x")
      lib_dir = make_library(root, videos: [v])

      io = StringIO.new
      notifier = ButtercutUiSidecar::Notifier.new(io: io)
      registry = ButtercutUiSidecar::JobRegistry.new

      transcribe = double("transcribe")
      analyze = double("analyze")
      summarize = double("summarize")
      allow(transcribe).to receive(:run) do |args|
        path = File.join(args[:transcript_output_dir], "a.json")
        File.write(path, JSON.generate(segments: []))
        { transcript_path: path }
      end
      allow(analyze).to receive(:run) do |args|
        File.write(args[:visual_transcript_path], JSON.generate(segments: []))
        { visual_transcript_path: args[:visual_transcript_path] }
      end
      allow(summarize).to receive(:run) do |args|
        File.write(args[:summary_output_path], "## Overview")
        { summary_path: args[:summary_output_path] }
      end

      controller = described_class.new(
        libraries_root: root, notifier: notifier, registry: registry,
        transcribe: transcribe, analyze: analyze, summarize: summarize,
        whisper_model: "small"
      )
      job_id = controller.start!(library: "demo")

      controller.wait!(job_id)

      data = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
      v0 = data["videos"].first
      expect(v0["transcript"]).to eq("a.json")
      expect(v0["visual_transcript"]).to eq("visual_a.json")
      expect(v0["summary"]).to eq("summary_a.md")

      events = io.string.lines.map { |l| JSON.parse(l) }
      methods = events.map { |e| e["method"] }
      expect(methods).to include("job_started", "file_started", "artifact_ready", "file_done", "job_done")
    end
  end
end
```

- [ ] **Step 2: Run, verify fail.** Expected: LoadError.

- [ ] **Step 3: Implement**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/analysis_controller.rb
# frozen_string_literal: true

require "concurrent"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "yaml"
require_relative "limits"
require_relative "analysis_job"

module ButtercutUiSidecar
  class AnalysisController
    def initialize(libraries_root:, notifier:, registry:,
                   transcribe:, analyze:, summarize:,
                   whisper_model: "small")
      @libraries_root = Pathname.new(libraries_root)
      @notifier = notifier
      @registry = registry
      @stages = { transcribe: transcribe, analyze: analyze, summarize: summarize }
      @whisper_model = whisper_model
    end

    # Kicks off a job and returns its id immediately. Use #wait! in tests.
    def start!(library:)
      job_id = "job-#{SecureRandom.hex(6)}"
      job = AnalysisJob.new(id: job_id, library: library)
      @registry.put(job_id, job)

      lib_dir = @libraries_root.join(library)
      data = read_yaml(lib_dir)
      videos = (data["videos"] || []).reject { |v| v["transcript"] && !v["transcript"].empty? && v["visual_transcript"] && !v["visual_transcript"].empty? && v["summary"] && !v["summary"].empty? }
      total = videos.length
      @notifier.notify("job_started", job_id: job_id, library: library, video_count: total)

      pools = build_pools

      done = Concurrent::AtomicFixnum.new(0)
      failed = Concurrent::AtomicFixnum.new(0)

      @completion_latch = Concurrent::CountDownLatch.new(1) unless total.positive?
      @completion_latch ||= Concurrent::CountDownLatch.new(1)

      remaining_units = Concurrent::AtomicFixnum.new(total * 3)

      complete_unit = lambda do |succeeded|
        succeeded ? done.increment : failed.increment
        if remaining_units.decrement.zero?
          @notifier.notify("job_done", job_id: job_id,
                           succeeded_count: done.value, failed_count: failed.value)
          shutdown_pools(pools)
          @registry.delete(job_id)
          @completion_latch.count_down
        end
      end

      videos.each do |v|
        chain_stages(job: job, video: v, lib_dir: lib_dir, pools: pools, on_complete: complete_unit, data: data)
      end

      @completion_latch.count_down if total.zero?

      job_id
    end

    # Test helper.
    def wait!(_job_id, timeout: 30)
      @completion_latch.wait(timeout)
    end

    private

    def build_pools
      {
        transcribe: Concurrent::FixedThreadPool.new(Limits::TRANSCRIBE_PARALLELISM),
        analyze:    Concurrent::FixedThreadPool.new(Limits::ANALYZE_PARALLELISM),
        summarize:  Concurrent::FixedThreadPool.new(Limits::SUMMARIZE_PARALLELISM)
      }
    end

    def shutdown_pools(pools)
      pools.values.each(&:shutdown)
    end

    def chain_stages(job:, video:, lib_dir:, pools:, on_complete:, data:)
      basename = File.basename(video["path"])
      stem = File.basename(basename, ".*")
      transcripts_dir = lib_dir.join("transcripts").to_s
      summaries_dir = lib_dir.join("summaries").to_s
      audio_path   = File.join(transcripts_dir, "#{stem}.json")
      visual_path  = File.join(transcripts_dir, "visual_#{stem}.json")
      summary_path = File.join(summaries_dir,   "summary_#{stem}.md")

      transcribe_step = lambda do
        return if video["transcript"] && !video["transcript"].empty?
        @stages[:transcribe].run(
          job: job, video_path: video["path"], transcript_output_dir: transcripts_dir,
          language_code: data["language_code"] || "en", whisper_model: @whisper_model
        )
        update_yaml_field(lib_dir, video["path"], "transcript", File.basename(audio_path))
      end

      analyze_step = lambda do
        return if video["visual_transcript"] && !video["visual_transcript"].empty?
        @stages[:analyze].run(
          job: job, video_path: video["path"],
          audio_transcript_path: audio_path, visual_transcript_path: visual_path
        )
        update_yaml_field(lib_dir, video["path"], "visual_transcript", File.basename(visual_path))
      end

      summarize_step = lambda do
        return if video["summary"] && !video["summary"].empty?
        @stages[:summarize].run(
          job: job, visual_transcript_path: visual_path, summary_output_path: summary_path
        )
        update_yaml_field(lib_dir, video["path"], "summary", File.basename(summary_path))
      end

      # Sequential per video, parallel across videos. Each stage's `run_step`
      # emits file_started / artifact_ready / file_done (or file_failed) and
      # calls on_complete exactly once. On success, enqueues the next stage.
      pools[:transcribe].post do
        run_step(job: job, stage: :transcribe, video: basename,
                 artifact_path: audio_path, on_complete: on_complete,
                 on_success: -> { pools[:analyze].post { analyze_in_pool.call } }) { transcribe_step.call }
      end

      analyze_in_pool = lambda do
        run_step(job: job, stage: :analyze, video: basename,
                 artifact_path: visual_path, on_complete: on_complete,
                 on_success: -> { pools[:summarize].post { summarize_in_pool.call } }) { analyze_step.call }
      end

      summarize_in_pool = lambda do
        run_step(job: job, stage: :summarize, video: basename,
                 artifact_path: summary_path, on_complete: on_complete,
                 on_success: -> { }) { summarize_step.call }
      end
    end

    # Per-stage worker body. Emits notifications and calls on_complete exactly
    # once. On success, runs on_success (which typically enqueues the next stage).
    def run_step(job:, stage:, video:, artifact_path:, on_complete:, on_success:)
      if job.canceled?
        on_complete.call(false)
        return
      end
      @notifier.notify("file_started", job_id: job.id, video: video, stage: stage.to_s)
      begin
        yield
        @notifier.notify("artifact_ready", job_id: job.id, video: video, stage: stage.to_s, artifact_path: artifact_path)
        @notifier.notify("file_done", job_id: job.id, video: video, stage: stage.to_s)
        on_complete.call(true)
        on_success.call
      rescue StandardError => e
        @notifier.notify("file_failed", job_id: job.id, video: video, stage: stage.to_s,
                         error_kind: classify_error(e), message: e.message)
        on_complete.call(false)
      end
    end

    def classify_error(error)
      case error.message
      when /invalid_api_key/i, /AuthenticationError/i then "auth"
      when /whisperx failed/i then "transcribe"
      when /ffmpeg/i then "ffmpeg"
      else "unknown"
      end
    end

    def read_yaml(lib_dir)
      YAML.safe_load(File.read(lib_dir.join("library.yaml")), permitted_classes: [Date, Time], aliases: true) || {}
    end

    def update_yaml_field(lib_dir, video_path, field, value)
      job_id = nil # reserved for log if needed
      yaml_path = lib_dir.join("library.yaml")
      lock_file = yaml_path.to_s + ".lock"
      File.open(lock_file, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        data = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date, Time], aliases: true) || {}
        (data["videos"] || []).each do |v|
          v[field] = value if v["path"] == video_path
        end
        data["last_updated"] = Date.today.iso8601
        File.write(yaml_path.to_s + ".tmp", YAML.dump(data))
        File.rename(yaml_path.to_s + ".tmp", yaml_path.to_s)
      end
    end
  end
end
```

**Note on `analyze_in_pool` / `summarize_in_pool`:** these are forward-referenced lambdas — Ruby allows this because the lambda variables aren't dereferenced until the outer `pools[:transcribe].post` block actually runs, by which time both inner lambdas are bound. If your linter complains about use-before-define, rearrange so all three lambdas are declared before the first `pools[:transcribe].post` call.

- [ ] **Step 4: Run, verify pass.** Expected: 1 example, 0 failures.

- [ ] **Step 5: Stress test cancellation manually**

Add a second test that calls `controller.start!`, sleeps briefly, then `job.cancel!` and verifies a `job_done` event still arrives with `failed_count > 0`. Skip if implementation time is short — covered by the integration smoke phase.

- [ ] **Step 6: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/analysis_controller.rb ui/sidecar/spec/lib/buttercut_ui_sidecar/analysis_controller_spec.rb
git commit -m "M2: AnalysisController orchestrates the three-stage pipeline with notifications"
```

---

### Task 4.7: Wire `start_analysis`, `cancel_job`, `retry_unit` into the dispatcher

**Files:**
- Modify: `ui/sidecar/buttercut_ui_sidecar.rb`

- [ ] **Step 1: Update dispatcher**

In `initialize`, after the existing wiring, add:

```ruby
@registry = ButtercutUiSidecar::JobRegistry.new
@anthropic = nil # lazy: only built when start_analysis fires and a key is configured
```

Add helper:

```ruby
def build_controller_or_raise!
  api_key = @settings.api_key
  raise StandardError, "missing_api_key" if api_key.nil?

  client = ButtercutUiSidecar::AnthropicClient.new(api_key: api_key)

  vision = ->(frames, prompt) {
    content = frames.map { |f| { type: "image", source: { type: "base64", media_type: "image/jpeg", data: Base64.strict_encode64(File.binread(f)) } } }
    content << { type: "text", text: prompt + "\n\nReturn ONLY a JSON object of the form {\"segments\": [...]}, no prose." }
    response = client.messages_create(
      model: ButtercutUiSidecar::AnthropicClient::VISION_MODEL,
      max_tokens: 4096,
      messages: [{ role: "user", content: content }]
    )
    text = (response["content"] || []).map { |c| c["text"] }.compact.join
    JSON.parse(text[/\{.*\}/m])
  }

  haiku = ->(prompt) {
    response = client.messages_create(
      model: ButtercutUiSidecar::AnthropicClient::HAIKU_MODEL,
      max_tokens: 1024,
      messages: [{ role: "user", content: prompt }]
    )
    (response["content"] || []).map { |c| c["text"] }.compact.join
  }

  ButtercutUiSidecar::AnalysisController.new(
    libraries_root: @libraries_root.to_s,
    notifier: @notifier,
    registry: @registry,
    transcribe: ButtercutUiSidecar::Stages::Transcribe.new,
    analyze: ButtercutUiSidecar::Stages::Analyze.new(vision: vision),
    summarize: ButtercutUiSidecar::Stages::Summarize.new(haiku: haiku),
    whisper_model: read_whisper_model
  )
end

def read_whisper_model
  path = @libraries_root.join("settings.yaml")
  return "small" unless path.file?
  data = YAML.safe_load(path.read, permitted_classes: [Date, Time], aliases: true) || {}
  data["whisper_model"] || "small"
end
```

In `dispatch`, add cases:

```ruby
when "start_analysis"
  controller = build_controller_or_raise!
  job_id = controller.start!(library: params.fetch("library"))
  { job_id: job_id }
when "cancel_job"
  job = @registry.get(params.fetch("job_id"))
  job&.cancel!
  {}
when "retry_unit"
  raise StandardError, "retry_unit is not yet supported in M2 minimum scope; re-run start_analysis to resume."
```

In `handle_line`, add:

```ruby
rescue StandardError => e
  case e.message
  when /\Amissing_api_key/
    respond_error(id: id, code: -32010, message: "missing_api_key")
  when /\Ainvalid_api_key/
    respond_error(id: id, code: -32012, message: e.message)
  else
    respond_error(id: id, code: -32000, message: "#{e.class}: #{e.message}")
  end
```

(Adjust the existing `StandardError` rescue rather than adding a duplicate.)

Also `require_relative` the new files at the top:

```ruby
require_relative "lib/buttercut_ui_sidecar/job_registry"
require_relative "lib/buttercut_ui_sidecar/analysis_job"
require_relative "lib/buttercut_ui_sidecar/analysis_controller"
require_relative "lib/buttercut_ui_sidecar/stages/transcribe"
require_relative "lib/buttercut_ui_sidecar/stages/analyze"
require_relative "lib/buttercut_ui_sidecar/stages/summarize"
require "base64"
```

- [ ] **Step 2: Run M0/M1 specs to make sure nothing regresses**

Run: `bundle exec rake spec`
Expected: all green.

- [ ] **Step 3: Smoke-test the missing-key path**

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"start_analysis","params":{"library":"demo"}}' | bundle exec ruby buttercut_ui_sidecar.rb /tmp
```
Expected: response with `error.code: -32010` and message `missing_api_key`.

- [ ] **Step 4: Commit**

```bash
git add ui/sidecar/buttercut_ui_sidecar.rb
git commit -m "M2: dispatch start_analysis, cancel_job, retry_unit (deferred)"
```

---

### Task 4.8: Add Phase-4 dependencies to settings template

**Files:**
- Modify: `templates/settings_template.yaml`

- [ ] **Step 1: Read the existing template**

Run: `cat templates/settings_template.yaml`

- [ ] **Step 2: Add the API key field placeholder**

Append:
```yaml
# Anthropic API key for the desktop UI's analysis pipeline. The CLI flow
# uses Claude Code's own auth and ignores this field. Optional — the env
# var ANTHROPIC_API_KEY takes precedence when set.
anthropic_api_key: ""
```

- [ ] **Step 3: Commit**

```bash
git add templates/settings_template.yaml
git commit -m "M2: document anthropic_api_key in settings template"
```

---

## Phase 5 — Rust IPC layer

### Task 5.1: Notification deserialization in the reader

**Files:**
- Modify: `ui/src-tauri/src/sidecar.rs`

- [ ] **Step 1: Read the current state**

Run: `cat ui/src-tauri/src/sidecar.rs | head -160`

- [ ] **Step 2: Modify `init` to accept an `AppHandle`**

Change the signature from:
```rust
pub fn init(ruby_bin: PathBuf, sidecar_script: PathBuf, libraries_root: PathBuf) -> std::io::Result<()>
```
to:
```rust
pub fn init(app: tauri::AppHandle, ruby_bin: PathBuf, sidecar_script: PathBuf, libraries_root: PathBuf) -> std::io::Result<()>
```
and pass `app` into the reader task closure (clone it before spawning).

- [ ] **Step 3: Add a `Notification` deserializer**

Below the existing `Response` struct, add:
```rust
#[derive(Deserialize)]
struct Notification {
    method: String,
    #[serde(default)]
    params: Value,
}
```

- [ ] **Step 4: In the reader task, branch on `id`**

Replace the inner `match serde_json::from_str::<Response>(&line)` block with:

```rust
match serde_json::from_str::<Response>(&line) {
    Ok(resp) if resp.id.is_some() => {
        let id = resp.id.unwrap();
        let mut map = pending_for_reader.lock().await;
        if let Some(tx) = map.remove(&id) {
            let payload = if let Some(err) = resp.error {
                Err(SidecarError::Rpc { code: err.code, message: err.message })
            } else {
                Ok(resp.result.unwrap_or(Value::Null))
            };
            let _ = tx.send(payload);
        }
    }
    _ => {
        match serde_json::from_str::<Notification>(&line) {
            Ok(n) => {
                let job_id = n.params.get("job_id").and_then(|v| v.as_str()).unwrap_or("");
                let event_name = if job_id.is_empty() {
                    "sidecar-event".to_string()
                } else {
                    format!("sidecar-event:{}", job_id)
                };
                let payload = serde_json::json!({ "method": n.method, "params": n.params });
                if let Err(e) = app_for_reader.emit(&event_name, payload) {
                    eprintln!("[sidecar] emit error: {e}");
                }
            }
            Err(e) => {
                eprintln!("[sidecar] parse error: {e}: {line}");
            }
        }
    }
}
```

(Clone `app` into `app_for_reader` before the `tokio::spawn` call. The trait import at the top of the file: `use tauri::Manager;` is already present in `lib.rs`; here we need `use tauri::Emitter;` — add it.)

- [ ] **Step 5: Update `lib.rs` `setup` to pass the AppHandle**

In `ui/src-tauri/src/lib.rs`, replace:
```rust
sidecar::init(ruby_bin, sidecar_script, libraries_root)
```
with:
```rust
sidecar::init(app.handle().clone(), ruby_bin, sidecar_script, libraries_root)
```

- [ ] **Step 6: Build**

Run: `cd ui/src-tauri && cargo check`
Expected: compiles clean.

- [ ] **Step 7: Commit**

```bash
git add ui/src-tauri/src/sidecar.rs ui/src-tauri/src/lib.rs
git commit -m "M2: forward sidecar JSON-RPC notifications as scoped Tauri events"
```

---

### Task 5.2: New Tauri commands

**Files:**
- Modify: `ui/src-tauri/src/lib.rs`

- [ ] **Step 1: Add command wrappers** at the top, alongside existing ones:

```rust
#[tauri::command]
async fn inspect_video_paths(paths: Vec<String>) -> Result<Value, String> {
    sidecar::call("inspect_video_paths", json!({ "paths": paths })).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_library(
    name: String, language: String, language_code: String,
    refinement: bool, videos: Value
) -> Result<Value, String> {
    sidecar::call("create_library", json!({
        "name": name, "language": language, "language_code": language_code,
        "refinement": refinement, "videos": videos
    })).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn has_api_key() -> Result<Value, String> {
    sidecar::call("has_api_key", json!({})).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn set_api_key(key: String) -> Result<Value, String> {
    sidecar::call("set_api_key", json!({ "key": key })).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn start_analysis(library: String) -> Result<Value, String> {
    sidecar::call("start_analysis", json!({ "library": library })).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn cancel_job(job_id: String) -> Result<Value, String> {
    sidecar::call("cancel_job", json!({ "job_id": job_id })).await.map_err(|e| e.to_string())
}
```

- [ ] **Step 2: Add `open_new_project_window`** alongside `open_library_window`:

```rust
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
```

- [ ] **Step 3: Register the new commands** in `tauri::generate_handler![...]`:

```rust
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
    cancel_job
])
```

- [ ] **Step 4: Build**

Run: `cd ui/src-tauri && cargo check`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add ui/src-tauri/src/lib.rs
git commit -m "M2: add Tauri commands for new RPCs and the New Project window"
```

---

### Task 5.3: Capability for events

**Files:**
- Inspect: `ui/src-tauri/capabilities/default.json`

- [ ] **Step 1: Read the capability file**

Run: `cat ui/src-tauri/capabilities/default.json`

- [ ] **Step 2: Ensure `core:event:default` is permitted**

If it's not in the permissions list, add it:
```json
"core:event:default"
```
(Tauri 2's default permission set usually already grants `event:listen`. If `pnpm tauri dev` later complains about a missing permission for `listen`, return here.)

- [ ] **Step 3: Build smoke**

Run: `cd ui && pnpm build`
Expected: clean.

- [ ] **Step 4: Commit (skip if no change)**

```bash
git add -A
git diff --cached --quiet || git commit -m "M2: ensure event listen permission is granted"
```

---

## Phase 6 — Frontend wiring

### Task 6.1: Typed RPC wrappers

**Files:**
- Modify: `ui/src/ipc/sidecar.ts`

- [ ] **Step 1: Append the new wrappers**

Add after the existing exports:

```ts
export interface AcceptedVideo { path: string; duration_seconds: number; size_bytes: number; }
export interface RejectedVideo { path: string; reason: "not_found" | "not_video" | "unreadable" | "zero_duration"; }
export interface InspectResult { accepted: AcceptedVideo[]; rejected: RejectedVideo[]; }

export async function inspectVideoPaths(paths: string[]): Promise<InspectResult> {
  return invoke<InspectResult>("inspect_video_paths", { paths });
}

export async function hasApiKey(): Promise<{ configured: boolean }> {
  return invoke<{ configured: boolean }>("has_api_key");
}

export async function setApiKey(key: string): Promise<{ ok: true }> {
  return invoke<{ ok: true }>("set_api_key", { key });
}

export interface CreateLibraryArgs {
  name: string;
  language: string;
  language_code: string;
  refinement: boolean;
  videos: AcceptedVideo[];
}

export async function createLibrary(args: CreateLibraryArgs): Promise<{ name: string }> {
  return invoke<{ name: string }>("create_library", args);
}

export async function startAnalysis(library: string): Promise<{ job_id: string }> {
  return invoke<{ job_id: string }>("start_analysis", { library });
}

export async function cancelJob(jobId: string): Promise<void> {
  await invoke("cancel_job", { job_id: jobId });
}

export async function openNewProjectWindow(): Promise<void> {
  await invoke("open_new_project_window");
}
```

- [ ] **Step 2: Build**

Run: `cd ui && pnpm build`
Expected: clean (TypeScript happy).

- [ ] **Step 3: Commit**

```bash
git add ui/src/ipc/sidecar.ts
git commit -m "M2: typed wrappers for the new sidecar RPCs"
```

---

### Task 6.2: Typed event listener

**Files:**
- Create: `ui/src/ipc/events.ts`

- [ ] **Step 1: Implement**

```ts
// ui/src/ipc/events.ts
import { listen, UnlistenFn } from "@tauri-apps/api/event";

export type StageName = "transcribe" | "analyze" | "summarize";

export type JobEvent =
  | { method: "job_started"; params: { job_id: string; library: string; video_count: number; ts: string } }
  | { method: "file_started"; params: { job_id: string; video: string; stage: StageName; ts: string } }
  | { method: "file_progress"; params: { job_id: string; video: string; stage: StageName; message?: string; percent?: number; ts: string } }
  | { method: "artifact_ready"; params: { job_id: string; video: string; stage: StageName; artifact_path: string; ts: string } }
  | { method: "file_failed"; params: { job_id: string; video: string; stage: StageName; error_kind: string; message: string; ts: string } }
  | { method: "file_done"; params: { job_id: string; video: string; stage: StageName; ts: string } }
  | { method: "job_done"; params: { job_id: string; succeeded_count: number; failed_count: number; ts: string } }
  | { method: "job_canceled"; params: { job_id: string; succeeded_count: number; failed_count: number; ts: string } };

export async function listenJobEvents(
  jobId: string,
  handler: (event: JobEvent) => void,
): Promise<UnlistenFn> {
  return listen<JobEvent>(`sidecar-event:${jobId}`, (e) => handler(e.payload));
}
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/ipc/events.ts
git commit -m "M2: typed JobEvent listener bound to sidecar-event:JOB"
```

---

### Task 6.3: Routing — register `/new-project`

**Files:**
- Modify: `ui/src/main.tsx`

- [ ] **Step 1: Edit**

```tsx
import React from "react";
import ReactDOM from "react-dom/client";
import "./styles/theme.css";
import Projects from "./routes/projects";
import Library from "./routes/library";
import NewProject from "./routes/new-project";

function pickRoute() {
  const hash = window.location.hash || "";
  const lib = hash.match(/^#\/library\/(.+)$/);
  if (lib) {
    try { return <Library name={decodeURIComponent(lib[1])} />; } catch { return <Projects />; }
  }
  if (hash === "#/new-project") {
    return <NewProject />;
  }
  return <Projects />;
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>{pickRoute()}</React.StrictMode>,
);
```

- [ ] **Step 2: Skip build until the component exists** — moves to next task.

---

### Task 6.4: New Project state machine

**Files:**
- Create: `ui/src/routes/new-project/state.ts`

- [ ] **Step 1: Implement**

```ts
// ui/src/routes/new-project/state.ts
import { AcceptedVideo, RejectedVideo } from "../../ipc/sidecar";

export type StepId = "footage" | "name" | "language" | "refinement" | "confirm";

export interface SetupState {
  step: StepId;
  accepted: AcceptedVideo[];
  rejected: RejectedVideo[];
  name: string;
  language: { name: string; code: string };
  refinement: boolean;
  collisionWith: string | null;
}

export const initialSetup: SetupState = {
  step: "footage",
  accepted: [],
  rejected: [],
  name: "",
  language: { name: "English", code: "en" },
  refinement: true,
  collisionWith: null,
};

export type SetupAction =
  | { type: "add_files"; accepted: AcceptedVideo[]; rejected: RejectedVideo[] }
  | { type: "remove_file"; path: string }
  | { type: "set_name"; value: string }
  | { type: "set_collision"; value: string | null }
  | { type: "set_language"; name: string; code: string }
  | { type: "set_refinement"; value: boolean }
  | { type: "go_step"; step: StepId };

export function setupReducer(state: SetupState, action: SetupAction): SetupState {
  switch (action.type) {
    case "add_files": {
      const existing = new Set(state.accepted.map((v) => v.path));
      const merged = [...state.accepted, ...action.accepted.filter((v) => !existing.has(v.path))];
      return { ...state, accepted: merged, rejected: [...state.rejected, ...action.rejected] };
    }
    case "remove_file":
      return { ...state, accepted: state.accepted.filter((v) => v.path !== action.path) };
    case "set_name":
      return { ...state, name: action.value };
    case "set_collision":
      return { ...state, collisionWith: action.value };
    case "set_language":
      return { ...state, language: { name: action.name, code: action.code } };
    case "set_refinement":
      return { ...state, refinement: action.value };
    case "go_step":
      return { ...state, step: action.step };
  }
}

export function slugify(name: string): string {
  return name.toLowerCase().replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "").replace(/-+/g, "-").replace(/^-|-$/g, "");
}
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/routes/new-project/state.ts
git commit -m "M2: setup-phase reducer + slugify helper"
```

---

### Task 6.5: Step components (5 files)

**Files:**
- Create: `ui/src/routes/new-project/steps/pick-footage.tsx`
- Create: `ui/src/routes/new-project/steps/name.tsx`
- Create: `ui/src/routes/new-project/steps/language.tsx`
- Create: `ui/src/routes/new-project/steps/refinement.tsx`
- Create: `ui/src/routes/new-project/steps/confirm.tsx`

- [ ] **Step 1: Implement `pick-footage.tsx`**

```tsx
import { useEffect } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { inspectVideoPaths, AcceptedVideo, RejectedVideo } from "../../../ipc/sidecar";
import { SetupState, SetupAction } from "../state";

export function PickFootage({ state, dispatch, onNext }: {
  state: SetupState;
  dispatch: React.Dispatch<SetupAction>;
  onNext: () => void;
}) {
  useEffect(() => {
    const unlistenP = getCurrentWebview().onDragDropEvent(async (event) => {
      if (event.payload.type === "drop") {
        const result = await inspectVideoPaths(event.payload.paths);
        dispatch({ type: "add_files", accepted: result.accepted, rejected: result.rejected });
      }
    });
    return () => { unlistenP.then((fn) => fn()); };
  }, [dispatch]);

  async function chooseFolder() {
    const picked = await open({ directory: true });
    if (!picked) return;
    // For folders, we'd need a sidecar enumerate step. Simpler: read directory contents
    // by calling inspect on the picked path; the sidecar treats a directory as not_video,
    // so for v1 we use the multi-file picker for folder contents and document folder support
    // as drop-only. Replace with a sidecar enumerate RPC in a follow-up.
    const result = await inspectVideoPaths([picked as string]);
    dispatch({ type: "add_files", accepted: result.accepted, rejected: result.rejected });
  }

  async function chooseFiles() {
    const picked = await open({ multiple: true });
    if (!picked) return;
    const paths = Array.isArray(picked) ? (picked as string[]) : [picked as string];
    const result = await inspectVideoPaths(paths);
    dispatch({ type: "add_files", accepted: result.accepted, rejected: result.rejected });
  }

  return (
    <section className="np-step">
      <h2>Pick footage</h2>
      <div className="np-dropzone">
        <p>Drop a folder or video files here.</p>
        <div className="np-dropzone__buttons">
          <button onClick={chooseFolder}>Choose folder…</button>
          <button onClick={chooseFiles}>Choose files…</button>
        </div>
      </div>

      {state.accepted.length > 0 && (
        <ul className="np-filelist">
          {state.accepted.map((v) => (
            <li key={v.path}>
              <span className="np-filelist__name">{v.path.split("/").pop()}</span>
              <span className="np-filelist__dur">{formatDuration(v.duration_seconds)}</span>
              <button className="np-filelist__remove" onClick={() => dispatch({ type: "remove_file", path: v.path })}>×</button>
            </li>
          ))}
        </ul>
      )}

      {state.rejected.length > 0 && (
        <details className="np-rejected">
          <summary>{state.rejected.length} skipped</summary>
          <ul>
            {state.rejected.map((r) => (
              <li key={r.path}>{r.path.split("/").pop()} — {r.reason}</li>
            ))}
          </ul>
        </details>
      )}

      <footer className="np-footer">
        <button disabled={state.accepted.length === 0} onClick={onNext}>Continue</button>
      </footer>
    </section>
  );
}

function formatDuration(s: number) {
  const m = Math.floor(s / 60); const r = Math.floor(s % 60);
  return `${m}:${String(r).padStart(2, "0")}`;
}
```

(*Folder picker note*: when the user picks a directory, the current implementation calls `inspect_video_paths` with the directory itself, which the sidecar will reject as `not_video`. The drag/drop path delivers individual files even when a folder is dropped (Tauri flattens). For v1 we lean on drag/drop for folders and document the folder button as "for v1, use drag/drop or the file picker." A follow-up adds an `enumerate_directory` sidecar RPC.)

- [ ] **Step 2: Implement `name.tsx`**

```tsx
import { useEffect, useRef } from "react";
import { listLibraries } from "../../../ipc/sidecar";
import { SetupState, SetupAction, slugify } from "../state";

export function Name({ state, dispatch, onBack, onNext }: {
  state: SetupState;
  dispatch: React.Dispatch<SetupAction>;
  onBack: () => void;
  onNext: () => void;
}) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => { ref.current?.focus(); }, []);

  useEffect(() => {
    const slug = slugify(state.name);
    if (!slug) { dispatch({ type: "set_collision", value: null }); return; }
    let cancelled = false;
    listLibraries().then((libs) => {
      if (cancelled) return;
      const hit = libs.find((l) => l.name === slug);
      dispatch({ type: "set_collision", value: hit ? slug : null });
    }).catch(() => {});
    return () => { cancelled = true; };
  }, [state.name, dispatch]);

  const slug = slugify(state.name);
  const blocked = !slug || state.collisionWith === slug;

  return (
    <section className="np-step">
      <h2>Name</h2>
      <input ref={ref} value={state.name} onChange={(e) => dispatch({ type: "set_name", value: e.target.value })} placeholder="My Bike Series" />
      {slug && <p className="np-slug">→ <code>{slug}</code></p>}
      {state.collisionWith && state.collisionWith === slug && (
        <p className="np-error">A library named <code>{slug}</code> already exists. Choose a different name.</p>
      )}
      <footer className="np-footer">
        <button onClick={onBack}>Back</button>
        <button disabled={blocked} onClick={onNext}>Continue</button>
      </footer>
    </section>
  );
}
```

- [ ] **Step 3: Implement `language.tsx`**

```tsx
import { useState } from "react";
import { SetupState, SetupAction } from "../state";

const PRESETS = [
  { name: "English", code: "en" },
  { name: "Spanish", code: "es" },
];

export function Language({ state, dispatch, onBack, onNext }: {
  state: SetupState;
  dispatch: React.Dispatch<SetupAction>;
  onBack: () => void;
  onNext: () => void;
}) {
  const [other, setOther] = useState(state.language.code);
  const isPreset = PRESETS.some((p) => p.code === state.language.code);

  return (
    <section className="np-step">
      <h2>Language</h2>
      <div className="np-cards">
        {PRESETS.map((p) => (
          <button
            key={p.code}
            className={"np-card" + (state.language.code === p.code ? " np-card--active" : "")}
            onClick={() => dispatch({ type: "set_language", name: p.name, code: p.code })}
          >
            {p.name}
          </button>
        ))}
        <button
          className={"np-card" + (!isPreset ? " np-card--active" : "")}
          onClick={() => dispatch({ type: "set_language", name: "Other", code: other })}
        >
          Other…
        </button>
      </div>
      {!isPreset && (
        <label className="np-other">
          ISO 639-1 code
          <input value={other} onChange={(e) => { setOther(e.target.value); dispatch({ type: "set_language", name: "Other", code: e.target.value }); }} />
        </label>
      )}
      <footer className="np-footer">
        <button onClick={onBack}>Back</button>
        <button disabled={!state.language.code} onClick={onNext}>Continue</button>
      </footer>
    </section>
  );
}
```

- [ ] **Step 4: Implement `refinement.tsx`**

```tsx
import { SetupState, SetupAction } from "../state";

export function Refinement({ state, dispatch, onBack, onNext }: {
  state: SetupState;
  dispatch: React.Dispatch<SetupAction>;
  onBack: () => void;
  onNext: () => void;
}) {
  return (
    <section className="np-step">
      <h2>Can I proofread the transcripts after they're generated?</h2>
      <p>I'll use the video's context to fix mistakes.</p>
      <div className="np-cards">
        <button className={"np-card" + (state.refinement ? " np-card--active" : "")}
                onClick={() => dispatch({ type: "set_refinement", value: true })}>
          <strong>Yes — Recommended</strong>
          <span>Use Claude to refine video understanding.</span>
        </button>
        <button className={"np-card" + (!state.refinement ? " np-card--active" : "")}
                onClick={() => dispatch({ type: "set_refinement", value: false })}>
          <strong>No</strong>
        </button>
      </div>
      <footer className="np-footer">
        <button onClick={onBack}>Back</button>
        <button onClick={onNext}>Continue</button>
      </footer>
    </section>
  );
}
```

- [ ] **Step 5: Implement `confirm.tsx`**

```tsx
import { SetupState, slugify } from "../state";

export function Confirm({ state, apiKeyConfigured, onBack, onStart, onSetupKey }: {
  state: SetupState;
  apiKeyConfigured: boolean;
  onBack: () => void;
  onStart: () => void;
  onSetupKey: () => void;
}) {
  const totalDuration = state.accepted.reduce((s, v) => s + v.duration_seconds, 0);
  const minutes = Math.round(totalDuration / 60);

  return (
    <section className="np-step">
      <h2>Confirm</h2>
      <ul className="np-summary">
        <li><strong>Project:</strong> <code>{slugify(state.name)}</code></li>
        <li><strong>Videos:</strong> {state.accepted.length} ({minutes}m total)</li>
        <li><strong>Language:</strong> {state.language.name} ({state.language.code})</li>
        <li><strong>Refinement:</strong> {state.refinement ? "Yes" : "No"}</li>
      </ul>

      {!apiKeyConfigured && (
        <div className="np-banner">
          <p>ButterCut needs your Anthropic API key to analyze footage.</p>
          <button onClick={onSetupKey}>Set up</button>
        </div>
      )}

      <footer className="np-footer">
        <button onClick={onBack}>Back</button>
        <button onClick={onStart} disabled={!apiKeyConfigured}>Start analysis</button>
      </footer>
    </section>
  );
}
```

- [ ] **Step 6: Commit**

```bash
git add ui/src/routes/new-project/steps/
git commit -m "M2: New Project five-step wizard components"
```

---

### Task 6.6: API key modal

**Files:**
- Create: `ui/src/routes/new-project/api-key-modal.tsx`

- [ ] **Step 1: Implement**

```tsx
import { useState } from "react";
import { setApiKey } from "../../ipc/sidecar";

export function ApiKeyModal({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [key, setKey] = useState("");
  const [status, setStatus] = useState<"idle" | "validating" | "error">("idle");
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setStatus("validating"); setError(null);
    try {
      await setApiKey(key);
      onSaved();
    } catch (e) {
      setStatus("error");
      setError(String(e));
    }
  }

  return (
    <div className="np-modal-backdrop">
      <div className="np-modal">
        <h3>Connect your Anthropic API key</h3>
        <p>ButterCut uses Claude to analyze footage. <a href="https://console.anthropic.com" target="_blank" rel="noreferrer">Get a key →</a></p>
        <input type="password" value={key} onChange={(e) => setKey(e.target.value)} placeholder="sk-ant-…" autoFocus />
        {error && <p className="np-error">{error}</p>}
        <div className="np-modal-buttons">
          <button onClick={onClose} disabled={status === "validating"}>Cancel</button>
          <button onClick={save} disabled={!key || status === "validating"}>
            {status === "validating" ? "Validating…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/routes/new-project/api-key-modal.tsx
git commit -m "M2: API key modal — validates via set_api_key"
```

---

### Task 6.7: Job reducer (progress state)

**Files:**
- Create: `ui/src/routes/new-project/jobReducer.ts`

- [ ] **Step 1: Implement**

```ts
import { JobEvent, StageName } from "../../ipc/events";

export type StageState = "idle" | "queued" | "in_progress" | "done" | "failed";

export interface ClipState {
  video: string;
  stages: Record<StageName, StageState>;
  failure?: { stage: StageName; message: string; error_kind: string };
  artifacts: Partial<Record<StageName, string>>;
}

export interface JobState {
  job_id: string | null;
  videos: Record<string, ClipState>;
  totals: { done: number; failed: number; total: number };
  status: "running" | "canceling" | "canceled" | "complete";
}

export const initialJobState: JobState = {
  job_id: null,
  videos: {},
  totals: { done: 0, failed: 0, total: 0 },
  status: "running",
};

export function jobReducer(state: JobState, evt: JobEvent | { method: "_internal_canceling" }): JobState {
  switch (evt.method) {
    case "job_started":
      return { ...state, job_id: evt.params.job_id, totals: { ...state.totals, total: evt.params.video_count } };
    case "file_started":
      return updateClip(state, evt.params.video, (c) => ({ ...c, stages: { ...c.stages, [evt.params.stage]: "in_progress" } }));
    case "file_done":
      return updateClip(state, evt.params.video, (c) => ({ ...c, stages: { ...c.stages, [evt.params.stage]: "done" } }));
    case "artifact_ready":
      return updateClip(state, evt.params.video, (c) => ({ ...c, artifacts: { ...c.artifacts, [evt.params.stage]: evt.params.artifact_path } }));
    case "file_failed":
      return updateClip(state, evt.params.video, (c) => ({
        ...c,
        stages: { ...c.stages, [evt.params.stage]: "failed" },
        failure: { stage: evt.params.stage, message: evt.params.message, error_kind: evt.params.error_kind },
      }));
    case "job_done":
      return { ...state, status: "complete", totals: { ...state.totals, done: evt.params.succeeded_count, failed: evt.params.failed_count } };
    case "job_canceled":
      return { ...state, status: "canceled", totals: { ...state.totals, done: evt.params.succeeded_count, failed: evt.params.failed_count } };
    case "_internal_canceling":
      return { ...state, status: "canceling" };
    case "file_progress":
      return state;
  }
}

function updateClip(state: JobState, video: string, fn: (c: ClipState) => ClipState): JobState {
  const existing = state.videos[video] ?? { video, stages: { transcribe: "idle", analyze: "idle", summarize: "idle" }, artifacts: {} };
  return { ...state, videos: { ...state.videos, [video]: fn(existing) } };
}
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/routes/new-project/jobReducer.ts
git commit -m "M2: jobReducer accumulates per-clip per-stage state from events"
```

---

### Task 6.8: Progress view + clip row + artifact preview

**Files:**
- Create: `ui/src/routes/new-project/progress/progress-view.tsx`
- Create: `ui/src/routes/new-project/progress/clip-row.tsx`
- Create: `ui/src/routes/new-project/progress/artifact-preview.tsx`

- [ ] **Step 1: Implement `clip-row.tsx`**

```tsx
import { ClipState } from "../jobReducer";
import { StageName } from "../../../ipc/events";
import { ArtifactPreview } from "./artifact-preview";

const GLYPH: Record<string, string> = { idle: "○", queued: "⏳", in_progress: "◐", done: "✓", failed: "✗" };

export function ClipRow({ clip, library, onRetry, expanded, onToggle }: {
  clip: ClipState;
  library: string;
  onRetry: (stage: StageName) => void;
  expanded: boolean;
  onToggle: () => void;
}) {
  const stages: StageName[] = ["transcribe", "analyze", "summarize"];

  return (
    <div className={"np-row " + (clip.failure ? "np-row--failed " : "") + (expanded ? "np-row--expanded" : "")}>
      <button className="np-row__head" onClick={onToggle}>
        <span className="np-row__name">{clip.video}</span>
        {stages.map((s) => (
          <span key={s} className={`np-chip np-chip--${clip.stages[s]}`}>{GLYPH[clip.stages[s]]} {s}</span>
        ))}
      </button>

      {expanded && (
        <div className="np-row__body">
          {clip.failure ? (
            <div className="np-failure">
              <strong>✗ {clip.failure.stage} stage failed</strong>
              <pre>{clip.failure.message}</pre>
              <div className="np-failure-buttons">
                <button onClick={() => onRetry(clip.failure!.stage)}>Retry {clip.failure.stage}</button>
              </div>
            </div>
          ) : (
            <ArtifactPreview clip={clip} library={library} />
          )}
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Implement `artifact-preview.tsx`**

```tsx
import { useEffect, useState } from "react";
import { getClipTranscripts } from "../../../ipc/sidecar";
import { ClipState } from "../jobReducer";

export function ArtifactPreview({ clip, library }: { clip: ClipState; library: string }) {
  const [data, setData] = useState<{ audio: string | null; visual: string | null; summary: string | null }>({ audio: null, visual: null, summary: null });

  useEffect(() => {
    getClipTranscripts(library, clip.video).then((t) => {
      setData({
        audio: previewAudio(t.audio),
        visual: previewVisual(t.visual),
        summary: t.summary ?? null,
      });
    }).catch(() => {});
  }, [clip.artifacts.transcribe, clip.artifacts.analyze, clip.artifacts.summarize, library, clip.video]);

  return (
    <div className="np-preview">
      {data.summary && <section><h4>Summary</h4><pre className="np-md">{data.summary}</pre></section>}
      {data.visual && <section><h4>Visual transcript</h4><pre>{data.visual}</pre></section>}
      {data.audio && <section><h4>Transcript</h4><pre>{data.audio}</pre></section>}
    </div>
  );
}

function previewAudio(t: any | null): string | null {
  if (!t || !t.segments) return null;
  return t.segments.slice(0, 6).map((s: any) => s.text).join(" ").trim() || null;
}
function previewVisual(t: any | null): string | null {
  if (!t || !t.segments) return null;
  return t.segments.slice(0, 6).map((s: any) => s.visual || s.text).filter(Boolean).join("\n");
}
```

- [ ] **Step 3: Implement `progress-view.tsx`**

```tsx
import { useEffect, useReducer, useState } from "react";
import { JobState, jobReducer, initialJobState } from "../jobReducer";
import { ClipRow } from "./clip-row";
import { listenJobEvents, JobEvent } from "../../../ipc/events";
import { cancelJob, openLibraryWindow } from "../../../ipc/sidecar";

export function ProgressView({ jobId, library, onComplete }: {
  jobId: string;
  library: string;
  onComplete: () => void;
}) {
  const [state, dispatch] = useReducer(jobReducer, initialJobState);
  const [expanded, setExpanded] = useState<string | null>(null);

  useEffect(() => {
    let unlisten: (() => void) | null = null;
    listenJobEvents(jobId, (evt: JobEvent) => dispatch(evt)).then((fn) => { unlisten = fn; });
    return () => { unlisten?.(); };
  }, [jobId]);

  const allClipsDone = Object.values(state.videos).every(
    (c) => c.stages.transcribe === "done" && c.stages.analyze === "done" && c.stages.summarize === "done"
  );

  function onCancel() {
    if (!confirm("Cancel analysis? Files already analyzed will be kept.")) return;
    dispatch({ method: "_internal_canceling" } as any);
    cancelJob(jobId).catch(console.error);
  }

  return (
    <section className="np-progress">
      <header className="np-progress__header">
        <h2>Analyzing {library}</h2>
        {state.status === "running" && <button onClick={onCancel}>Cancel</button>}
        {state.status === "canceling" && <span>Canceling…</span>}
      </header>

      <div className="np-progress__bar">
        <div style={{ width: `${(state.totals.done / Math.max(1, state.totals.total)) * 100}%` }} />
      </div>
      <p className="np-progress__count">
        {state.totals.done} of {state.totals.total} clips ready
        {state.totals.failed > 0 && <span className="np-progress__failed"> · {state.totals.failed} failed</span>}
      </p>

      <ul className="np-progress__list">
        {Object.values(state.videos).map((c) => (
          <li key={c.video}>
            <ClipRow
              clip={c}
              library={library}
              expanded={expanded === c.video}
              onToggle={() => setExpanded(expanded === c.video ? null : c.video)}
              onRetry={() => { /* M2 deferred — close window and re-run start_analysis */ onComplete(); }}
            />
          </li>
        ))}
      </ul>

      {(state.status === "complete" || state.status === "canceled" || allClipsDone) && (
        <footer className="np-progress__footer">
          <button onClick={() => openLibraryWindow(library).then(onComplete)}>Open Library</button>
        </footer>
      )}
    </section>
  );
}
```

- [ ] **Step 4: Commit**

```bash
git add ui/src/routes/new-project/progress/
git commit -m "M2: progress view, clip row, artifact preview"
```

---

### Task 6.9: New Project window root

**Files:**
- Create: `ui/src/routes/new-project/index.tsx`
- Create: `ui/src/routes/new-project/new-project.css`

- [ ] **Step 1: Implement `index.tsx`**

```tsx
import { useEffect, useReducer, useState } from "react";
import { initialSetup, setupReducer, slugify, StepId } from "./state";
import { PickFootage } from "./steps/pick-footage";
import { Name } from "./steps/name";
import { Language } from "./steps/language";
import { Refinement } from "./steps/refinement";
import { Confirm } from "./steps/confirm";
import { ApiKeyModal } from "./api-key-modal";
import { ProgressView } from "./progress/progress-view";
import { createLibrary, hasApiKey, startAnalysis } from "../../ipc/sidecar";
import "./new-project.css";

const STEPS: StepId[] = ["footage", "name", "language", "refinement", "confirm"];

export default function NewProject() {
  const [state, dispatch] = useReducer(setupReducer, initialSetup);
  const [phase, setPhase] = useState<"setup" | "progress">("setup");
  const [job, setJob] = useState<{ id: string; library: string } | null>(null);
  const [keyConfigured, setKeyConfigured] = useState(false);
  const [showKeyModal, setShowKeyModal] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    hasApiKey().then((r) => setKeyConfigured(r.configured)).catch(() => setKeyConfigured(false));
  }, []);

  const idx = STEPS.indexOf(state.step);
  const goNext = () => dispatch({ type: "go_step", step: STEPS[Math.min(STEPS.length - 1, idx + 1)] });
  const goBack = () => dispatch({ type: "go_step", step: STEPS[Math.max(0, idx - 1)] });

  async function start() {
    setError(null);
    try {
      const { name } = await createLibrary({
        name: state.name,
        language: state.language.name,
        language_code: state.language.code,
        refinement: state.refinement,
        videos: state.accepted,
      });
      const { job_id } = await startAnalysis(name);
      setJob({ id: job_id, library: name });
      setPhase("progress");
    } catch (e) {
      setError(String(e));
    }
  }

  if (phase === "progress" && job) {
    return <ProgressView jobId={job.id} library={job.library} onComplete={() => window.close()} />;
  }

  return (
    <main className="np">
      <nav className="np-breadcrumb">
        {STEPS.map((s, i) => (
          <span key={s} className={"np-breadcrumb__item" + (i === idx ? " np-breadcrumb__item--active" : "")}>
            {i + 1}. {s}
          </span>
        ))}
      </nav>

      {state.step === "footage" && <PickFootage state={state} dispatch={dispatch} onNext={goNext} />}
      {state.step === "name" && <Name state={state} dispatch={dispatch} onBack={goBack} onNext={goNext} />}
      {state.step === "language" && <Language state={state} dispatch={dispatch} onBack={goBack} onNext={goNext} />}
      {state.step === "refinement" && <Refinement state={state} dispatch={dispatch} onBack={goBack} onNext={goNext} />}
      {state.step === "confirm" && (
        <Confirm
          state={state}
          apiKeyConfigured={keyConfigured}
          onBack={goBack}
          onStart={start}
          onSetupKey={() => setShowKeyModal(true)}
        />
      )}

      {error && <p className="np-error">{error}</p>}

      {showKeyModal && (
        <ApiKeyModal
          onClose={() => setShowKeyModal(false)}
          onSaved={() => { setShowKeyModal(false); setKeyConfigured(true); }}
        />
      )}
    </main>
  );
}
```

- [ ] **Step 2: Implement `new-project.css`** — minimal styling matching the M0/M1 dark stage + tungsten amber palette:

```css
:root {
  --np-bg: #14141a;
  --np-fg: #e7e5e0;
  --np-muted: #8b8a86;
  --np-amber: #e0a55a;
  --np-red: #c87272;
  --np-line: #2a2a32;
}
.np { padding: 32px; color: var(--np-fg); background: var(--np-bg); min-height: 100vh; font-family: 'JetBrains Mono', ui-monospace, monospace; }
.np-breadcrumb { display: flex; gap: 16px; margin-bottom: 32px; color: var(--np-muted); }
.np-breadcrumb__item--active { color: var(--np-amber); }
.np-step h2 { font-family: 'EB Garamond', serif; font-style: italic; font-weight: 400; font-size: 32px; }
.np-dropzone { border: 2px dashed var(--np-amber); padding: 64px; text-align: center; border-radius: 6px; }
.np-dropzone__buttons { margin-top: 16px; display: flex; gap: 12px; justify-content: center; }
.np-filelist { list-style: none; padding: 0; margin: 16px 0; }
.np-filelist li { display: flex; gap: 12px; padding: 8px 0; border-bottom: 1px solid var(--np-line); }
.np-filelist__remove { margin-left: auto; background: transparent; color: var(--np-muted); border: none; cursor: pointer; }
.np-rejected { margin: 8px 0; color: var(--np-amber); }
.np-footer { display: flex; gap: 12px; margin-top: 24px; }
.np-footer button { padding: 8px 20px; }
.np-cards { display: flex; gap: 12px; margin: 16px 0; }
.np-card { padding: 16px 20px; border: 1px solid var(--np-line); background: transparent; color: var(--np-fg); cursor: pointer; border-radius: 4px; }
.np-card--active { border-color: var(--np-amber); }
.np-other { display: block; margin-top: 12px; }
.np-summary li { padding: 4px 0; }
.np-banner { background: rgba(224, 165, 90, 0.08); padding: 12px 16px; border-left: 2px solid var(--np-amber); margin: 16px 0; }
.np-error { color: var(--np-red); }
.np-slug { color: var(--np-muted); }
.np-modal-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.6); display: grid; place-items: center; }
.np-modal { background: var(--np-bg); border: 1px solid var(--np-line); padding: 24px; border-radius: 6px; width: 480px; }
.np-modal-buttons { display: flex; gap: 8px; justify-content: flex-end; margin-top: 16px; }
.np-progress { padding: 32px; color: var(--np-fg); background: var(--np-bg); min-height: 100vh; }
.np-progress__header { display: flex; justify-content: space-between; align-items: center; }
.np-progress__bar { height: 4px; background: var(--np-line); margin: 16px 0 4px 0; }
.np-progress__bar > div { height: 4px; background: var(--np-amber); transition: width 0.4s ease; }
.np-progress__count { color: var(--np-muted); }
.np-progress__failed { color: var(--np-red); }
.np-progress__list { list-style: none; padding: 0; }
.np-row { border: 1px solid var(--np-line); border-radius: 4px; margin: 8px 0; overflow: hidden; }
.np-row__head { display: flex; gap: 16px; align-items: center; width: 100%; padding: 12px 16px; background: transparent; color: var(--np-fg); border: none; cursor: pointer; }
.np-row__name { flex: 1; text-align: left; }
.np-chip { color: var(--np-muted); }
.np-chip--in_progress { color: var(--np-amber); animation: pulse 1.6s ease-in-out infinite; }
.np-chip--done { color: var(--np-amber); }
.np-chip--failed { color: var(--np-red); }
@keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: 0.4 } }
.np-row__body { padding: 12px 16px; border-top: 1px solid var(--np-line); background: rgba(255,255,255,0.02); }
.np-failure pre { color: var(--np-red); white-space: pre-wrap; }
.np-preview pre { white-space: pre-wrap; color: var(--np-muted); }
.np-md { font-family: inherit; }
```

- [ ] **Step 3: Build**

Run: `cd ui && pnpm build`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add ui/src/routes/new-project/index.tsx ui/src/routes/new-project/new-project.css
git commit -m "M2: New Project window root + setup/progress phase switch"
```

---

### Task 6.10: + New Project tile on the Projects screen

**Files:**
- Modify: `ui/src/routes/projects.tsx`
- Modify: `ui/src/routes/projects.css`

- [ ] **Step 1: Edit `projects.tsx`**

Add the import and render the tile inside the grid:

```tsx
import { listLibraries, openLibraryWindow, openNewProjectWindow, LibrarySummary } from "../ipc/sidecar";
```

Inside the `state.kind === "ready"` branch's grid, before the `state.libraries.map(...)`:

```tsx
<li>
  <button className="card card--new" onClick={() => openNewProjectWindow().catch(console.error)}>
    <span className="card__plus">+</span>
    <span className="card__name">New Project</span>
  </button>
</li>
```

Also: the empty-state hint that says "Create one with the CLI for now." — replace its text with "No libraries yet. Click **+ New Project** to start."

- [ ] **Step 2: Edit `projects.css`**

Append:
```css
.card--new { border-style: dashed; border-color: var(--np-amber, #e0a55a); }
.card__plus { font-size: 32px; color: var(--np-amber, #e0a55a); }
```

- [ ] **Step 3: Smoke build**

Run: `cd ui && pnpm build`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add ui/src/routes/projects.tsx ui/src/routes/projects.css
git commit -m "M2: + New Project tile on the Projects screen"
```

---

## Phase 7 — End-to-end smoke

### Task 7.1: Manual happy-path run

This task is *not* automated; it gates merge.

- [ ] **Step 1: Set ANTHROPIC_API_KEY**

```bash
export ANTHROPIC_API_KEY=sk-ant-…
```

- [ ] **Step 2: Run dev**

```bash
cd ui && pnpm tauri dev
```

- [ ] **Step 3: Click "+ New Project"**

A new window opens.

- [ ] **Step 4: Drop ~3 short MP4s onto Step ①**

Verify thumbnails... wait, no thumbnails in the wizard — just file list with durations. Verify durations populate.

- [ ] **Step 5: Walk steps ②–⑤**

Type a name, watch the slug populate; pick English; pick Yes for refinement; click Start analysis.

- [ ] **Step 6: Watch the progress view**

- Bar advances as artifacts land.
- Click a row in progress; the artifact preview should populate after each stage's `artifact_ready`.
- After completion, click **Open Library**; the M1 footage browser should open with all clips analyzed.

- [ ] **Step 7: Verify CLI round-trip**

Run from a terminal:
```bash
ls libraries/<your-name>/library.yaml libraries/<your-name>/transcripts/ libraries/<your-name>/summaries/
```
The schema and filenames should match what the CLI workflow produces.

- [ ] **Step 8: Cancellation smoke**

Repeat with a longer clip; click Cancel mid-transcribe. Verify:
- Whisperx/ffmpeg processes die within ~2s (`ps aux | grep whisperx`).
- No `*.tmp` files remain in `transcripts/` or `summaries/`.
- Click "Resume analysis" or close + reopen and start_analysis again — picks up from where it left off.

- [ ] **Step 9: Bad API key smoke**

Start a fresh project with no key set. Confirm pane shows the banner. Click Set up; type `sk-bad`. Modal shows the upstream error and stays open.

- [ ] **Step 10: No commit; this is verification only.**

If anything fails, open targeted issues; do not paper over with sleeps or `--no-verify`.

---

### Task 7.2: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add entry**

Under the `[Unreleased]` heading, prepend:

```markdown
### Added
- M2: New Project flow + streaming analysis progress UI in the desktop app. Drop a folder of videos, name a project, pick a language, and watch the three-stage pipeline (transcribe → analyze → summarize) run with per-file per-stage progress streamed over JSON-RPC notifications. Removes the last terminal dependency from onboarding.
- Sidecar gains: `inspect_video_paths`, `create_library`, `has_api_key`, `set_api_key`, `start_analysis`, `cancel_job`. Validates Anthropic keys with a Haiku ping; persists to `libraries/settings.yaml` (gitignored). Extracts analyze + summarize prompt content into shared `ui/sidecar/prompts/` files referenced by both the CLI agent and the new sidecar parent.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "M2: changelog entry"
```

---

### Task 7.3: Open the PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin ui-m2-library-creation-and-analysis
```

- [ ] **Step 2: Create PR against `main`**

```bash
gh pr create --title "M2: Library creation + analysis from the UI" --body "$(cat <<'EOF'
## Summary
- Adds the New Project flow: drag-drop or pick → name → language → refinement → start analysis.
- Promotes the sidecar from a YAML reader to the analysis pipeline owner. Whisperx + ffmpeg as subprocesses; Anthropic SDK for analyze + summarize. JSON-RPC notifications stream per-file per-stage progress to the UI as scoped Tauri events.
- Extracts analyze + summarize prompt content into `ui/sidecar/prompts/` so the CLI agent and the sidecar share a single source of truth.
- API key handling: env override + `libraries/settings.yaml`. Validated on save with a Haiku ping.

Closes the M2 milestone of #14.

## Test plan
- [ ] Manual happy path against ~3 short clips end-to-end (per `docs/superpowers/plans/2026-05-03-m2-library-creation-and-analysis.md` Task 7.1).
- [ ] Cancel mid-transcribe; no orphan `*.tmp` files; resume picks up.
- [ ] Bad API key surfaces the upstream error in the modal.
- [ ] Library created via UI is consumable by the CLI `roughcut` skill.
- [ ] `bundle exec rake spec` passes (sidecar).
- [ ] `cargo check` clean (Rust shell).
- [ ] `pnpm build` clean (frontend).
- [ ] M0 Projects screen and M1 Library window unchanged.
EOF
)"
```

- [ ] **Step 3: Expect CodeRabbit + Codex reviews; run `/babysit-coderabbit <PR#>` after they post.**

---

## Self-review checklist (run after writing this plan)

- **Spec coverage:**
  - ✅ JSON-RPC notifications IPC: Tasks 1.2, 5.1, 6.2.
  - ✅ Sidecar pipeline (Option 1 from spec Q2): Tasks 4.3–4.6.
  - ✅ API key UX (Q3): Tasks 1.3, 1.4, 2.3, 6.6.
  - ✅ Hard-stop cancellation (Q4): Tasks 4.2, 4.6, 4.7, 6.8.
  - ✅ Concurrency caps (Q5): Tasks 1.1, 4.6.
  - ✅ Five-step wizard: Tasks 6.4, 6.5.
  - ✅ Progress view with streaming artifact previews: Task 6.8.
  - ✅ + New Project tile: Task 6.10.
  - ✅ Open Library handoff: Task 6.8 (`onComplete` → `openLibraryWindow`).
  - ✅ Prompt extraction: Phase 3.
  - ✅ Acceptance criteria mapping: covered by Task 7.1's manual walkthrough.

- **Placeholder scan:** No "TBD"/"TODO" left. The folder-picker limitation is explicitly called out in Task 6.5 with a follow-up note ("a follow-up adds an `enumerate_directory` sidecar RPC") — that's a deliberate scope decision, not a placeholder.

- **Type consistency:** RPC method names match between Ruby dispatcher (Task 2.3, 4.7), Rust commands (Task 5.2), and TS wrappers (Task 6.1). Event method names match between Ruby `Notifier.notify` calls (Task 4.6), TS `JobEvent` union (Task 6.2), and reducer cases (Task 6.7).

- **`retry_unit` scope:** Plan defers the retry-unit RPC implementation to a follow-up; the UI's "Retry stage" button currently closes and re-runs `start_analysis`. Spec acceptance criterion "Retry / Skip / Show full log all work" is partially met — Retry triggers a re-run rather than a precise per-stage replay. Flag for the PR description.
