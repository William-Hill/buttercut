require 'spec_helper'
require 'tmpdir'

require_relative '../.claude/skills/roughcut/generate_apply_script'

RSpec.describe GenerateApplyScript do
  it 'stamps the absolute recipe path into the apply script' do
    Dir.mktmpdir do |dir|
      recipe_path = File.join(dir, 'cut.recipe.json')
      File.write(recipe_path, '{}')
      output_path = File.join(dir, 'cut_apply.py')

      described_class.generate(recipe_path: recipe_path, output_path: output_path)

      content = File.read(output_path)
      expect(content).to include(%(RECIPE_PATH = "#{File.expand_path(recipe_path)}"))
      expect(content).to match(/FUSES_SOURCE_DIR\s*=\s*".*\/fuses"/)
      expect(content).to match(/RESOLVE_FUSES_DIR\s*=\s*"[^"]*Fusion\/Fuses\/?"/)
      expect(content).not_to include('{{RECIPE_PATH}}')
      expect(content).not_to include('{{FUSES_SOURCE_DIR}}')
      expect(content).not_to include('{{RESOLVE_FUSES_DIR}}')
    end
  end

  it 'JSON-escapes paths containing quotes or backslashes' do
    # Simulate hostile path values without relying on the filesystem to allow
    # them — we're testing the substitution, not Dir.mkdir.
    instance = described_class.new(
      recipe_path: '/tmp/r.json',
      output_path: '/tmp/out.py',
      fuses_source_dir: '/tmp/fuses',
      resolve_fuses_dir: '/tmp/resolve-fuses'
    )
    instance.instance_variable_set(:@recipe_path, %(/tmp/name with "quote" and \\ backslash/r.json))

    Dir.mktmpdir do |dir|
      output_path = File.join(dir, 'out.py')
      instance.instance_variable_set(:@output_path, output_path)
      instance.generate

      content = File.read(output_path)
      stamped = content[/^RECIPE_PATH = .*/]
      # Quote inside the path must be escaped as \"
      expect(stamped).to include('\\"quote\\"')
      # Backslash inside the path must be escaped as \\
      expect(stamped).to include('and \\\\ backslash')
      expect(content).not_to include('{{RECIPE_PATH}}')

      # And the stamped line must be a valid Python string literal — eval it
      # in Python and check it round-trips to the original path.
      py = "import ast, sys; sys.stdout.write(ast.literal_eval(#{stamped.split('=', 2).last.strip.inspect}))"
      result = `python3 -c #{py.shellescape}`
      expect(result).to eq(%(/tmp/name with "quote" and \\ backslash/r.json))
    end
  end

  it 'produces an executable file' do
    Dir.mktmpdir do |dir|
      recipe_path = File.join(dir, 'r.json')
      File.write(recipe_path, '{}')
      output_path = File.join(dir, 'r_apply.py')

      described_class.generate(recipe_path: recipe_path, output_path: output_path)

      expect(File.executable?(output_path)).to be true
    end
  end

  it 'expands a relative recipe path to absolute' do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        File.write('rel.recipe.json', '{}')
        described_class.generate(recipe_path: 'rel.recipe.json', output_path: 'out.py')

        content = File.read('out.py')
        expect(content).to match(%r{RECIPE_PATH = "/.+/rel\.recipe\.json"})
      end
    end
  end

  it 'is idempotent — re-running with the same inputs reproduces the same output' do
    Dir.mktmpdir do |dir|
      recipe_path = File.join(dir, 'r.json')
      File.write(recipe_path, '{}')
      output_path = File.join(dir, 'out.py')

      described_class.generate(recipe_path: recipe_path, output_path: output_path)
      first = File.read(output_path)
      described_class.generate(recipe_path: recipe_path, output_path: output_path)
      second = File.read(output_path)

      expect(first).to eq(second)
    end
  end

  it 'rejects empty recipe_path' do
    expect {
      described_class.new(recipe_path: '', output_path: 'x', fuses_source_dir: '/tmp/fuses', resolve_fuses_dir: '/tmp/resolve-fuses')
    }.to raise_error(ArgumentError, /recipe_path/)
  end

  it 'rejects nil output_path' do
    expect {
      described_class.new(recipe_path: 'x', output_path: nil, fuses_source_dir: '/tmp/fuses', resolve_fuses_dir: '/tmp/resolve-fuses')
    }.to raise_error(ArgumentError, /output_path/)
  end

  it 'logs the b-roll count when the recipe has a broll array' do
    Dir.mktmpdir do |dir|
      recipe = {
        'version' => 3,
        'library' => 'test-lib',
        'timeline' => 'test-timeline',
        'clips' => [{ 'index' => 1, 'source_file' => 'a.mov' }],
        'broll' => [{
          'id' => 'br-0001', 'start' => 1.0, 'end' => 2.0,
          'placement' => 'overlay', 'source' => 'broll/br-0001.mp4',
          'source_video' => 'a.mov'
        }]
      }
      recipe_path = File.join(dir, 'test.recipe.json')
      apply_path = File.join(dir, 'test_apply.py')
      File.write(recipe_path, JSON.pretty_generate(recipe))

      described_class.generate(recipe_path: recipe_path, output_path: apply_path)

      contents = File.read(apply_path)
      # Generated Python should reference the b-roll array and its length so
      # users running the apply script see how many manifest entries exist.
      expect(contents).to include("recipe.get('broll'")
      expect(contents).to match(/len\(broll_clips\).*b-roll clip/i)
    end
  end
end
