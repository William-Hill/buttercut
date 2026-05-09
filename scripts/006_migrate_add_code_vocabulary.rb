#!/usr/bin/env ruby
# Adds `code_vocabulary: []` to the existing `broll:` block in library.yaml.
# Edits textually so quote styles and indentation elsewhere are preserved.
#
# Usage: ruby scripts/006_migrate_add_code_vocabulary.rb [library_name]
#        ruby scripts/006_migrate_add_code_vocabulary.rb --all

require 'yaml'
require 'date'

class MigrateAddCodeVocabulary
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

    ok = if @args[0] == '--all'
      migrate_all
    else
      migrate_one(@args[0])
    end

    puts "\nMigration complete."
    ok ? 0 : 1
  end

  private

  def print_usage
    puts "Usage: ruby scripts/006_migrate_add_code_vocabulary.rb [library_name]"
    puts "       ruby scripts/006_migrate_add_code_vocabulary.rb --all"
  end

  def migrate_all
    libraries = Dir.glob("libraries/*/library.yaml")
    puts "Migrating #{libraries.length} libraries...\n\n"
    libraries.all? do |path|
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
    parsed = YAML.safe_load(content, permitted_classes: [Date, Time, Symbol], aliases: false)
    unless parsed.is_a?(Hash) && parsed['broll'].is_a?(Hash)
      return refuse("No `broll:` block found; run scripts/005_migrate_add_broll.rb first")
    end
    return note("Already has code_vocabulary; no change") if parsed['broll'].key?('code_vocabulary')

    new_content = insert_line(content)
    return false unless new_content
    return false unless valid_after_insert?(new_content)

    File.write(path, new_content)
    puts "  ✓ Added code_vocabulary: [] to broll block"
    true
  end

  # Insert immediately after `blacklist_terms:` so the new key sits inside
  # the broll block. Falls back to inserting after the last broll key if the
  # block uses a different ordering.
  def insert_line(content)
    lines = content.lines
    broll_idx = lines.index { |l| l.match?(/^broll:/) }
    return refuse("`broll:` not found at column 0") unless broll_idx

    block_end = broll_idx + 1
    while block_end < lines.length && lines[block_end].match?(/^\s+\S/)
      block_end += 1
    end

    insert_at = lines[broll_idx...block_end].rindex { |l| l.match?(/^  blacklist_terms:/) }
    insert_at = insert_at ? broll_idx + insert_at + 1 : block_end

    lines.insert(insert_at, "  code_vocabulary: []\n").join
  end

  def valid_after_insert?(new_content)
    parsed = YAML.safe_load(new_content, permitted_classes: [Date, Time, Symbol], aliases: false)
    return true if parsed.is_a?(Hash) && parsed['broll'].is_a?(Hash) && parsed['broll']['code_vocabulary'] == []
    refuse("Insert produced unexpected YAML; refusing to write")
  end

  def refuse(msg)
    puts "  ✗ #{msg}"
    false
  end

  def note(msg)
    puts "  - #{msg}"
    true
  end
end

if __FILE__ == $PROGRAM_NAME
  exit MigrateAddCodeVocabulary.run(ARGV)
end
