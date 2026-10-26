require_relative "spec_helper"
require_relative "../lib/media/cuts"

RSpec.describe Media::Cuts, :core do
  # 0-2 s speech, 2-3 s silence, 3-5 s speech with a quiet dip at 4.0 s.
  let(:flow) do
    db = Array.new(500) { |i| i.between?(200, 299) ? -50.0 : -20.0 }
    (398..402).each { |i| db[i] = -35.0 }
    { "energy" => { "hop" => 0.01, "db" => db }, "speech_runs" => [[0.0, 2.0], [3.0, 5.0]],
      "pauses" => [{ "t0" => 2.0, "t1" => 3.0, "dur" => 1.0, "kind" => "phrase" }],
      "words" => [{ "text" => "hello", "center" => 1.0 }, { "text" => "um,", "center" => 3.5 }] }
  end

  it "snaps boundaries inside speech to the quietest point and leaves silence alone" do
    expect(described_class.snap(4.08, flow)).to be_within(0.011).of(4.0)
    expect(described_class.snap(2.4, flow)).to eq(2.4)
  end

  it "shortens unnatural pauses to the kept silence" do
    expect(described_class.pause_cuts(flow, 0, 5)).to eq([[2.125, 2.875]])
    expect(described_class.pause_cuts(flow, 0, 5, except: [2.5])).to eq([])
  end

  it "keeps ranges around overlapping cuts and honours snap: false" do
    expect(described_class.keeps(0, 5, [[1.0, 2.5], [2.0, 3.2]])).to eq([[0, 1.0], [3.2, 5]])
    expect(described_class.keeps(0, 5, [[3.3, 4.08, { snap: false }]], flow: flow)).to eq([[0, 3.3], [4.08, 5]])
    expect(described_class.keeps(0, 5, [[3.3, 4.08]], flow: flow).last.first).to be_within(0.011).of(4.0)
  end

  it "splits into jump-cut segments that open on a contrasting framing" do
    wide, tight = { zoom: 1.3 }, { fit: 0.72 }
    segs = described_class.segments(inn: 0, out: 5, cuts: [[2.2, 2.8]], beats: [[0, wide]], flow: flow,
                                    tight: ->(s) { s[:fit].to_f >= 0.5 }, contrast: ->(s) { s[:fit] ? wide : tight })
    expect(segs.map { |s| [s[:in], s[:out], s[:jump]] }).to eq([[0, 2.2, false], [2.8, 5, true]])
    expect(segs.last[:beats].first[1]).to eq(tight)
    expect(described_class.text(flow, 3.0, 4.0)).to eq("um,")
  end

  it "never squeezes a zoom after a cut into a pop" do
    wide, med = { zoom: 1.4 }, { fit: 0.56 }
    tight = ->(s) { s[:fit].to_f >= 0.5 }
    # Zoom-out 0.12 s after a jump cut, and the previous segment ended tight: open on the wide instead.
    segs = described_class.segments(inn: 0, out: 10, cuts: [[2.0, 2.5]], beats: [[0, med], [2.62, wide]],
                                    tight:, contrast: ->(s) { tight.(s) ? wide : med })
    expect(segs.last[:beats].map { |t, s, _| [t, s] }).to eq([[2.5, wide]])
    # Zoom-out 1.1 s into the first segment: delayed to a 4.5 s move.
    beats = described_class.settle_moves([[0, med, { ease: "cut" }], [1.1, wide, { ease: "smooth" }]], 10,
                                         min_move: 4.5, settle: 1.5)
    expect(beats.map(&:first)).to eq([0, 4.5])
  end
end
