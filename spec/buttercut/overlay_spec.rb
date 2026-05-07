require 'spec_helper'
require 'buttercut/overlay'

RSpec.describe ButterCut::Overlay do
  let(:base) do
    {
      source: "/abs/broll/br-0001.mp4",
      source_id: "br-0001",
      start: 10.0,
      duration: 5.0,
      placement: "overlay"
    }
  end

  describe ".from_hash" do
    it "parses a minimal overlay" do
      o = described_class.from_hash(base)
      expect(o.source).to eq("/abs/broll/br-0001.mp4")
      expect(o.source_id).to eq("br-0001")
      expect(o.start).to eq(10.0)
      expect(o.duration).to eq(5.0)
      expect(o.placement).to eq("overlay")
      expect(o.pip?).to be(false)
    end

    it "parses pip with corner + scale" do
      o = described_class.from_hash(base.merge(placement: "pip", pip_corner: "top_right", pip_scale: 0.4))
      expect(o.pip?).to be(true)
      expect(o.pip_corner).to eq("top_right")
      expect(o.pip_scale).to eq(0.4)
    end

    it "defaults pip_corner=top_right and pip_scale=0.33 when placement is pip and fields missing" do
      o = described_class.from_hash(base.merge(placement: "pip"))
      expect(o.pip_corner).to eq("top_right")
      expect(o.pip_scale).to eq(0.33)
    end

    it "rejects placement outside the enum" do
      expect { described_class.from_hash(base.merge(placement: "weird")) }.to raise_error(ArgumentError, /placement/)
    end

    it "rejects non-positive duration" do
      expect { described_class.from_hash(base.merge(duration: 0)) }.to raise_error(ArgumentError, /duration/)
    end

    it "rejects pip fields on non-pip placement" do
      expect {
        described_class.from_hash(base.merge(pip_corner: "top_right"))
      }.to raise_error(ArgumentError, /pip_corner.*only valid.*pip/)
    end

    it "raises when source path is not absolute" do
      expect {
        described_class.from_hash(base.merge(source: "relative/path.mp4"))
      }.to raise_error(ArgumentError, /absolute/)
    end
  end

  describe "#pip_transform" do
    let(:pip) { described_class.from_hash(base.merge(placement: "pip", pip_corner: "top_right", pip_scale: 0.25)) }

    it "returns nil for non-pip overlays" do
      expect(described_class.from_hash(base).pip_transform).to be_nil
    end

    it "returns scale and a position fraction for pip" do
      t = pip.pip_transform
      expect(t[:scale]).to eq(0.25)
      # top_right with 0.25 scale: x positive, y positive (FCPXML convention: positive y = up)
      expect(t[:x]).to be > 0
      expect(t[:y]).to be > 0
      expect(t[:corner]).to eq("top_right")
    end

    it "computes opposite-sign x and y for opposite corners" do
      a = described_class.from_hash(base.merge(placement: "pip", pip_corner: "top_right", pip_scale: 0.25)).pip_transform
      b = described_class.from_hash(base.merge(placement: "pip", pip_corner: "bottom_left", pip_scale: 0.25)).pip_transform
      expect(a[:x]).to eq(-b[:x])
      expect(a[:y]).to eq(-b[:y])
    end
  end
end
