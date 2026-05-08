require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'open3'
require 'date'

RSpec.describe '006_migrate_add_code_vocabulary.rb' do
  let(:script_path) { File.expand_path('../scripts/006_migrate_add_code_vocabulary.rb', __dir__) }

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

  let(:post_005_yaml) do
    <<~YAML
      library_name: my-lib
      broll:
        density: medium
        score_threshold: 0.5
        blacklist_terms: []
      footage_summary: "x"
      videos: []
    YAML
  end

  it 'appends code_vocabulary: [] to an existing broll block' do
    Dir.mktmpdir do |dir|
      path = write_library(dir, 'my-lib', post_005_yaml)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/Added code_vocabulary/)
      data = YAML.load_file(path, permitted_classes: [Date, Time, Symbol])
      expect(data['broll']['code_vocabulary']).to eq([])
      expect(data['broll']['blacklist_terms']).to eq([])
      expect(data['broll']['density']).to eq('medium')
    end
  end

  it 'is idempotent' do
    Dir.mktmpdir do |dir|
      path = write_library(dir, 'my-lib', post_005_yaml)
      run_migration('my-lib', dir)
      first = File.read(path)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/already has/i)
      expect(File.read(path)).to eq(first)
    end
  end

  it 'refuses to run when no broll block exists' do
    Dir.mktmpdir do |dir|
      yaml_no_broll = <<~YAML
        library_name: my-lib
        footage_summary: "x"
        videos: []
      YAML
      write_library(dir, 'my-lib', yaml_no_broll)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/run scripts\/005/)
    end
  end

  it 'preserves a non-empty code_vocabulary already present' do
    Dir.mktmpdir do |dir|
      yaml_with_vocab = <<~YAML
        library_name: my-lib
        broll:
          density: medium
          score_threshold: 0.5
          blacklist_terms: []
          code_vocabulary: [git, npm]
        footage_summary: "x"
      YAML
      path = write_library(dir, 'my-lib', yaml_with_vocab)
      original = File.read(path)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/already has/i)
      expect(File.read(path)).to eq(original)
      data = YAML.load_file(path, permitted_classes: [Date, Time, Symbol])
      expect(data['broll']['code_vocabulary']).to eq(['git', 'npm'])
    end
  end
end
