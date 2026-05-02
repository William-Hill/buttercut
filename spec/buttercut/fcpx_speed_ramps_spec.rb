require 'spec_helper'
require 'nokogiri'

RSpec.describe ButterCut::FCPX, 'speed ramps via FCPXML 1.10 timeMap' do
  let(:clip_path) { '/tmp/ramp_clip.mov' }
  let(:metadata) do
    {
      'streams' => [
        {
          'codec_type' => 'video',
          'width' => 1920,
          'height' => 1080,
          'r_frame_rate' => '30000/1001',
          'color_space' => 'bt709',
          'color_primaries' => 'bt709',
          'color_transfer' => 'bt709',
          'tags' => { 'timecode' => '00:00:00;00' }
        },
        { 'codec_type' => 'audio', 'sample_rate' => '48000' }
      ],
      'format' => { 'duration' => '10.0', 'tags' => { 'timecode' => '00:00:00;00' } }
    }
  end

  before do
    allow_any_instance_of(ButterCut::FCPX).to receive(:extract_metadata_from_ffprobe).and_return(metadata)
  end

  def parse(xml)
    Nokogiri::XML(xml)
  end

  it 'declares FCPXML version 1.10' do
    generator = ButterCut::FCPX.new([{ path: clip_path }])
    doc = parse(generator.to_xml)
    expect(doc.at_xpath('/fcpxml')['version']).to eq('1.10')
  end

  it 'omits timeMap when no speed_ramps are present' do
    generator = ButterCut::FCPX.new([{ path: clip_path, start_at: 0.0, duration: 4.0 }])
    doc = parse(generator.to_xml)
    expect(doc.xpath('//timeMap')).to be_empty
  end

  it 'emits a timeMap with timept waypoints when a clip has speed_ramps' do
    ramps = [
      { 'at' => 0.0, 'speed' => 200, 'ease' => 'ease-out' },
      { 'at' => 1.0, 'speed' => 100, 'ease' => 'ease-in' }
    ]
    generator = ButterCut::FCPX.new([
      { path: clip_path, start_at: 0.0, duration: 2.0, speed_ramps: ramps }
    ])
    doc = parse(generator.to_xml)

    time_maps = doc.xpath('//timeMap')
    expect(time_maps.length).to eq(1)

    timepts = time_maps.first.xpath('timept')
    expect(timepts.length).to be >= 2

    times = timepts.map { |t| t['time'] }
    expect(times.first).to eq('0s')

    interps = timepts.map { |t| t['interp'] }
    expect(interps).to all(satisfy { |v| %w[linear smooth2].include?(v) })

    expect(timepts.last['value']).not_to eq('0s')
  end

  it 'maps ease values to FCPXML interp keywords' do
    ramps = [
      { 'at' => 0.0, 'speed' => 100, 'ease' => 'linear' },
      { 'at' => 0.5, 'speed' => 150, 'ease' => 'ease-in-out' }
    ]
    generator = ButterCut::FCPX.new([
      { path: clip_path, start_at: 0.0, duration: 2.0, speed_ramps: ramps }
    ])
    doc = parse(generator.to_xml)
    interps = doc.xpath('//timeMap/timept').map { |t| t['interp'] }
    expect(interps).to include('linear', 'smooth2')
  end

  it 'pads with a leading 100%-baseline timept at output 0 when first ramp is mid-clip' do
    ramps = [{ 'at' => 0.5, 'speed' => 200, 'ease' => 'linear' }]
    generator = ButterCut::FCPX.new([
      { path: clip_path, start_at: 0.0, duration: 2.0, speed_ramps: ramps }
    ])
    doc = parse(generator.to_xml)
    timepts = doc.xpath('//timeMap/timept')
    expect(timepts.length).to be >= 2

    leading = timepts.first
    expect(leading['time']).to eq('0s')
    expect(leading['value']).to eq('0s')

    # The leading→first-ramp segment integrates as the average of (100%, 200%)
    # over 0.5s = 1.5x * 0.5s = 0.75s of source advance.
    second = timepts[1]
    expect(second['time']).to eq('1/2s')
    expect(second['value']).to eq('3/4s')
  end
end
