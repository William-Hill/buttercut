#!/usr/bin/env ruby
# Generate <name>_apply.py from the apply_recipe.py template by stamping in
# the absolute recipe path. The result is fully self-contained and can be
# dropped into Resolve's Edit scripts directory.

require 'json'

class GenerateApplyScript
  TEMPLATE_PATH = File.expand_path('templates/apply_recipe.py', __dir__)
  PLACEHOLDER_KEYS = %w[
    RECIPE_PATH
    FUSES_SOURCE_DIR
    RESOLVE_FUSES_DIR
  ].freeze
  DEFAULT_FUSES_SOURCE_DIR = File.expand_path('../../../fuses', __dir__)
  DEFAULT_RESOLVE_FUSES_DIR = File.expand_path(
    '~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses'
  )

  def self.generate(recipe_path:, output_path:, fuses_source_dir: DEFAULT_FUSES_SOURCE_DIR, resolve_fuses_dir: DEFAULT_RESOLVE_FUSES_DIR)
    new(
      recipe_path: recipe_path,
      output_path: output_path,
      fuses_source_dir: fuses_source_dir,
      resolve_fuses_dir: resolve_fuses_dir
    ).generate
  end

  def initialize(recipe_path:, output_path:, fuses_source_dir:, resolve_fuses_dir:)
    raise ArgumentError, "recipe_path required" if recipe_path.nil? || recipe_path.empty?
    raise ArgumentError, "output_path required" if output_path.nil? || output_path.empty?

    @recipe_path = File.expand_path(recipe_path)
    @output_path = output_path
    @fuses_source_dir = File.expand_path(fuses_source_dir)
    @resolve_fuses_dir = File.expand_path(resolve_fuses_dir)
  end

  def generate
    template = File.read(TEMPLATE_PATH)
    PLACEHOLDER_KEYS.each do |key|
      placeholder = "{{#{key}}}"
      raise "template missing #{placeholder}" unless template.include?(placeholder)
    end

    stamped = template
      .sub('{{RECIPE_PATH}}') { JSON.dump(@recipe_path) }
      .sub('{{FUSES_SOURCE_DIR}}') { JSON.dump(@fuses_source_dir) }
      .sub('{{RESOLVE_FUSES_DIR}}') { JSON.dump(@resolve_fuses_dir) }

    File.write(@output_path, stamped)
    File.chmod(0o755, @output_path)
    @output_path
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length < 2 || ARGV.length > 3
    warn "Usage: #{$PROGRAM_NAME} <recipe.json> <output_apply.py> [resolve_fuses_dir]"
    exit 1
  end
  resolve_fuses_dir =
    if ARGV.length == 3 && !ARGV[2].to_s.strip.empty?
      ARGV[2]
    elsif !(ENV['BUTTERCUT_RESOLVE_FUSES_DIR'] || '').to_s.strip.empty?
      ENV['BUTTERCUT_RESOLVE_FUSES_DIR']
    else
      GenerateApplyScript::DEFAULT_RESOLVE_FUSES_DIR
    end
  GenerateApplyScript.generate(
    recipe_path: ARGV[0],
    output_path: ARGV[1],
    resolve_fuses_dir: resolve_fuses_dir
  )
  puts "✓ Apply script generated: #{ARGV[1]}"
end
