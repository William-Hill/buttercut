require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'open3'
require 'date'

RSpec.describe '005_migrate_add_broll.rb' do
  let(:script_path) { File.expand_path('../scripts/005_migrate_add_broll.rb', __dir__) }

  def run_migration(library_name, cwd)
    Open3.capture2('ruby', script_path, library_name, chdir: cwd)
  end

  def write_library(dir, name, content)
    lib_dir = File.join(dir, 'libraries', name)
    FileUtils.mkdir_p(lib_dir)
    path = File.join(lib_dir, 'library.yaml')
    File.write(path, content)
    path
  end

  let(:legacy_yaml) do
    <<~YAML
      library_name: my-lib
      language: english
      transcript_refinement: false
      user_context: ""
      footage_summary: "x"
      videos:
        - path: /tmp/x.mov
          duration: "00:01:00"
          transcript:
          visual_transcript:
          summary:
    YAML
  end

  it 'adds the default broll block to a library missing it' do
    Dir.mktmpdir do |dir|
      path = write_library(dir, 'my-lib', legacy_yaml)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/Added broll block/)
      data = YAML.load_file(path, permitted_classes: [Date, Time, Symbol])
      expect(data['broll']).to eq('density' => 'medium', 'score_threshold' => 0.5, 'blacklist_terms' => [])
    end
  end

  it 'is idempotent — running twice is a no-op' do
    Dir.mktmpdir do |dir|
      path = write_library(dir, 'my-lib', legacy_yaml)
      run_migration('my-lib', dir)
      first = File.read(path)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/already has/i)
      expect(File.read(path)).to eq(first)
    end
  end

  it 'leaves a library with an existing broll block alone' do
    Dir.mktmpdir do |dir|
      yaml_with_broll = <<~YAML
        library_name: my-lib
        broll:
          density: high
          score_threshold: 0.7
          blacklist_terms: [function]
        footage_summary: "x"
        videos:
          - path: /tmp/x.mov
      YAML
      path = write_library(dir, 'my-lib', yaml_with_broll)
      original = File.read(path)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/already has/i)
      expect(File.read(path)).to eq(original)
      data = YAML.load_file(path, permitted_classes: [Date, Time, Symbol])
      expect(data['broll']['density']).to eq('high')
    end
  end
end
