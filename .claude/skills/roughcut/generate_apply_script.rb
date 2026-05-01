#!/usr/bin/env ruby
# Generate <name>_apply.py from the apply_recipe.py template by stamping in
# the absolute recipe path. The result is fully self-contained and can be
# dropped into Resolve's Edit scripts directory.

class GenerateApplyScript
  TEMPLATE_PATH = File.expand_path('templates/apply_recipe.py', __dir__)
  PLACEHOLDER = '{{RECIPE_PATH}}'.freeze

  def self.generate(recipe_path:, output_path:)
    new(recipe_path: recipe_path, output_path: output_path).generate
  end

  def initialize(recipe_path:, output_path:)
    raise ArgumentError, "recipe_path required" if recipe_path.nil? || recipe_path.empty?
    raise ArgumentError, "output_path required" if output_path.nil? || output_path.empty?

    @recipe_path = File.expand_path(recipe_path)
    @output_path = output_path
  end

  def generate
    template = File.read(TEMPLATE_PATH)
    raise "template missing #{PLACEHOLDER}" unless template.include?(PLACEHOLDER)

    stamped = template.sub(PLACEHOLDER, @recipe_path)
    File.write(@output_path, stamped)
    File.chmod(0o755, @output_path)
    @output_path
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length != 2
    warn "Usage: #{$PROGRAM_NAME} <recipe.json> <output_apply.py>"
    exit 1
  end
  GenerateApplyScript.generate(recipe_path: ARGV[0], output_path: ARGV[1])
  puts "✓ Apply script generated: #{ARGV[1]}"
end
