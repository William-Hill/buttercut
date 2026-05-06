require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'json'
require 'fileutils'
require 'buttercut/broll_renderer'

RSpec.describe ButterCut::BrollRenderer do
  let(:entry) { YAML.load_file('spec/fixtures/broll_renderer/manifest_entry.yaml') }
  let(:theme) { { "name" => "tutorial-dark" } }
  let(:hyperframes_dir) { File.expand_path('hyperframes', Dir.pwd) }

  describe '.render' do
    it 'requires entry, theme, output_dir, hyperframes_dir' do
      expect { described_class.render }.to raise_error(ArgumentError)
    end

    it 'rejects an entry whose template has no composition' do
      Dir.mktmpdir do |out|
        bad = entry.merge('template' => 'does-not-exist')
        expect {
          described_class.render(entry: bad, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        }.to raise_error(ArgumentError, /composition not found/i)
      end
    end

    it 'writes to <output_dir>/<id>.mp4 and returns that path' do
      Dir.mktmpdir do |out|
        renderer = described_class.new(entry: entry, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        expected = File.join(out, 'br-0001.mp4')
        captured = nil
        allow(renderer).to receive(:run_render!) { |cmd| captured = cmd; FileUtils.touch(expected) }
        result = renderer.render
        expect(result).to eq(expected)
        expect(captured).to include('hyperframes', 'render', '-o', expected)
        json_idx = captured.index('--variables')
        vars = JSON.parse(captured[json_idx + 1])
        expect(vars).to include('command' => 'git rebase -i HEAD~3', 'caption' => 'Interactive rebase, last 3 commits')
        expect(vars['duration']).to be_within(0.001).of(5.0)
      end
    end

    it 'is idempotent — re-render overwrites the same path' do
      Dir.mktmpdir do |out|
        renderer = described_class.new(entry: entry, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        expected = File.join(out, 'br-0001.mp4')
        allow(renderer).to receive(:run_render!) { FileUtils.touch(expected) }
        first = renderer.render
        File.write(expected, "stale")
        second = renderer.render
        expect(first).to eq(second)
        expect(File.read(second)).to eq("")
      end
    end

    it 'pins fps, quality, and workers for deterministic output' do
      Dir.mktmpdir do |out|
        renderer = described_class.new(entry: entry, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        captured = nil
        allow(renderer).to receive(:run_render!) { |cmd| captured = cmd; FileUtils.touch(File.join(out, 'br-0001.mp4')) }
        renderer.render
        expect(captured).to include('--fps', '30')
        expect(captured).to include('--quality', 'standard')
        expect(captured).to include('--workers', '1')
      end
    end
  end
end
