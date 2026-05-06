#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path('../../../lib', __FILE__))
require 'buttercut/fuse_library'
require 'json'
require 'fileutils'
require 'time'

class VerifyFuses
  def self.run(fixture_path)
    new(fixture_path).run
  end

  def initialize(fixture_path)
    raise ArgumentError, "fixture_path required" if fixture_path.nil? || fixture_path.empty?
    raise ArgumentError, "fixture not found: #{fixture_path}" unless File.file?(fixture_path)

    @fixture = File.expand_path(fixture_path)
    @repo_root = File.expand_path('../../..', __FILE__)
    @library = ButterCut::FuseLibrary.load(root: File.join(@repo_root, 'fuses'))
  end

  def run
    if @library.names.empty?
      warn "no fuses registered in fuses/ - nothing to verify"
      return 1
    end

    out_dir = File.join(@repo_root, 'tmp', 'verify_fuses')
    FileUtils.mkdir_p(out_dir)
    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%S')
    recipe_path = File.join(out_dir, "recipe_#{stamp}.json")
    apply_path = File.join(out_dir, "apply_#{stamp}.py")

    File.write(recipe_path, JSON.pretty_generate(build_recipe))
    require_relative '../skills/roughcut/generate_apply_script'
    GenerateApplyScript.generate(recipe_path: recipe_path, output_path: apply_path)

    print_instructions(apply_path)
    0
  end

  private

  def build_recipe
    clips = @library.names.each_with_index.map do |name, index|
      manifest = @library.lookup(name)
      {
        "index" => index + 1,
        "source_file" => @fixture,
        "fusion_effects" => [{
          "fuse" => name,
          "params" => default_params(manifest)
        }]
      }
    end

    {
      "version" => 2,
      "library" => "verify_fuses",
      "timeline" => "verify_fuses_#{Time.now.to_i}",
      "clips" => clips
    }
  end

  def default_params(manifest)
    manifest.fetch('params').each_with_object({}) { |param, out| out[param.fetch('name')] = param['default'] }
  end

  def print_instructions(apply_path)
    puts <<~TEXT

      --- verify_fuses smoke ---
      1. Open DaVinci Resolve.
      2. Create a timeline and place #{@library.names.length} copies of this clip on V1:
         #{@fixture}
      3. Open Workspace > Console > Py3 and run:
           exec(open(#{apply_path.inspect}, encoding="utf-8").read())
      4. Expected output includes:
           fusion_effects: #{@library.names.length}/#{@library.names.length}
         with no ACTION REQUIRED and no warnings.
      5. Confirm each clip has its expected fuse tool in Fusion.
      6. Optionally capture screenshots for fuses/<Name>/reference.png.

      Apply script path:
      #{apply_path}
    TEXT
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length != 1
    warn "Usage: #{$PROGRAM_NAME} <fixture.mov>"
    exit 1
  end

  exit VerifyFuses.run(ARGV[0])
end
