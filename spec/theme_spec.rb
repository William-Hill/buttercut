require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'buttercut/theme'

RSpec.describe ButterCut::Theme do
  let(:themes_dir) { File.expand_path('../themes', __dir__) }

  describe '.resolve' do
    it 'loads a preset and returns its tokens' do
      tokens = described_class.resolve(
        library_theme: { 'template_set' => 'tutorial-dark' },
        themes_dir: themes_dir
      )
      expect(tokens['font_display']).to eq('Inter')
      expect(tokens['font_mono']).to eq('JetBrains Mono')
      expect(tokens['color_bg']).to eq('#0d0d0d')
      expect(tokens['color_accent']).to eq('#ff6b35')
      expect(tokens['motion']).to eq('snappy')
    end

    it 'merges library overrides over the preset' do
      tokens = described_class.resolve(
        library_theme: {
          'template_set' => 'tutorial-dark',
          'color_accent' => '#00ff00',
          'logo' => 'assets/custom.svg'
        },
        themes_dir: themes_dir
      )
      expect(tokens['color_accent']).to eq('#00ff00')
      expect(tokens['logo']).to eq('assets/custom.svg')
      expect(tokens['font_display']).to eq('Inter') # untouched preset value
    end

    it 'raises when template_set is missing' do
      expect {
        described_class.resolve(library_theme: {}, themes_dir: themes_dir)
      }.to raise_error(ArgumentError, /template_set/)
    end

    it 'raises when the preset file does not exist' do
      expect {
        described_class.resolve(
          library_theme: { 'template_set' => 'does-not-exist' },
          themes_dir: themes_dir
        )
      }.to raise_error(ArgumentError, /preset/)
    end

    it 'raises when motion is invalid' do
      expect {
        described_class.resolve(
          library_theme: { 'template_set' => 'tutorial-dark', 'motion' => 'wobbly' },
          themes_dir: themes_dir
        )
      }.to raise_error(ArgumentError, /motion/)
    end

    it 'accepts symbol keys in library_theme' do
      tokens = described_class.resolve(
        library_theme: { template_set: 'tutorial-dark' },
        themes_dir: themes_dir
      )
      expect(tokens['font_display']).to eq('Inter')
    end
  end

  describe 'preset files' do
    %w[tutorial-dark vlog-warm corporate-clean].each do |name|
      it "loads and parses #{name}.yaml with required keys" do
        path = File.join(themes_dir, "#{name}.yaml")
        expect(File).to exist(path)
        data = YAML.load_file(path)
        %w[font_display font_mono color_bg color_accent logo motion].each do |key|
          expect(data).to have_key(key), "#{name}.yaml missing key: #{key}"
        end
        expect(%w[snappy smooth minimal]).to include(data['motion'])
      end
    end

    it 'tutorial-dark matches the existing code-callout palette' do
      data = YAML.load_file(File.join(themes_dir, 'tutorial-dark.yaml'))
      expect(data['font_display']).to eq('Inter')
      expect(data['font_mono']).to eq('JetBrains Mono')
      expect(data['color_bg']).to eq('#0d0d0d')
      expect(data['color_accent']).to eq('#ff6b35')
    end
  end
end
