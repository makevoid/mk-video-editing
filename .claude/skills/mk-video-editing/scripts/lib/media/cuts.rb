require "json"

module Media
  # Helpers for EDL generator scripts (edit/build_edl.rb) that remove words, fillers and pauses inside a clip.
  #
  #   flow = Media::Cuts.flow("../analysis/flow/A.json")          # speech:flow output (energy, runs, words)
  #   segs = Media::Cuts.segments(inn: 2.5, out: 67.3, cuts: [[3.52, 4.77], [10.46, 12.67]], flow: flow,
  #                               beats: [[2.5, WIDE], [14.84, PUNCH, { ease: "cut" }]],
  #                               tight: ->(s) { s[:fit].to_f >= 0.5 }, contrast: ->(s) { tight ? MWIDE : MED })
  #   # => [{ in:, out:, beats:, jump: false }, { in:, out:, beats:, jump: true }, ...]
  #
  # Cut boundaries snap to the quietest 10 ms frame nearby, so a cut lands between words even inside connected
  # speech. Each segment after a jump cut starts on a framing that contrasts with the end of the previous segment
  # (wide <-> tight), the standard way to make a single-camera jump cut read as intentional, and no zoom inside a
  # segment runs faster than `min_move` seconds (see settle_moves).
  module Cuts
    module_function

    def flow(path) = JSON.parse(File.read(path))

    # Lowest-energy point (3-frame average) within +-window of t; ties go to the frame closest to t. A t already in
    # silence (outside every speech run) is kept, so trimmed pauses keep exactly the silence asked for.
    def snap(t, flow, window: 0.12)
      hop, db = flow.dig("energy", "hop"), flow.dig("energy", "db")
      return t unless db
      return t if (flow["speech_runs"] || []).none? { |a, b| t > a && t < b }
      i0 = ((t - window) / hop).floor.clamp(1, db.size - 2)
      i1 = ((t + window) / hop).ceil.clamp(1, db.size - 2)
      best = (i0..i1).min_by { |k| [(db[k - 1] + db[k] + db[k + 1]) / 3.0, (k * hop - t).abs] }
      (best * hop).round(3)
    end

    # Cuts that shorten unnatural pauses inside [inn, out] to `keep` seconds of silence (half each side). Defaults:
    # mid-phrase pauses over 0.6 s keep 0.25 s, after a comma over 0.8 s keep 0.4 s, between sentences over 1.2 s keep
    # 0.7 s. Shorter pauses are the speaker's rhythm and stay.
    PAUSES = { "phrase" => [0.6, 0.25], "comma" => [0.8, 0.4], "sentence" => [1.2, 0.7] }.freeze
    def pause_cuts(flow, inn, out, limits: PAUSES, except: [])
      # (except: times whose pause must stay, e.g. a deliberate dramatic beat)
      flow["pauses"].filter_map do |p|
        max, keep = limits.fetch(p["kind"])
        next unless p["dur"] > max && p["t0"] >= inn && p["t1"] <= out
        next if except.any? { |t| t.between?(p["t0"], p["t1"]) }
        [(p["t0"] + keep / 2).round(3), (p["t1"] - keep / 2).round(3)]
      end
    end

    # [in, out] ranges kept after removing cuts ([a, b] source seconds, snapped when a flow is given; [a, b,
    # { snap: false }] keeps both boundaries exactly as written).
    def keeps(inn, out, cuts, flow: nil, window: 0.12)
      cuts = cuts.map do |a, b, o|
        flow && o&.dig(:snap) != false ? [snap(a, flow, window: window), snap(b, flow, window: window)] : [a, b]
      end.sort
      ranges, cur = [], inn
      cuts.each do |a, b|
        next if b <= cur || a >= out
        ranges << [cur, a] if a > cur
        cur = [cur, b].max
      end
      ranges << [cur, out] if out > cur
      ranges.map { |a, b| [a.round(3), b.round(3)] }
    end

    # Words whose speech centroid (speech:flow `words`) falls inside [a, b], for logging what a cut removes.
    def text(flow, a, b)
      (flow["words"] || []).select { |w| w["center"].between?(a, b) }.map { |w| w["text"] }.join(" ")
    end

    # Camera state at source time t from beats [[t, shot, opts], ...]: the last shot at or before t, plus every
    # opts value (blur, dim...) filled forward.
    def state_at(beats, t)
      shot, opts = beats.first[1], {}
      beats.each do |bt, s, o|
        break if bt > t + 1e-6
        shot = s
        opts = opts.merge((o || {}).except(:ease))
      end
      [shot, opts]
    end

    # Keeps every eased change of shot size at least `min_move` seconds long. A cut moves the start of the next
    # eased move to the cut, so a 6 s zoom-out can shrink to a 0.1 s pop. A move that would end within `settle`
    # seconds of a jump cut opens on its shot instead (when `open_ok` allows it, i.e. it still contrasts with the
    # previous segment); other short moves are delayed to min_move after the previous key, or dropped when the
    # segment has no room for them. Moves that only change framing (same zoom/fit) are left alone.
    def settle_moves(beats, b, min_move:, settle:, open_ok: ->(_) { false })
      a = beats.first[0]
      beats.drop(1).each_with_object([beats.first]) do |(bt, shot, o), out|
        pt, ps = out.last
        next if shot == ps && o&.dig(:ease) != "cut" # no-op key (e.g. the segment already opened on this shot)
        if o&.dig(:ease) == "cut" || shot.slice(:zoom, :fit) == ps.slice(:zoom, :fit) || bt - pt >= min_move
          out << [bt, shot, o]
        elsif out.size == 1 && bt - a <= settle && open_ok.(shot)
          out[0] = [a, shot, out[0][2]]
        elsif pt + min_move <= b - 0.5
          out << [(pt + min_move).round(3), shot, o]
        end
      end
    end

    # Splits [inn, out] minus cuts into segments with rebased beats; see the module comment.
    def segments(inn:, out:, cuts:, beats:, flow: nil, tight: nil, contrast: nil, min: 0.5, lookahead: 1.0,
                 min_move: 4.5, settle: 1.5)
      ranges = keeps(inn, out, cuts, flow: flow)
      short = ranges.select { |a, b| b - a < min }
      warn "cuts: segments shorter than #{min}s: #{short.inspect}" unless short.empty?
      prev_end_shot = nil
      ranges.each_with_index.map do |(a, b), i|
        shot, opts = state_at(beats, a)
        inner = beats.select { |bt, _, _| bt > a + 1e-6 && bt < b - 1e-6 }
        # A cut beat right after a jump cut would change framing twice in a second: start on it instead.
        if i > 0 && (early = inner.find { |bt, _, o| bt < a + lookahead && o&.dig(:ease) == "cut" })
          shot = early[1]
          inner.delete(early)
        elsif i > 0 && tight && contrast && prev_end_shot && tight.(shot) == tight.(prev_end_shot)
          shot = contrast.(shot)
        end
        prev = prev_end_shot
        open_ok = ->(s) { i > 0 && (!tight || !prev || tight.(s) != tight.(prev)) }
        segment_beats = settle_moves([[a, shot, opts.merge(ease: "cut")]] + inner, b, min_move:, settle:, open_ok:)
        prev_end_shot = state_at(segment_beats, b).first
        { in: a, out: b, beats: segment_beats, jump: i > 0 }
      end
    end
  end
end
