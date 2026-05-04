# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/brief_store"

RSpec.describe ButtercutUiSidecar::BriefStore do
  it "refuses upsert when the library directory does not exist" do
    Dir.mktmpdir do |root|
      store = described_class.new(libraries_root: root, library: "missing-lib")
      expect { store.upsert(id: nil, prompt: "x", target_duration_seconds: 10) }.to raise_error(/library directory missing/)
    end
  end

  it "upserts, lists newest first, and forks" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "demo"))
      File.write(File.join(root, "demo", "library.yaml"), YAML.dump("library_name" => "demo"))

      store = described_class.new(libraries_root: root, library: "demo")

      id1 = store.upsert(id: nil, prompt: "First cut", target_duration_seconds: 60, title: "v1")
      expect(id1).to start_with("b-")

      id2 = store.upsert(id: id1, prompt: "First cut revised", target_duration_seconds: 90, title: "v1b")
      expect(id2).to eq(id1)

      forked = store.fork(parent_id: id1)
      expect(forked).not_to eq(id1)

      rows = store.list
      expect(rows.first["id"]).to eq(forked)
      expect(rows.first["parent_id"]).to eq(id1)
      expect(rows.first["prompt"]).to eq("First cut revised")

      parent = rows.find { |r| r["id"] == id1 }
      expect(parent["target_duration_seconds"]).to eq(90)
    end
  end

  it "sorts rows with invalid updated_at last without raising" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "demo", "briefs"))
      catalog = File.join(root, "demo", "briefs", "catalog.yaml")
      File.write(
        catalog,
        YAML.dump(
          "briefs" => [
            {
              "id" => "b-bad",
              "parent_id" => nil,
              "prompt" => "old",
              "target_duration_seconds" => 1,
              "title" => "",
              "created_at" => "2020-01-01T00:00:00.000Z",
              "updated_at" => "not-a-valid-time"
            },
            {
              "id" => "b-good",
              "parent_id" => nil,
              "prompt" => "new",
              "target_duration_seconds" => 1,
              "title" => "",
              "created_at" => "2020-01-01T00:00:00.000Z",
              "updated_at" => "2026-06-01T12:00:00.000Z"
            }
          ]
        )
      )

      store = described_class.new(libraries_root: root, library: "demo")
      rows = store.list
      expect(rows.first["id"]).to eq("b-good")
      expect(rows.last["id"]).to eq("b-bad")
    end
  end
end
