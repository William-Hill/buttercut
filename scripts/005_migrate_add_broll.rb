#!/usr/bin/env ruby
# Edits library.yaml textually rather than round-tripping through YAML so
# quote styles and indentation elsewhere in the file are preserved exactly.
#
# Usage: ruby scripts/005_migrate_add_broll.rb [library_name]
#        ruby scripts/005_migrate_add_broll.rb --all

require 'yaml'
require 'date'

class MigrateAddBroll
  BROLL_BLOCK = <<~YAML
    broll:
      density: medium
      score_threshold: 0.5
      blacklist_terms: []
  YAML

  def self.run(args)
    new(args).run
  end

  def initialize(args)
    raise ArgumentError, "args required" if args.nil?
    @args = args
  end

  def run
    if @args.empty?
      print_usage
      return 1
    end

    if @args[0] == '--all'
      migrate_all
    else
      migrate_one(@args[0])
    end

    puts "\nMigration complete."
    0
  end

  private

  def print_usage
    puts "Usage: ruby scripts/005_migrate_add_broll.rb [library_name]"
    puts "       ruby scripts/005_migrate_add_broll.rb --all"
  end

  def migrate_all
    libraries = Dir.glob("libraries/*/library.yaml")
    puts "Migrating #{libraries.length} libraries...\n\n"
    libraries.each do |path|
      puts "#{path.split('/')[1]}:"
      migrate_library(path)
    end
  end

  def migrate_one(library_name)
    puts "#{library_name}:"
    migrate_library("libraries/#{library_name}/library.yaml")
  end

  def migrate_library(path)
    return refuse("Not found: #{path}") unless File.exist?(path)

    content = File.read(path)
    return note("Already has broll block; no change") if content.match?(/^broll:/)

    new_content = insert_block(content)
    return false unless new_content
    return false unless valid_after_insert?(new_content)

    File.write(path, new_content)
    puts "  ✓ Added broll block (density: medium, score_threshold: 0.5)"
    true
  end

  def insert_block(content)
    lines = content.lines
    insert_index = lines.index { |l| l.match?(/^footage_summary:/) } ||
                   lines.index { |l| l.match?(/^videos:/) }
    unless insert_index
      refuse("No `footage_summary:` or `videos:` anchor found; skipping")
      return nil
    end
    lines.insert(insert_index, BROLL_BLOCK, "\n").join
  end

  def valid_after_insert?(new_content)
    parsed = YAML.safe_load(new_content, permitted_classes: [Date, Time, Symbol], aliases: false)
    return true if parsed.is_a?(Hash) && parsed['broll'].is_a?(Hash) &&
                   parsed['broll']['density'] == 'medium' &&
                   parsed['broll']['score_threshold'] == 0.5 &&
                   parsed['broll']['blacklist_terms'] == []
    refuse("Insert produced unexpected YAML; refusing to write")
  end

  def refuse(msg)
    puts "  ✗ #{msg}"
    false
  end

  def note(msg)
    puts "  - #{msg}"
    false
  end
end

if __FILE__ == $PROGRAM_NAME
  exit MigrateAddBroll.run(ARGV)
end
