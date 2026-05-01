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
      expect(content).not_to include('{{RECIPE_PATH}}')
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
        expect(content).to match(/RECIPE_PATH = "\/.+\/rel\.recipe\.json"/)
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
      described_class.new(recipe_path: '', output_path: 'x')
    }.to raise_error(ArgumentError, /recipe_path/)
  end

  it 'rejects nil output_path' do
    expect {
      described_class.new(recipe_path: 'x', output_path: nil)
    }.to raise_error(ArgumentError, /output_path/)
  end
end
