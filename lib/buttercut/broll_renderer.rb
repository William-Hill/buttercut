require 'json'
require 'fileutils'
require 'shellwords'
require 'securerandom'

class ButterCut
  class BrollRenderer
    PINNED_FPS = '30'
    PINNED_QUALITY = 'standard'
    PINNED_WORKERS = '1'
    PINNED_HYPERFRAMES_VERSION = '0.5.3'
    SAFE_SLUG = /\A[a-z0-9][a-z0-9_-]*\z/i

    def self.render(entry:, theme:, output_dir:, hyperframes_dir:)
      new(entry: entry, theme: theme, output_dir: output_dir, hyperframes_dir: hyperframes_dir).render
    end

    def initialize(entry:, theme:, output_dir:, hyperframes_dir:)
      raise ArgumentError, 'entry hash required' unless entry.is_a?(Hash) && !entry.empty?
      raise ArgumentError, 'theme hash required' unless theme.is_a?(Hash) && !theme.empty?
      raise ArgumentError, 'output_dir required' if !output_dir.is_a?(String) || output_dir.empty?
      raise ArgumentError, 'hyperframes_dir required' if !hyperframes_dir.is_a?(String) || hyperframes_dir.empty?

      @entry = entry
      @theme = theme
      @output_dir = output_dir
      @hyperframes_dir = hyperframes_dir

      validate_entry!
    end

    def render
      validate_composition_exists!
      FileUtils.mkdir_p(@output_dir)
      out = output_path
      tmp = "#{out}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}"
      File.delete(tmp) if File.exist?(tmp)
      begin
        run_render!(build_command(tmp))
        raise "render produced no file at #{tmp}" unless File.exist?(tmp)
        FileUtils.mv(tmp, out, force: true)
      ensure
        File.delete(tmp) if File.exist?(tmp)
      end
      out
    end

    private

    def output_path
      File.join(@output_dir, "#{@entry.fetch('id')}.mp4")
    end

    def composition_dir
      File.join(@hyperframes_dir, 'compositions', @entry.fetch('template'))
    end

    def validate_composition_exists!
      unless File.exist?(File.join(composition_dir, 'index.html'))
        raise ArgumentError, "composition not found for template #{@entry['template'].inspect} at #{composition_dir}"
      end
    end

    def validate_entry!
      id = @entry['id']
      template = @entry['template']
      unless id.is_a?(String) && id.match?(SAFE_SLUG)
        raise ArgumentError, "entry id must match #{SAFE_SLUG.source}, got #{id.inspect}"
      end
      unless template.is_a?(String) && template.match?(SAFE_SLUG)
        raise ArgumentError, "entry template must match #{SAFE_SLUG.source}, got #{template.inspect}"
      end
      start_t = @entry['start']
      end_t = @entry['end']
      unless start_t.is_a?(Numeric) && end_t.is_a?(Numeric) && end_t > start_t
        raise ArgumentError, "entry start/end must be numeric with end > start, got start=#{start_t.inspect} end=#{end_t.inspect}"
      end
    end

    def variables
      duration = @entry.fetch('end') - @entry.fetch('start')
      (@entry['content'] || {}).merge('duration' => duration, 'theme' => @theme)
    end

    def build_command(out)
      hyperframes_invocation + [
        'render', composition_dir,
        '-o', out,
        '--fps', PINNED_FPS,
        '--quality', PINNED_QUALITY,
        '--workers', PINNED_WORKERS,
        '--quiet',
        '--variables', JSON.generate(variables)
      ]
    end

    def hyperframes_invocation
      local_bin = File.join(@hyperframes_dir, 'node_modules', '.bin', 'hyperframes')
      return [local_bin] if File.executable?(local_bin)
      ['npx', '--prefix', @hyperframes_dir, '-y', "hyperframes@#{PINNED_HYPERFRAMES_VERSION}"]
    end

    def run_render!(cmd)
      ok = system(*cmd)
      raise "hyperframes render failed: #{Shellwords.join(cmd)}" unless ok
    end
  end
end
