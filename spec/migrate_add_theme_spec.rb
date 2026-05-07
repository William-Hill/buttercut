require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'open3'
require 'date'

RSpec.describe '004_migrate_add_theme.rb' do
  let(:script_path) { File.expand_path('../scripts/004_migrate_add_theme.rb', __dir__) }

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
      created_date: 2026-01-01
      last_updated: 2026-01-01
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

  it 'adds the default theme block to a library missing it' do
    Dir.mktmpdir do |dir|
      path = write_library(dir, 'my-lib', legacy_yaml)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/Added theme block/)
      data = YAML.load_file(path, permitted_classes: [Date, Time, Symbol])
      expect(data).to have_key('theme')
      expect(data['theme']['template_set']).to eq('tutorial-dark')
      expect(data['theme']['font_display']).to eq('Inter')
      expect(data['theme']['motion']).to eq('snappy')
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

  it 'leaves a library with an existing theme block alone' do
    Dir.mktmpdir do |dir|
      yaml_with_theme = legacy_yaml + <<~YAML
        theme:
          font_display: CustomFont
          font_mono: CustomMono
          color_bg: '#111111'
          color_accent: '#222222'
          logo: assets/x.svg
          template_set: vlog-warm
          motion: smooth
      YAML
      path = write_library(dir, 'my-lib', yaml_with_theme)
      original = File.read(path)
      out, _ = run_migration('my-lib', dir)
      expect(out).to match(/already has/i)
      expect(File.read(path)).to eq(original)
      data = YAML.load_file(path, permitted_classes: [Date, Time, Symbol])
      expect(data['theme']['font_display']).to eq('CustomFont')
    end
  end
end
