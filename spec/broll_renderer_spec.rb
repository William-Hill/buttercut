require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'json'
require 'fileutils'
require 'buttercut/broll_renderer'

RSpec.describe ButterCut::BrollRenderer do
  let(:entry) { YAML.load_file(File.expand_path('fixtures/broll_renderer/manifest_entry.yaml', __dir__)) }
  let(:theme) { { "name" => "tutorial-dark" } }
  let(:hyperframes_dir) { File.expand_path('../hyperframes', __dir__) }

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

    it 'rejects entry ids and templates with path separators' do
      Dir.mktmpdir do |out|
        bad_id = entry.merge('id' => '../escape')
        expect {
          described_class.render(entry: bad_id, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        }.to raise_error(ArgumentError, /entry id must match/)

        bad_template = entry.merge('template' => '../../other')
        expect {
          described_class.render(entry: bad_template, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        }.to raise_error(ArgumentError, /entry template must match/)
      end
    end

    it 'rejects entries with non-numeric or non-positive durations' do
      Dir.mktmpdir do |out|
        bad = entry.merge('start' => 5.0, 'end' => 5.0)
        expect {
          described_class.render(entry: bad, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        }.to raise_error(ArgumentError, /start\/end/)
      end
    end

    def stub_render_to_capture(renderer, captured_ref)
      allow(renderer).to receive(:run_render!) do |cmd|
        captured_ref[:cmd] = cmd
        FileUtils.touch(cmd[cmd.index('-o') + 1])
      end
    end

    it 'writes to <output_dir>/<id>.mp4 and returns that path' do
      Dir.mktmpdir do |out|
        renderer = described_class.new(entry: entry, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        expected = File.join(out, 'br-0001.mp4')
        captured_ref = {}
        stub_render_to_capture(renderer, captured_ref)
        result = renderer.render
        captured = captured_ref.fetch(:cmd)
        expect(result).to eq(expected)
        expect(File.exist?(expected)).to be true
        expect(captured.take(4).join(' ')).to match(/hyperframes/)
        expect(captured).to include('render')
        out_path = captured[captured.index('-o') + 1]
        expect(out_path).to match(%r{\A#{Regexp.escape(File.join(out, 'br-0001'))}\.tmp-\d+-[0-9a-f]+\.mp4\z})
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
        captured_ref = {}
        stub_render_to_capture(renderer, captured_ref)
        first = renderer.render
        File.write(expected, "stale")
        second = renderer.render
        expect(first).to eq(second)
        expect(File.read(second)).to eq("")
      end
    end

    it 'preserves the prior MP4 if render fails (render-then-swap)' do
      Dir.mktmpdir do |out|
        renderer = described_class.new(entry: entry, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        expected = File.join(out, 'br-0001.mp4')
        File.write(expected, "good")
        allow(renderer).to receive(:run_render!).and_raise("simulated render failure")
        expect { renderer.render }.to raise_error(/simulated render failure/)
        expect(File.read(expected)).to eq("good")
      end
    end

    it 'pins fps, quality, and workers for deterministic output' do
      Dir.mktmpdir do |out|
        renderer = described_class.new(entry: entry, theme: theme, output_dir: out, hyperframes_dir: hyperframes_dir)
        captured_ref = {}
        stub_render_to_capture(renderer, captured_ref)
        renderer.render
        captured = captured_ref.fetch(:cmd)
        expect(captured).to include('--fps', '30')
        expect(captured).to include('--quality', 'standard')
        expect(captured).to include('--workers', '1')
      end
    end
  end

  describe 'determinism (integration)', :integration do
    # MP4 muxer embeds non-deterministic timestamps, so byte-identical SHA fails;
    # we assert structural ffprobe equality (codec/dims/frames/duration) instead.
    it 'produces structurally-identical MP4s across two runs with the same inputs', :slow do
      skip 'set RUN_HYPERFRAMES_INTEGRATION=1 to run' unless ENV['RUN_HYPERFRAMES_INTEGRATION'] == '1'
      probe = lambda do |path|
        JSON.parse(`ffprobe -v error -print_format json -show_streams -show_format "#{path}"`)
      end
      Dir.mktmpdir do |out_a|
        Dir.mktmpdir do |out_b|
          described_class.render(entry: entry, theme: theme, output_dir: out_a, hyperframes_dir: hyperframes_dir)
          described_class.render(entry: entry, theme: theme, output_dir: out_b, hyperframes_dir: hyperframes_dir)
          a = probe.call(File.join(out_a, 'br-0001.mp4'))
          b = probe.call(File.join(out_b, 'br-0001.mp4'))
          keys = %w[codec_name width height nb_frames duration]
          expect(a['streams'][0].slice(*keys)).to eq(b['streams'][0].slice(*keys))
        end
      end
    end
  end
end
