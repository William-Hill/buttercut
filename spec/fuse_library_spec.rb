require 'spec_helper'
require 'buttercut/fuse_library'
require 'fileutils'
require 'json'
require 'tmpdir'

RSpec.describe ButterCut::FuseLibrary do
  def write_fuse(root, name, manifest)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.json'), JSON.pretty_generate(manifest))
    File.write(File.join(dir, "#{name}.fuse"), "-- stub\n")
  end

  let(:base_manifest) do
    {
      "name" => "ChromaPulse",
      "version" => "1.0.0",
      "description" => "Chromatic aberration that pulses.",
      "tested_on_resolve" => "20.2.3",
      "params" => [
        { "name" => "intensity", "type" => "number", "default" => 0.4, "range" => [0.0, 1.0] }
      ]
    }
  end

  it 'loads a valid library and looks up by name' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'ChromaPulse', base_manifest)
      lib = described_class.load(root: root)
      fuse = lib.lookup('ChromaPulse')
      expect(fuse['name']).to eq('ChromaPulse')
      expect(fuse['fuse_path']).to eq(File.join(root, 'ChromaPulse', 'ChromaPulse.fuse'))
    end
  end

  it 'returns nil for unknown names from lookup' do
    Dir.mktmpdir do |root|
      lib = described_class.load(root: root)
      expect(lib.lookup('Nope')).to be_nil
    end
  end

  it 'raises on duplicate fuse names across manifest dirs' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'A', base_manifest.merge('name' => 'Same'))
      write_fuse(root, 'B', base_manifest.merge('name' => 'Same'))
      expect { described_class.load(root: root) }.to raise_error(ArgumentError, /duplicate/i)
    end
  end

  it 'raises on missing required manifest keys' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'X', { "name" => "X" })
      expect { described_class.load(root: root) }.to raise_error(ArgumentError, /version|description|params/)
    end
  end

  it 'validates params: type and range' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'ChromaPulse', base_manifest)
      lib = described_class.load(root: root)
      expect { lib.validate_params!('ChromaPulse', { "intensity" => 0.5 }) }.not_to raise_error
      expect { lib.validate_params!('ChromaPulse', { "intensity" => 2.0 }) }.to raise_error(ArgumentError, /range/)
      expect { lib.validate_params!('ChromaPulse', { "intensity" => "high" }) }.to raise_error(ArgumentError, /type/)
      expect { lib.validate_params!('ChromaPulse', { "wat" => 1 }) }.to raise_error(ArgumentError, /unknown/i)
    end
  end

  it 'validate_params! raises for unknown fuse name' do
    Dir.mktmpdir do |root|
      lib = described_class.load(root: root)
      expect { lib.validate_params!('Missing', {}) }.to raise_error(ArgumentError, /unknown fuse/i)
    end
  end

  it 'validates integer params against declared range' do
    manifest = {
      "name" => "ZoomPunch",
      "version" => "1.0.0",
      "description" => "test",
      "params" => [
        { "name" => "duration_frames", "type" => "integer", "default" => 6, "range" => [1, 30] }
      ]
    }
    Dir.mktmpdir do |root|
      write_fuse(root, 'ZoomPunch', manifest)
      lib = described_class.load(root: root)
      expect { lib.validate_params!('ZoomPunch', { "duration_frames" => 6 }) }.not_to raise_error
      expect { lib.validate_params!('ZoomPunch', { "duration_frames" => 0 }) }.to raise_error(ArgumentError, /range/)
      expect { lib.validate_params!('ZoomPunch', { "duration_frames" => 99 }) }.to raise_error(ArgumentError, /range/)
    end
  end
end
