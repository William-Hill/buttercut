require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'json'
require 'nokogiri'

EXPORT_SCRIPT = File.expand_path('../../.claude/skills/roughcut/export_to_fcpxml.rb', __dir__)
require EXPORT_SCRIPT

RSpec.describe RoughcutExporter do
  let(:fixture_dir) { File.expand_path('../fixtures/broll_integration', __dir__) }
  let(:media_path) { File.expand_path('../fixtures/media/MVI_0323_720p.mov', __dir__) }
  let(:roughcut_yaml_src) { File.join(fixture_dir, 'sample_roughcut.yaml') }
  let(:broll_yaml_src) { File.join(fixture_dir, 'sample_roughcut.broll.yaml') }

  # Skip DTD validation in tests — fixture XML uses minimal asset shape that
  # the DTD rejects, but the structural assertions below are what we care about.
  around(:each) do |example|
    ENV['BUTTERCUT_SKIP_DTD'] = '1'
    example.run
    ENV.delete('BUTTERCUT_SKIP_DTD')
  end

  def with_library
    Dir.mktmpdir do |root|
      lib_dir = File.join(root, 'libraries', 'fixture-library')
      roughcut_dir = File.join(lib_dir, 'roughcuts')
      FileUtils.mkdir_p(roughcut_dir)

      FileUtils.cp(roughcut_yaml_src, File.join(roughcut_dir, 'sample_roughcut.yaml'))

      broll = YAML.load_file(broll_yaml_src)
      broll['entries'].first['rendered'] = media_path
      File.write(File.join(roughcut_dir, 'sample_roughcut.broll.yaml'), broll.to_yaml)

      File.write(File.join(lib_dir, 'library.yaml'), {
        'videos' => [{ 'path' => media_path }]
      }.to_yaml)

      Dir.chdir(root) do
        yield root, File.join('libraries/fixture-library/roughcuts/sample_roughcut.yaml'),
                    File.join('libraries/fixture-library/roughcuts/sample_roughcut.xml')
      end
    end
  end

  it "discovers a sibling broll.yaml and emits an overlay clip in the XML" do
    with_library do |_root, roughcut, xml_out|
      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      doc = Nokogiri::XML(File.read(xml_out)).remove_namespaces!
      expect(doc.xpath('//spine//asset-clip[@lane="1"]').length).to eq(1)
    end
  end

  it "produces XML with no lane=1 clips when no broll.yaml is present" do
    with_library do |_root, roughcut, xml_out|
      File.delete(File.join(File.dirname(roughcut), 'sample_roughcut.broll.yaml'))
      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      doc = Nokogiri::XML(File.read(xml_out)).remove_namespaces!
      expect(doc.xpath('//spine//asset-clip[@lane="1"]')).to be_empty
    end
  end

  it "includes a broll array in the recipe.json" do
    with_library do |_root, roughcut, xml_out|
      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      recipe_path = xml_out.sub(/\.xml\z/, '.recipe.json')
      recipe = JSON.parse(File.read(recipe_path))
      expect(recipe['broll']).to be_an(Array)
      expect(recipe['broll'].first['id']).to eq('br-0001')
    end
  end

  it "late-renders entries with rendered: null and updates the manifest" do
    with_library do |_root, roughcut, xml_out|
      broll_path = File.join(File.dirname(roughcut), 'sample_roughcut.broll.yaml')
      broll = YAML.load_file(broll_path)
      broll['entries'].first['rendered'] = nil
      File.write(broll_path, broll.to_yaml)

      allow(ButterCut::BrollRenderer).to receive(:render) do |entry:, output_dir:, **_kw|
        FileUtils.mkdir_p(output_dir)
        path = File.join(output_dir, "#{entry['id']}.mp4")
        FileUtils.cp(media_path, path)
        path
      end

      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')

      expect(ButterCut::BrollRenderer).to have_received(:render).once

      updated = YAML.load_file(broll_path)
      expect(updated['entries'].first['rendered']).to eq('broll/br-0001.mp4')

      doc = Nokogiri::XML(File.read(xml_out)).remove_namespaces!
      expect(doc.xpath('//spine//asset-clip[@lane="1"]').length).to eq(1)
    end
  end

  it "re-renders entries whose rendered MP4 is missing on disk" do
    with_library do |_root, roughcut, xml_out|
      broll_path = File.join(File.dirname(roughcut), 'sample_roughcut.broll.yaml')
      broll = YAML.load_file(broll_path)
      broll['entries'].first['rendered'] = 'broll/br-0001.mp4'
      File.write(broll_path, broll.to_yaml)

      allow(ButterCut::BrollRenderer).to receive(:render) do |entry:, output_dir:, **_kw|
        FileUtils.mkdir_p(output_dir)
        path = File.join(output_dir, "#{entry['id']}.mp4")
        FileUtils.cp(media_path, path)
        path
      end

      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')

      expect(ButterCut::BrollRenderer).to have_received(:render).once
    end
  end

  it "does NOT re-render entries whose rendered MP4 already exists" do
    with_library do |_root, roughcut, xml_out|
      allow(ButterCut::BrollRenderer).to receive(:render)
      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      expect(ButterCut::BrollRenderer).not_to have_received(:render)
    end
  end

  it "skip_render: true bypasses the render pass entirely (warns and skips on null)" do
    with_library do |_root, roughcut, xml_out|
      broll_path = File.join(File.dirname(roughcut), 'sample_roughcut.broll.yaml')
      broll = YAML.load_file(broll_path)
      broll['entries'].first['rendered'] = nil
      File.write(broll_path, broll.to_yaml)

      allow(ButterCut::BrollRenderer).to receive(:render)

      expect {
        RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx', skip_render: true)
      }.to output(/skipping br-0001.*rendered/i).to_stderr

      expect(ButterCut::BrollRenderer).not_to have_received(:render)
      doc = Nokogiri::XML(File.read(xml_out)).remove_namespaces!
      expect(doc.xpath('//spine//asset-clip[@lane="1"]')).to be_empty
    end
  end
end
