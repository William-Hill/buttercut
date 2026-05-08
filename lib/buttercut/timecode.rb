class ButterCut
  module Timecode
    module_function

    def to_seconds(tc)
      h, m, s = tc.to_s.split(":")
      h.to_i * 3600 + m.to_i * 60 + s.to_f
    end
  end
end
