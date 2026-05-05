#!/usr/bin/env ruby

class LintFuses
  def self.run
    new.run
  end

  def run
    fuses_dir = File.expand_path('../../fuses', __dir__)
    files = Dir.glob(File.join(fuses_dir, '**', '*.fuse')).sort
    if files.empty?
      warn "no fuses to lint at #{fuses_dir}"
      return 0
    end

    command = ['luacheck', '--no-color', *files]
    puts command.join(' ')
    system(*command) ? 0 : 1
  end
end

if __FILE__ == $PROGRAM_NAME
  exit LintFuses.run
end
