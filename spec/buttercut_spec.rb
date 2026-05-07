require 'spec_helper'

RSpec.describe ButterCut do
  let(:video_file_path) { File.expand_path('./fixtures/media/MVI_0323_720p.mov', __dir__) }
  let(:clips) { [{ path: video_file_path }] }

  describe '.new factory method' do
    it 'creates a ButterCut::FCPX instance when editor is :fcpx' do
      generator = ButterCut.new(clips, editor: :fcpx)
      expect(generator).to be_a(ButterCut::FCPX)
    end

    it 'creates a ButterCut::FCP7 instance when editor is :fcp7' do
      generator = ButterCut.new(clips, editor: :fcp7)
      expect(generator).to be_a(ButterCut::FCP7)
    end

    it 'requires editor parameter' do
      expect { ButterCut.new(clips) }.to raise_error(ArgumentError, /missing keyword.*editor/)
    end

    it 'raises error for unsupported editor' do
      expect { ButterCut.new(clips, editor: :premiere) }.to raise_error(ArgumentError, /Unsupported editor: :premiere/)
      expect { ButterCut.new(clips, editor: :resolve) }.to raise_error(ArgumentError, /Unsupported editor: :resolve/)
      expect { ButterCut.new(clips, editor: :invalid) }.to raise_error(ArgumentError, /Unsupported editor: :invalid/)
    end

    it 'accepts an optional overlays: keyword and exposes it via the editor' do
      overlay = {
        source: video_file_path,
        source_id: 'br-0001',
        start: 0.0,
        duration: 1.0,
        placement: 'overlay'
      }
      generator = ButterCut.new(clips, editor: :fcpx, overlays: [overlay])
      expect(generator.overlays.length).to eq(1)
      expect(generator.overlays.first).to be_a(ButterCut::Overlay)
      expect(generator.overlays.first.source_id).to eq('br-0001')
    end

    it 'defaults overlays to [] when omitted' do
      generator = ButterCut.new(clips, editor: :fcpx)
      expect(generator.overlays).to eq([])
    end
  end
end
