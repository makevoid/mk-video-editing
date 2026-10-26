require "json"
require "etc"
require "tmpdir"
require_relative "shell"
require_relative "ffmpeg"
require_relative "guard"

module Media
  # Footage editing through the native Swift editor (tools/edit, `medit`): per-source analysis (stabilization path,
  # flicker tiles, exposure/color stats, Vision people boxes), subject tracks, EDL renders, review stills and sheets.
  class Edit < Shell
    PACKAGE = File.expand_path("../../tools/edit", __dir__)
    BIN = File.join(PACKAGE, ".build", "release", "medit")

    def build
      run("swift", "build", "-c", "release", "--package-path", PACKAGE)
      { path: BIN }
    end

    # One pass over a source -> analysis JSON. region: "x0,y0,x1,y1" (normalized) restricts stabilization to static scenery;
    # detect_region: stage crop where people detection runs at higher resolution (far speakers).
    def analyze(source, out, region: nil, detect_region: nil, detect_every: nil, from: nil, to: nil)
      ensure_built
      args = [source, "--out", out]
      args += ["--register-region", region] if region
      args += ["--detect-region", detect_region] if detect_region
      args += ["--detect-every", detect_every] if detect_every
      args += ["--from", from] if from
      args += ["--to", to] if to
      heavy { JSON.parse(Guard.run(BIN, "analyze", *args).lines.last) }
    end

    # Picks the speaker among the analysis' people boxes and writes a world-space track (stabilization removed;
    # space: "frame" keeps raw frame coordinates, for clips rendered with stabilize 0):
    # {"samples": [[t, x, y, w, h], ...]} normalized, top-left. seed: "x,y" normalized source point near the subject at
    # the start; stage: [ymin, ymax] band for the box center; size: [hmin, hmax] box height range; max_aspect: widest
    # width/height (in pixels) kept, which drops audience heads and shoulders in the foreground.
    def track(analysis, out, seed: nil, stage: [0.12, 0.85], size: [0.06, 0.75], max_speed: 0.6, max_aspect: 0.5, space: "world")
      a = JSON.parse(File.read(analysis))
      w, h, shift, times = a["width"].to_f, a["height"].to_f, a["shift"], a["times"]
      candidates = a["people"].map do |p|
        sx, sy = space == "frame" ? [0, 0] : shift[p["f"]]
        boxes = p["boxes"].filter_map do |x, y, bw, bh, conf|
          cy = y + bh / 2
          next unless bh.between?(*size) && cy.between?(*stage) && conf > 0.15 && bw * w <= max_aspect * bh * h
          [x - sx / w, y - sy / h, bw, bh, conf]
        end
        [p["t"], boxes]
      end
      prev = seed&.split(",")&.map(&:to_f)
      unless prev # most confident early box, preferring the frame's middle
        early = candidates.first(30).flat_map { |_, boxes| boxes }
        raise "No person found in the first detections of #{analysis}; pass SEED=x,y" if early.empty?
        best = early.max_by { |x, _y, bw, _bh, conf| conf - (x + bw / 2 - 0.5).abs }
        prev = [best[0] + best[2] / 2, best[1] + best[3] / 2]
      end
      last_t = candidates.first&.first || 0
      samples = []
      gaps = 0
      candidates.each do |t, boxes|
        reach = 0.05 + max_speed * (t - last_t)
        pick = boxes.min_by { |x, y, bw, bh, _| Math.hypot(x + bw / 2 - prev[0], (y + bh / 2 - prev[1]) * 0.6) }
        if pick && Math.hypot(pick[0] + pick[2] / 2 - prev[0], (pick[1] + pick[3] / 2 - prev[1]) * 0.6) <= reach
          samples << [t, *pick.first(4).map { |v| v.round(4) }]
          prev = [pick[0] + pick[2] / 2, pick[1] + pick[3] / 2]
          last_t = t
        else
          gaps += 1
        end
      end
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, JSON.generate({ "source" => a["source"], "analysis" => analysis, "space" => space, "samples" => samples }))
      { out: out, samples: samples.size, detections: candidates.size, gaps: gaps, span: [times.first, times.last] }
    end

    # Summary of an analysis for grading and deflicker decisions: median luma percentiles, mean color, ripple strength.
    def stats(analysis, from: nil, to: nil)
      a = JSON.parse(File.read(analysis))
      idx = a["times"].each_index.select { |i| (!from || a["times"][i] >= from) && (!to || a["times"][i] <= to) }
      med = ->(xs) { s = xs.sort; s[s.size / 2] }
      g = idx.map { |i| a["luma"][i].sum / a["luma"][i].size }
      ripple = g.each_cons(2).map { |x, y| (y - x).abs }.sum / [g.size - 1, 1].max / (g.sum / [g.size, 1].max)
      rgb = (0..2).map { |c| idx.sum { |i| a["rgb"][i][c] } / idx.size }
      { frames: idx.size, fps: a["fps"], hdr: a["hdr"],
        luma_p02: med.(idx.map { |i| a["pct"][i][0] }).round(3), luma_p50: med.(idx.map { |i| a["pct"][i][1] }).round(3),
        luma_p98: med.(idx.map { |i| a["pct"][i][2] }).round(3),
        mean_rgb_linear: rgb.map { |v| v.round(4) }, rb_ratio: (rgb[0] / rgb[2]).round(3), gb_ratio: (rgb[1] / rgb[2]).round(3),
        frame_ripple: ripple.round(4), shift_range_px: (0..1).map { |c| v = idx.map { |i| a["shift"][i][c] }; (v.max - v.min).round(1) } }
    end

    # Renders the EDL (optionally a time range). jobs > 1 renders frame-exact chunks in parallel, joins with a stream copy
    # and muxes the timeline audio once.
    def render(edl, out, from: 0.0, to: nil, audio: :edl, jobs: 1, bitrate: nil, codec: nil)
      ensure_built
      raise CommandError, "Output already exists: #{out}" if File.exist?(out)
      doc = JSON.parse(File.read(edl))
      fps = doc.fetch("fps", 30).to_f
      to ||= timeline_end(doc)
      sound = audio == :edl ? doc["audio"]&.then { |p| File.expand_path(p, File.dirname(edl)) } : audio
      first, last = (from * fps).round, (to * fps).round
      extra = []
      extra += ["--bitrate", bitrate] if bitrate
      extra += ["--codec", codec] if codec
      chunks = [jobs.to_i, MAX_JOBS, ((last - first) / (fps * 8)).floor].min
      if chunks <= 1
        args = [edl, "--out", out, "--from", first / fps, "--to", last / fps, *extra]
        args += sound ? ["--audio", sound] : ["--no-audio"]
        return heavy { JSON.parse(Guard.run(BIN, "render", *args).lines.last) }
      end
      parts = "#{out}.parts"
      FileUtils.rm_rf(parts)
      FileUtils.mkdir_p(parts)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      bounds = (0..chunks).map { |i| first + (last - first) * i / chunks }
      warn "  rendering #{last - first} frames as #{chunks} parallel chunks"
      heavy { render_chunks(bounds, edl, parts, fps, extra) }
      threads = Dir[File.join(parts, "*.mp4")].sort.map { |f| [f, nil] }
      list = File.join(parts, "list.txt")
      File.write(list, threads.map { |f, _| "file '#{File.expand_path(f)}'\n" }.join)
      joined = sound ? File.join(parts, "joined.mp4") : out
      run("ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", joined)
      if sound
        range = File.join(parts, "range.wav")
        run("ffmpeg", "-y", "-v", "error", "-ss", (first / fps).round(6), "-i", sound, "-t", ((last - first) / fps).round(6), "-ar", "48000", range)
        run("ffmpeg", "-y", "-v", "error", "-i", joined, "-i", range, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", out)
      end
      FileUtils.rm_rf(parts)
      ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      { "out" => out, "frames" => last - first, "jobs" => chunks, "ms" => ms.round, "render_fps" => ((last - first) / (ms / 1000)).round(1) }
    end

    # Fast draft of a range: half resolution, no audio processing beyond the EDL mix.
    def preview(edl, out, from:, to:, scale: 0.5, jobs: 1)
      doc = JSON.parse(File.read(edl))
      draft = "#{edl.sub(/\.json\z/, "")}.preview.json"
      doc["width"] = (doc.fetch("width", 1920) * scale / 2).round * 2
      doc["height"] = (doc.fetch("height", 1080) * scale / 2).round * 2
      File.write(draft, JSON.pretty_generate(doc))
      FileUtils.rm_f(out)
      render(draft, out, from: from, to: to, jobs: jobs, bitrate: 6_000_000)
    ensure
      FileUtils.rm_f(draft) if draft
    end

    # PNG stills at timeline times; debug adds the full source frame with crop (red), subject (green) and safe area (yellow).
    def stills(edl, dir, times, debug: false)
      ensure_built
      args = [edl, "--out", dir, "--times", times.join(",")]
      args << "--debug" if debug
      heavy { JSON.parse(Guard.run(BIN, "stills", *args).lines.last) }
    end

    def timeline_end(doc)
      return doc["duration"].to_f if doc["duration"]
      clips = doc.fetch("clips").map { |c| c["at"].to_f + (c["out"].to_f - c["in"].to_f) / c.fetch("speed", 1).to_f }
      overlays = doc.fetch("overlays", []).map { |o| o["at"].to_f + o.fetch("duration", 0).to_f }
      (clips + overlays).max
    end

    # Each medit job holds a 4K/HDR hardware decoder, GPU surfaces and ~0.4-1 GB: on a 16 GB machine several at once
    # can exhaust memory and freeze the system. A machine-wide lock serializes medit jobs across processes; parallel
    # render chunks (JOBS) are the only sanctioned concurrency and default to 1. MEDIT_LOCK=0 disables the lock.
    LOCK = File.join(Dir.tmpdir, "medit-heavy.lock")
    MAX_JOBS = [(`sysctl -n hw.memsize`.to_i / 2**30 / 12), 1].max # ~1 chunk per 12 GB RAM

    def heavy
      return yield if ENV["MEDIT_LOCK"] == "0"
      File.open(LOCK, File::CREAT | File::RDWR) do |lock|
        warn "  waiting for another medit job (#{LOCK})" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    private

    def render_chunks(bounds, edl, parts, fps, extra)
      threads = bounds.each_cons(2).with_index.map do |(a, b), i|
        file = File.join(parts, format("%03d.mp4", i))
        t = Thread.new { Guard.run(BIN, "render", edl, "--out", file, "--from", a / fps, "--to", b / fps, "--no-audio", *extra, quiet: true) }
        t.report_on_exception = false
        t
      end
      threads.each(&:value)
    end

    def ensure_built
      sources = Dir[File.join(PACKAGE, "Sources", "**", "*.swift")] + [File.join(PACKAGE, "Package.swift")] +
                Dir[File.expand_path("../../tools/graphics/Sources/MotionGraphics/*.swift", __dir__)]
      build if !File.file?(BIN) || sources.any? { |path| File.mtime(path) > File.mtime(BIN) }
    end
  end
end
