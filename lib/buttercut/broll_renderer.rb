require 'json'
require 'fileutils'
require 'shellwords'

class ButterCut
  # Renders one b-roll manifest entry to MP4 via the Hyperframes CLI.
  # Sub-agents do not interact with library.yaml — the parent passes
  # `entry`, `theme`, `output_dir`, and `hyperframes_dir` inline.
  class BrollRenderer
    PINNED_FPS = '30'
    PINNED_QUALITY = 'standard'
    PINNED_WORKERS = '1'

    def self.render(entry:, theme:, output_dir:, hyperframes_dir:)
      new(entry: entry, theme: theme, output_dir: output_dir, hyperframes_dir: hyperframes_dir).render
    end

    def initialize(entry:, theme:, output_dir:, hyperframes_dir:)
      raise ArgumentError, 'entry hash required' unless entry.is_a?(Hash) && !entry.empty?
      raise ArgumentError, 'theme hash required' unless theme.is_a?(Hash)
      raise ArgumentError, 'output_dir required' if !output_dir.is_a?(String) || output_dir.empty?
      raise ArgumentError, 'hyperframes_dir required' if !hyperframes_dir.is_a?(String) || hyperframes_dir.empty?

      @entry = entry
      @theme = theme
      @output_dir = output_dir
      @hyperframes_dir = hyperframes_dir
    end

    def render
      validate_composition_exists!
      FileUtils.mkdir_p(@output_dir)
      out = output_path
      File.delete(out) if File.exist?(out)
      run_render!(build_command(out))
      raise "render produced no file at #{out}" unless File.exist?(out)
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

    def variables
      duration = @entry.fetch('end') - @entry.fetch('start')
      (@entry['content'] || {}).merge('duration' => duration, 'theme' => @theme)
    end

    def build_command(out)
      [
        'npx', '--prefix', @hyperframes_dir, '-y', 'hyperframes', 'render', composition_dir,
        '-o', out,
        '--fps', PINNED_FPS,
        '--quality', PINNED_QUALITY,
        '--workers', PINNED_WORKERS,
        '--quiet',
        '--variables', JSON.generate(variables)
      ]
    end

    def run_render!(cmd)
      ok = system(*cmd)
      raise "hyperframes render failed: #{Shellwords.join(cmd)}" unless ok
    end
  end
end
