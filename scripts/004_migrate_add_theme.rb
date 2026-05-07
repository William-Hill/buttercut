#!/usr/bin/env ruby
# Edits library.yaml textually rather than round-tripping through YAML so
# quote styles and indentation elsewhere in the file are preserved exactly.
#
# Usage: ruby scripts/004_migrate_add_theme.rb [library_name]
#        ruby scripts/004_migrate_add_theme.rb --all

require 'yaml'
require 'date'

def migrate_library(library_path)
  unless File.exist?(library_path)
    puts "  ✗ Not found: #{library_path}"
    return false
  end

  content = File.read(library_path)

  if content.match?(/^theme:/)
    puts "  - Already has theme block; no change"
    return false
  end

  block = <<~YAML
    theme:
      font_display: Inter
      font_mono: JetBrains Mono
      color_bg: '#0d0d0d'
      color_fg: '#f5f5f4'
      color_accent: '#ff6b35'
      logo: assets/logo.svg
      template_set: tutorial-dark
      motion: snappy
  YAML

  lines = content.lines
  insert_index = lines.index { |line| line.match?(/^footage_summary:/) }
  insert_index ||= lines.index { |line| line.match?(/^videos:/) }

  unless insert_index
    puts "  ✗ No `footage_summary:` or `videos:` anchor found; skipping"
    return false
  end

  lines.insert(insert_index, block, "\n")
  new_content = lines.join

  parsed = YAML.load(new_content, permitted_classes: [Date, Time, Symbol])
  unless parsed.is_a?(Hash) && parsed['theme'].is_a?(Hash) && parsed['theme']['template_set'] == 'tutorial-dark'
    puts "  ✗ Insert produced unexpected YAML; refusing to write"
    return false
  end

  File.write(library_path, new_content)
  puts "  ✓ Added theme block (template_set: tutorial-dark)"
  true
end

def find_libraries
  Dir.glob("libraries/*/library.yaml")
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    puts "Usage: ruby scripts/004_migrate_add_theme.rb [library_name]"
    puts "       ruby scripts/004_migrate_add_theme.rb --all"
    exit 1
  end

  if ARGV[0] == '--all'
    libraries = find_libraries
    puts "Migrating #{libraries.length} libraries...\n\n"
    libraries.each do |lib_path|
      lib_name = lib_path.split('/')[1]
      puts "#{lib_name}:"
      migrate_library(lib_path)
    end
  else
    library_name = ARGV[0]
    library_path = "libraries/#{library_name}/library.yaml"
    puts "#{library_name}:"
    migrate_library(library_path)
  end

  puts "\nMigration complete."
end
