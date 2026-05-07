require 'spec_helper'
require 'nokogiri'
require 'buttercut'

RSpec.describe ButterCut::FCPX, "overlay emission" do
  let(:video_file_path) { File.expand_path('../fixtures/media/MVI_0323_720p.mov', __dir__) }
  let(:clips) { [{ path: video_file_path }] }
  let(:overlay) do
    {
      source: video_file_path,        # reuse media fixture as a stand-in MP4
      source_id: 'br-0001',
      start: 0.5,
      duration: 1.0,
      placement: 'overlay'
    }
  end

  def doc(overlays)
    xml = ButterCut.new(clips, editor: :fcpx, overlays: overlays).to_xml
    Nokogiri::XML(xml).remove_namespaces!
  end

  context "no overlays" do
    it "emits no lane=1 clips" do
      d = doc([])
      expect(d.xpath('//spine//asset-clip[@lane]')).to be_empty
    end

    it "emits the same number of <asset>, <asset-clip> children of spine, and <adjust-volume> elements as a generator without overlays" do
      a = Nokogiri::XML(ButterCut.new(clips, editor: :fcpx).to_xml).remove_namespaces!
      b = Nokogiri::XML(ButterCut.new(clips, editor: :fcpx, overlays: []).to_xml).remove_namespaces!
      expect(b.xpath('//resources/asset').length).to eq(a.xpath('//resources/asset').length)
      expect(b.xpath('//spine/asset-clip').length).to eq(a.xpath('//spine/asset-clip').length)
      expect(b.xpath('//adjust-volume').length).to eq(a.xpath('//adjust-volume').length)
    end
  end

  context "one overlay placement" do
    it "emits an asset for the overlay source" do
      d = doc([overlay])
      assets = d.xpath('//resources/asset')
      sources = assets.map { |a| a['src'] }
      expect(sources.any? { |s| s&.include?('MVI_0323_720p.mov') }).to be(true)
    end

    it "emits the overlay clip on lane=1, attached to the spine asset-clip" do
      d = doc([overlay])
      lane_clips = d.xpath('//spine//asset-clip[@lane="1"]')
      expect(lane_clips.length).to eq(1)
      expect(lane_clips.first['name']).to include('br-0001')
    end

    it "mutes the overlay audio with -96dB" do
      d = doc([overlay])
      lane_clip = d.xpath('//spine//asset-clip[@lane="1"]').first
      vol = lane_clip.xpath('./adjust-volume').first
      expect(vol['amount']).to eq('-96dB')
    end

    it "does not emit adjust-transform for non-pip overlays" do
      d = doc([overlay])
      lane_clip = d.xpath('//spine//asset-clip[@lane="1"]').first
      expect(lane_clip.xpath('./adjust-transform')).to be_empty
    end
  end

  context "pip placement" do
    let(:pip_overlay) { overlay.merge(placement: 'pip', pip_corner: 'top_right', pip_scale: 0.25) }

    it "emits adjust-transform with scale and position" do
      d = doc([pip_overlay])
      lane_clip = d.xpath('//spine//asset-clip[@lane="1"]').first
      tr = lane_clip.xpath('./adjust-transform').first
      expect(tr).not_to be_nil
      expect(tr['scale']).to match(/\A0\.25 0\.25\z/)
      x, y = tr['position'].split(' ').map(&:to_f)
      expect(x).to be > 0
      expect(y).to be > 0
    end
  end

  context "cutaway placement" do
    let(:cutaway) { overlay.merge(placement: 'cutaway') }

    it "emits the same lane=1 attachment as overlay (per design)" do
      d = doc([cutaway])
      lane_clips = d.xpath('//spine//asset-clip[@lane="1"]')
      expect(lane_clips.length).to eq(1)
    end
  end
end
