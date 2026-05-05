# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "timeout"

module ButtercutUiSidecar
  class ResolveHandoff
    OPEN_RESOLVE_TIMEOUT_SEC = 15
    PRECHECK_TIMEOUT_SEC = 45
    APPLY_SCRIPT_TIMEOUT_SEC = 300
    PRECHECK = <<~PY.freeze
      import json
      import sys

      expected_timeline = sys.argv[1] if len(sys.argv) > 1 else ""
      try:
          import DaVinciResolveScript as dvr_script  # type: ignore
      except Exception:
          print(json.dumps({"ok": False, "error": "resolve_scripting_disabled"}))
          sys.exit(0)

      resolve = dvr_script.scriptapp("Resolve")
      if not resolve:
          print(json.dumps({"ok": False, "error": "resolve_scripting_disabled"}))
          sys.exit(0)

      project_manager = resolve.GetProjectManager()
      project = project_manager.GetCurrentProject() if project_manager else None
      if not project:
          print(json.dumps({"ok": False, "error": "resolve_no_active_project"}))
          sys.exit(0)

      timeline = project.GetCurrentTimeline()
      if not timeline:
          print(json.dumps({"ok": False, "error": "resolve_no_active_timeline"}))
          sys.exit(0)

      active_timeline = timeline.GetName() or ""
      if expected_timeline and expected_timeline != active_timeline:
          print(json.dumps({
              "ok": False,
              "error": "resolve_timeline_target_mismatch",
              "expected_timeline": expected_timeline,
              "active_timeline": active_timeline,
          }))
          sys.exit(0)

      print(json.dumps({
          "ok": True,
          "project_name": project.GetName() or "",
          "active_timeline": active_timeline,
      }))
    PY

    def run(apply_path:, recipe_path:)
      apply = Pathname.new(apply_path.to_s).expand_path
      recipe = Pathname.new(recipe_path.to_s).expand_path
      raise "missing_artifacts: apply script not found at #{apply}" unless apply.file?
      raise "missing_artifacts: recipe not found at #{recipe}" unless recipe.file?

      ensure_resolve_running!
      activate_resolve!

      recipe_obj = JSON.parse(recipe.read)
      expected_timeline = recipe_obj["timeline"].to_s.strip
      if expected_timeline.empty?
        raise "missing_recipe_timeline: Recipe JSON has no timeline name. Re-export the rough cut to regenerate the recipe."
      end
      precheck = precheck_resolve(expected_timeline: expected_timeline)
      raise precheck_error(precheck) unless precheck["ok"]

      out, status = with_handoff_timeout(APPLY_SCRIPT_TIMEOUT_SEC, "Apply script") do
        Open3.capture2e("python3", apply.to_s)
      end
      raise normalize_apply_failure(out) unless status.success?

      {
        ok: true,
        output: out,
        project_name: precheck["project_name"].to_s,
        timeline_name: precheck["active_timeline"].to_s
      }
    end

    private

    def ensure_resolve_running!
      _out, status = Open3.capture2("pgrep", "-x", "Resolve")
      return if status.success?

      raise "resolve_not_running: Open DaVinci Resolve, open your project and timeline, then try Send to Resolve again."
    end

    def activate_resolve!
      out, status = with_handoff_timeout(OPEN_RESOLVE_TIMEOUT_SEC, "Open Resolve") do
        Open3.capture2e("open", "-a", "DaVinci Resolve")
      end
      return if status.success?

      detail = out.to_s.strip
      suffix = detail.empty? ? "" : " (#{detail})"
      raise "resolve_launch_failed: Could not open DaVinci Resolve from the desktop. Open Resolve manually, then try Send to Resolve again.#{suffix}"
    end

    def precheck_resolve(expected_timeline:)
      out, status = with_handoff_timeout(PRECHECK_TIMEOUT_SEC, "Resolve precheck") do
        Open3.capture2e("python3", "-c", PRECHECK, expected_timeline.to_s)
      end
      raise "resolve_precheck_failed: #{out.strip}" unless status.success?

      JSON.parse(out)
    rescue JSON::ParserError
      raise "resolve_precheck_failed: #{out.to_s.strip}"
    end

    def with_handoff_timeout(seconds, label)
      Timeout.timeout(seconds) { yield }
    rescue Timeout::Error
      raise "resolve_handoff_timeout: #{label} exceeded #{seconds}s — try again or restart Resolve if it is not responding."
    end

    def precheck_error(precheck)
      case precheck["error"].to_s
      when "resolve_scripting_disabled"
        "resolve_scripting_disabled: Enable Resolve scripting (Preferences > System > General > External scripting using Local) and restart Resolve."
      when "resolve_no_active_project"
        "resolve_no_active_project: Open the Resolve project that contains your imported rough cut timeline."
      when "resolve_no_active_timeline"
        "resolve_no_active_timeline: Import/open the rough cut timeline in Resolve before sending."
      when "resolve_timeline_target_mismatch"
        expected = precheck["expected_timeline"].to_s
        active = precheck["active_timeline"].to_s
        "resolve_timeline_target_mismatch: Recipe targets '#{expected}' but Resolve has '#{active}' active. Switch to '#{expected}' and retry."
      else
        "resolve_precheck_failed: #{precheck["error"]}"
      end
    end

    def normalize_apply_failure(output)
      text = output.to_s
      if text.include?("recipe not found")
        return "missing_recipe: The apply script could not find the recipe JSON on disk. Re-export the rough cut in ButterCut so the .recipe.json next to your XML is regenerated, then import the XML in Resolve and try again."
      end
      if text.include?("recipe version") && text.include?("unsupported")
        return "resolve_apply_failed: This recipe version is not supported by the apply script. Re-export the rough cut to regenerate the recipe and _apply.py."
      end
      if text.include?("could not connect to Resolve")
        return "resolve_scripting_disabled: Resolve scripting bridge not available. Enable Local scripting and restart Resolve."
      end
      if text.include?("no project open")
        return "resolve_no_active_project: No project is open in Resolve."
      end
      if text.include?("no timeline open")
        return "resolve_no_active_timeline: No timeline is active in Resolve. Import/open the rough cut timeline first."
      end

      "resolve_apply_failed: #{text.strip}"
    end
  end
end
