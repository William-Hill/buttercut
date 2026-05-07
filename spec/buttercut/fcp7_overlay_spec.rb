require 'spec_helper'
require 'nokogiri'
require 'buttercut'

RSpec.describe ButterCut::FCP7, "overlay emission" do
  let(:video_file_path) { File.expand_path('../fixtures/media/MVI_0323_720p.mov', __dir__) }
  let(:clips) { [{ path: video_file_path }] }
  let(:overlay) do
    {
      source: video_file_path,
      source_id: 'br-0001',
      start: 0.5,
      duration: 1.0,
      placement: 'overlay'
    }
  end

  def doc(overlays)
    xml = ButterCut.new(clips, editor: :fcp7, overlays: overlays).to_xml
    Nokogiri::XML(xml).remove_namespaces!
  end

  context "no overlays" do
    it "still emits exactly one video <track> and one audio <track>" do
      d = doc([])
      expect(d.xpath('//media/video/track').length).to eq(1)
      expect(d.xpath('//media/audio/track').length).to eq(1)
    end
  end

  context "one overlay" do
    it "emits a second video track containing the overlay clipitem" do
      d = doc([overlay])
      tracks = d.xpath('//media/video/track')
      expect(tracks.length).to eq(2)
      v2 = tracks[1]
      items = v2.xpath('./clipitem')
      expect(items.length).to eq(1)
      expect(items.first.xpath('./name').text).to include('br-0001')
    end

    it "places the clipitem at frame-aligned start and end on V2" do
      d = doc([overlay])
      v2 = d.xpath('//media/video/track')[1]
      item = v2.xpath('./clipitem').first
      start_frame = item.xpath('./start').text.to_i
      end_frame   = item.xpath('./end').text.to_i
      expect(end_frame).to be > start_frame
      expect(start_frame).to be >= 0
    end

    it "emits no <filter> for non-pip overlays" do
      d = doc([overlay])
      v2 = d.xpath('//media/video/track')[1]
      item = v2.xpath('./clipitem').first
      expect(item.xpath('./filter')).to be_empty
    end
  end

  context "pip overlay" do
    let(:pip_overlay) { overlay.merge(placement: 'pip', pip_corner: 'top_right', pip_scale: 0.25) }

    it "emits a Motion Basic Motion filter with Scale parameter" do
      d = doc([pip_overlay])
      v2 = d.xpath('//media/video/track')[1]
      item = v2.xpath('./clipitem').first
      filter_names = item.xpath('./filter/effect/name').map(&:text)
      expect(filter_names).to include('Basic Motion')
      scale_param = item.xpath('./filter/effect/parameter[name="Scale"]/value').first
      expect(scale_param).not_to be_nil
      expect(scale_param.text.to_f).to be_within(0.01).of(25.0) # FCP7 Scale 0..100
    end

    it "inverts y between FCPXML and FCP7 (top_right => positive horiz, negative vert)" do
      d = doc([pip_overlay])
      v2 = d.xpath('//media/video/track')[1]
      item = v2.xpath('./clipitem').first
      center = item.xpath('./filter/effect/parameter[name="Center"]/value').first
      expect(center).not_to be_nil
      horiz = center.xpath('./horiz').text.to_f
      vert  = center.xpath('./vert').text.to_f
      expect(horiz).to be > 0
      expect(vert).to be < 0
    end
  end
end
