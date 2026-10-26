require_relative "../workflow/approval"
require_relative "../workflow/waves"
require_relative "../workflow/journal"
require_relative "fonts"
module Toolkit
  class Operations
    TASKS = {
      "doctor" => "Check local tools; STRICT=1 fails on missing prerequisites",
      "setup" => "Install gems and a local Python venv; build the Swift tools (mgraphics, mvfx, medit)",
      "fonts:list" => "List installed macOS TTF/OTF files, including Supplemental fonts (local)",
      "fonts:copy" => "Copy selected fonts into this video project: [selection.json] (local)",
      "openapi:fetch" => "Fetch current Fal audio input schemas (no generation)",
      "openapi:summary" => "Print saved Fal schema summaries",
      "plan:approve" => "Record actual user approval: NOTE='approved wording'",
      "work:next" => "Allocate/resume next dependency-ready wave; SIZE=2/3..4/4..8/6..10",
      "work:accept" => "Accept reviewed job: JOB=id EVIDENCE=review.md",
      "work:log" => "Append worker progress: AGENT=id EVENT=event MESSAGE=text; LOG_DIR optional",
      "work:watch" => "Show recent worker log entries; LOG_DIR and LIMIT optional",
      "anim:render" => "Render a JSON scene to PNG frames: [scene.json,out,frames,width,height] (local)",
      "graphics:build" => "Build native Swift drawing/composition renderer (macOS 14+)",
      "graphics:render" => "Native scene: [scene.json,out_dir_or_movie,frames,width,height,fps]; PLATE/AUDIO/CODEC/SUPERSAMPLE/BITRATE/GLOW (gpu default, cg)/JOBS (parallel chunks, default 1) optional",
      "graphics:preview" => "Fast draft for iterating: [scene.json,out.mp4,from_s,to_s] at 1x, 30 fps (FPS/SUPERSAMPLE/AUDIO/JOBS/WIDTH/HEIGHT/GLOW optional); finals use graphics:render",
      "graphics:benchmark" => "Measure native scene: [scene.json,frames,width,height,fps] (FROM first frame, SUPERSAMPLE), no files written",
      "audio:analyze" => "Beats and energy of a music track or any audio/video: [audio,out_dir] → beats.json, energy.json (local)",
      "audio:transcribe_local" => "Local mlx-whisper word timestamps: [audio,out.json,from,seconds] (Apple Silicon, uv; free)",
      "media:stems_local" => "Local Demucs vocals/no_vocals/drums/bass/other: [audio,out_dir,from,seconds] (uv; free, full-song aligned)",
      "media:probe" => "Probe [path]",
      "media:sheet" => "Contact sheet [video,out.jpg]",
      "media:frames" => "Dense reference analysis [video,out_dir,fps,width]",
      "media:frame" => "Extract [video,seconds,out.png]",
      "media:cut" => "Cut reference video [video,out.mp4,start,seconds]",
      "media:cuts" => "Detect picture cuts [video,out.json] (Python)",
      "media:audio_cut" => "Cut audio [source,out.wav,start,seconds]",
      "media:montage" => "Labeled review sheet of images [out.jpg,columns,width,img1,img2,...] (local)",
      "media:concat" => "Concatenate unrelated clips [out.mp4,a.mp4,b.mp4,...]",
      "media:mux" => "Replace audio [video,audio,out.mp4]",
      "media:youtube" => "4K delivery [video,out.mp4] (local encode only)",
      "media:twitter" => "X/Twitter upload encode for any video [video,out.mp4]: fit 16:9/9:16/1:1 box, <=60 fps, H.264 High yuv420p BT.709, closed 1 s GOPs, AAC-LC, faststart; CRF (16), MAX_MBPS (24, X max 25), TUNE (e.g. animation) optional; reports free/Premium fit",
      "media:faststart" => "Lossless upload copy [video,out.mp4]: streams copied, moov moved to the front (no re-encode)",
      "vfx:build" => "Build Swift Core Image renderer (macOS)",
      "vfx:analyze" => "Analyze VFX source beats and cuts; VFX=name",
      "vfx:stills" => "Preview cued VFX frames [0,24,...]; VFX=name",
      "vfx:clip" => "Render VFX interval [from_frame,to_frame]; VFX=name",
      "vfx:render" => "Render complete VFX version; VFX=name, JOBS parallel chunks (default 1)",
      "sfx:gen" => "Synthesize/cache the sounds of an SFX cue sheet (synth:/tone: free; prompt: Stable Audio via Fal, paid); SFX=name",
      "sfx:mix" => "Mix cued SFX onto a rendered video (local); SFX=name",
      "test" => "Run RSpec suite; PROFILE=all|core|media|swift",
      "edit:build" => "Build the native Swift footage editor medit (macOS 14+)",
      "edit:analyze" => "Analyze a source: [source,out.json] stabilization path, flicker tiles, color stats, Vision people; REGION=x0,y0,x1,y1 (stabilization) DETECT_REGION=x0,y0,x1,y1 (stage crop for small speakers) DETECT_EVERY=0.1 FROM/TO optional",
      "edit:track" => "Speaker track from an analysis: [analysis.json,out.json] SEED=x,y STAGE=ymin,ymax SIZE=hmin,hmax optional; SPACE=frame for clips rendered with stabilize 0",
      "edit:stats" => "Exposure/color/flicker summary of an analysis: [analysis.json,from,to]",
      "edit:transcribe" => "Local word transcript of every source: [out_dir,source...] (mlx-whisper; free); VERBATIM=1 keeps fillers (um, uh) for speech:flow",
      "edit:stills" => "Review stills of an EDL: [edl.json,out_dir,t1,t2,...]; DEBUG=1 adds crop/subject overlays on the full frame",
      "edit:sheet" => "Contact sheet of EDL stills: [edl.json,out.jpg,every_s] (labelled timeline times)",
      "edit:preview" => "Half-res draft of an EDL range: [edl.json,out.mp4,from_s,to_s]; SCALE=0.5 JOBS",
      "edit:render" => "Final render of an EDL: [edl.json,out.mp4]; FROM/TO, JOBS (parallel chunks, default 1, capped ~1 per 12 GB RAM), BITRATE, CODEC=h264|hevc",
      "speech:clean" => "Clean dialogue: [in,out.wav] PRESET=room|light|<ffmpeg chain>, ISOLATE=1 (local Demucs vocals), AMBIENCE=0.12",
      "speech:measure" => "Loudness/noise of audio: [path...]",
      "speech:flow" => "Fillers, hums, repeats, false starts, unnatural pauses with proposed cuts: [transcript.json,audio.wav,out.json] (+ out.txt)",
      "speech:mix" => "Timeline audio of an EDL (clips, sounds, ducked music) normalized: [edl.json,out.wav]; LUFS=-16 TP=-1.5",
      "speech:loudnorm" => "Two-pass loudness normalization: [in,out.wav]; LUFS=-16 TP=-1.5",
      "voice:tts" => "Narration line with Fal ElevenLabs (paid; explicit request only): [text_file,out.mp3]; VOICE=Brian SPEED STABILITY STYLE; MODEL=v4 for Eleven v4",
      "music:score" => "Instrumental background score with Fal ElevenLabs Music v2.5 (paid; explicit request only): [prompt_file,out.mp3,seconds]"
    }.freeze
    # Disfluent prompt: Whisper imitates its style and writes the fillers it normally drops.
    VERBATIM_PROMPT = "Umm, so, uh, we- we built, um, this thing. Uh, I mean, like, hmm, you know, it's, uh, it's good."
    def ff = @ff ||= Media::FFmpeg.new
    def py = @py ||= Media::Python.new
    def emit(value) = puts(JSON.pretty_generate(value))
    def endpoints = Fal::Models.constants.filter_map { |c| k = Fal::Models.const_get(c); k.endpoint if k.respond_to?(:endpoint) && k != Fal::Models::Base }.uniq
    def required(args, n)
      raise ArgumentError, "Need #{n} arguments; see ruby scripts/mv.rb --help or rake -T" if args.size < n
      args
    end
    def call(name, a)
      case name
      when "doctor" then doctor
      when "setup" then setup
      when "fonts:list" then emit Fonts.new.list
      when "fonts:copy" then required(a, 1); emit Fonts.new.copy(a[0])
      when "openapi:fetch" then endpoints.each { |id| Fal::OpenAPI.fetch(id); warn "fetched #{id}" }
      when "openapi:summary" then endpoints.each { |id| puts Fal::OpenAPI.load(id).summary if File.file?(Fal::OpenAPI.spec_path(id)) }
      when "plan:approve" then emit Workflow::Approval.new.record!(ENV["NOTE"])
      when "work:next" then Workflow::Approval.new.check!; emit Workflow::Waves.new.next!(ENV["SIZE"])
      when "work:accept" then emit Workflow::Waves.new.accept!(ENV.fetch("JOB"), ENV["EVIDENCE"])
      when "work:log" then emit Workflow::Journal.new.append(agent: ENV["AGENT"], event: ENV["EVENT"], message: ENV["MESSAGE"], artifact: ENV["ARTIFACT"], request_id: ENV["REQUEST_ID"])
      when "work:watch" then emit Workflow::Journal.new.snapshot(limit: Integer(ENV.fetch("LIMIT", "5")))
      when "anim:render"
        required(a, 3); emit Media::Anim.new.render(a[0], a[1], frames: Integer(a[2]), width: Integer(a[3] || 1920), height: Integer(a[4] || 1080), fps: 24)
      when "graphics:build" then emit Media::Graphics.new.build
      when "graphics:render"
        required(a, 3)
        emit Media::Graphics.new.render(a[0], a[1], frames: Integer(a[2]), width: Integer(a[3] || 1920), height: Integer(a[4] || 1080), fps: Float(a[5] || 24),
          plate: ENV["PLATE"], audio: ENV["AUDIO"], codec: ENV["CODEC"], only: ENV["ONLY"]&.split(",")&.map { |v| Integer(v) },
          supersample: ENV["SUPERSAMPLE"]&.then { |v| Integer(v) }, bitrate: ENV["BITRATE"]&.then { |v| Integer(v) }, glow: ENV["GLOW"],
          jobs: Integer(ENV["JOBS"] || 1))
      when "graphics:preview"
        required(a, 4)
        emit Media::Graphics.new.preview(a[0], a[1], from: Float(a[2]), to: Float(a[3]), fps: Float(ENV["FPS"] || 30),
          width: Integer(ENV["WIDTH"] || 1920), height: Integer(ENV["HEIGHT"] || 1080), supersample: Integer(ENV["SUPERSAMPLE"] || 1), audio: ENV["AUDIO"], glow: ENV["GLOW"],
          jobs: Integer(ENV["JOBS"] || 1))
      when "graphics:benchmark"
        required(a, 2)
        emit Media::Graphics.new.render(a[0], "", frames: Integer(a[1]), width: Integer(a[2] || 1920), height: Integer(a[3] || 1080), fps: Float(a[4] || 24), benchmark: true,
          from: Integer(ENV["FROM"] || 0), supersample: ENV["SUPERSAMPLE"]&.then { |v| Integer(v) }, glow: ENV["GLOW"])
      when "audio:analyze" then required(a, 2); analyze_audio(*a)
      when "audio:transcribe_local"
        required(a, 2); result = py.transcribe_local(a[0], from: Float(a[2] || 0), seconds: Float(a[3] || 0))
        FileUtils.mkdir_p(File.dirname(a[1])); File.write(a[1], JSON.pretty_generate(result)); emit(path: a[1], words: result["chunks"].size, text: result["text"])
      when "media:stems_local" then required(a, 2); emit py.stems_local(a[0], a[1], from: Float(a[2] || 0), seconds: Float(a[3] || 0))
      when "media:probe" then required(a, 1); emit ff.summary(a[0])
      when "media:sheet" then required(a, 2); emit ff.contact_sheet(*a)
      when "media:frames" then required(a, 2); emit ff.extract_frames(a[0], a[1], fps: Float(a[2] || 12), width: Integer(a[3] || 480))
      when "media:frame" then required(a, 3); emit ff.frame_at(a[0], Float(a[1]), a[2])
      when "media:cut"
        required(a, 4); ff.run("ffmpeg", "-y", "-v", "error", "-ss", a[2], "-i", a[0], "-t", a[3], "-c:v", "libx264", "-c:a", "aac", a[1]); emit(path: a[1])
      when "media:cuts"
        required(a, 2); result = py.call("cuts.py", a[0]); FileUtils.mkdir_p(File.dirname(a[1])); File.write(a[1], JSON.pretty_generate(result)); emit(path: a[1], cuts: result["cuts"])
      when "media:audio_cut" then required(a, 4); emit ff.extract_audio(a[0], a[1], from: Float(a[2]), seconds: Float(a[3]))
      when "media:montage"
        required(a, 4); cols = Integer(a[1]); imgs = a.drop(3); FileUtils.mkdir_p(File.dirname(a[0]))
        emit Media::ImageMagick.new.board(imgs.map { |i| [i, File.basename(i, ".*")] }, a[0], tile: "#{cols}x", width: Integer(a[2]))
      when "media:concat" then required(a, 2); emit ff.concat_videos(a.drop(1), a[0])
      when "media:mux" then required(a, 3); emit ff.mux(*a, shortest: false)
      when "media:youtube" then required(a, 2); emit ff.youtube_4k(*a)
      when "media:twitter"
        required(a, 2)
        emit ff.twitter(*a, crf: Float(ENV["CRF"] || 16), max_mbps: Float(ENV["MAX_MBPS"] || 24), tune: ENV["TUNE"])
      when "media:faststart" then required(a, 2); emit ff.faststart(*a)
      when "vfx:build" then emit Media::Vfx.new.build
      when "vfx:analyze" then emit Media::Vfx.new.analyze
      when "vfx:stills" then required(a, 1); emit Media::Vfx.new.stills(a.map { |x| Integer(x) })
      when "vfx:clip" then required(a, 2); emit Media::Vfx.new.clip(*a.map { |x| Integer(x) })
      when "vfx:render" then emit Media::Vfx.new.render
      when "sfx:gen" then emit Media::Sfx.new.generate(only: ENV["ONLY"]&.split(","), force: ENV["FORCE"] == "1")
      when "sfx:mix" then emit Media::Sfx.new.mix
      when "test" then require_relative "test_runner"; TestRunner.new.run
      when "edit:build" then emit Media::Edit.new.build
      when "edit:analyze"
        required(a, 2); emit Media::Edit.new.analyze(a[0], a[1], region: ENV["REGION"], detect_region: ENV["DETECT_REGION"], detect_every: ENV["DETECT_EVERY"], from: ENV["FROM"], to: ENV["TO"])
      when "edit:track"
        required(a, 2)
        pair = ->(k, d) { ENV[k]&.split(",")&.map { |v| Float(v) } || d }
        emit Media::Edit.new.track(a[0], a[1], seed: ENV["SEED"], stage: pair.("STAGE", [0.12, 0.85]), size: pair.("SIZE", [0.06, 0.75]),
                                         space: ENV["SPACE"] || "world")
      when "edit:stats" then required(a, 1); emit Media::Edit.new.stats(a[0], from: a[1]&.then { |v| Float(v) }, to: a[2]&.then { |v| Float(v) })
      when "edit:transcribe"
        required(a, 2); FileUtils.mkdir_p(a[0])
        emit(a.drop(1).map do |src|
          wav = File.join(a[0], "#{File.basename(src, ".*")}.wav")
          ff.run("ffmpeg", "-y", "-v", "error", "-i", src, "-vn", "-ac", "1", "-ar", "16000", wav)
          result = py.transcribe_local(wav, language: ENV["MV_WHISPER_LANG"] || "en", prompt: ENV["VERBATIM"] == "1" ? VERBATIM_PROMPT : "")
          json = File.join(a[0], "#{File.basename(src, ".*")}.json")
          File.write(json, JSON.pretty_generate(result)); FileUtils.rm_f(wav)
          { source: src, transcript: json, words: result["chunks"].size, text: result["text"] }
        end)
      when "edit:stills"
        required(a, 3); emit Media::Edit.new.stills(a[0], a[1], a.drop(2).map { |v| Float(v) }, debug: ENV["DEBUG"] == "1")
      when "edit:sheet"
        required(a, 2); edit = Media::Edit.new; every = Float(a[2] || 10)
        doc = JSON.parse(File.read(a[0])); times = (0...(edit.timeline_end(doc) / every).ceil).map { |i| (i * every + 0.5).round(3) }
        dir = "#{a[1]}.stills"; FileUtils.rm_rf(dir)
        files = edit.stills(a[0], dir, times)["files"]
        emit Media::ImageMagick.new.board(files.map { |f| [f, format("%.1fs", File.basename(f, ".png").to_f)] }, a[1], tile: "6x", width: 320)
      when "edit:preview"
        required(a, 4); emit Media::Edit.new.preview(a[0], a[1], from: Float(a[2]), to: Float(a[3]), scale: Float(ENV["SCALE"] || 0.5), jobs: Integer(ENV["JOBS"] || 1))
      when "edit:render"
        required(a, 2)
        emit Media::Edit.new.render(a[0], a[1], from: Float(ENV["FROM"] || 0), to: ENV["TO"]&.then { |v| Float(v) }, jobs: Integer(ENV["JOBS"] || 1),
          bitrate: ENV["BITRATE"]&.then { |v| Integer(v) }, codec: ENV["CODEC"])
      when "speech:clean"
        required(a, 2); emit Media::Speech.new.clean(a[0], a[1], preset: ENV["PRESET"] || "room", isolate: ENV["ISOLATE"] == "1", ambience: Float(ENV["AMBIENCE"] || 0.12))
      when "speech:flow" then required(a, 3); emit py.speech_flow(a[0], a[1], a[2])
      when "speech:measure" then required(a, 1); emit(a.to_h { |p| [p, Media::Speech.new.measure(p)] })
      when "speech:mix" then required(a, 2); emit Media::Speech.new.mix(a[0], a[1], lufs: Float(ENV["LUFS"] || -16), tp: Float(ENV["TP"] || -1.5))
      when "speech:loudnorm" then required(a, 2); emit Media::Speech.new.loudnorm(a[0], a[1], lufs: Float(ENV["LUFS"] || -16), tp: Float(ENV["TP"] || -1.5))
      when "voice:tts"
        required(a, 2); c = Fal::Client.new
        opts = { voice: ENV["VOICE"], speed: ENV["SPEED"]&.then { |v| Float(v) }, stability: ENV["STABILITY"]&.then { |v| Float(v) }, style: ENV["STYLE"]&.then { |v| Float(v) } }.compact
        if ENV["MODEL"] == "v4"
          opts = opts.slice(:voice, :stability)
          result = Fal::Models::ElevenV4Tts.new(client: c).speak(text: File.read(a[0]).strip, **opts)
        else
          result = Fal::Models::ElevenTts.new(client: c).speak(text: File.read(a[0]).strip, **opts)
        end
        c.download(result.output.fetch("audio").fetch("url"), a[1])
        emit(path: a[1], request_id: result.request_id, duration: ff.duration(a[1]))
      when "music:score"
        required(a, 3); c = Fal::Client.new
        result = Fal::Models::ElevenMusic.new(client: c).compose(prompt: File.read(a[0]).strip, seconds: Float(a[2]))
        c.download(result.output.fetch("audio").fetch("url"), a[1])
        emit(path: a[1], request_id: result.request_id, duration: ff.duration(a[1]))
      else raise ArgumentError, "Unknown task #{name}"
      end
    end
    def analyze_audio(source, out)
      FileUtils.mkdir_p(out)
      wav = ff.extract_audio(source, File.join(out, "song.wav"))
      beats = py.call("beats.py", wav, "24")
      energy = py.audio_energy(wav)
      File.write(File.join(out, "beats.json"), JSON.pretty_generate(beats))
      File.write(File.join(out, "energy.json"), JSON.pretty_generate(energy))
      emit(duration: ff.duration(wav), bpm: beats["bpm"], beats: File.join(out, "beats.json"), energy: File.join(out, "energy.json"))
    end
    def doctor
      bins = %w[ffmpeg ffprobe magick python3 swift uv]
      checks = bins.to_h { |b| [b, Media::Shell.available?(b)] }
      checks["ruby_3_2"] = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2")
      checks["apple_silicon"] = RbConfig::CONFIG["host_cpu"].to_s.match?(/arm|aarch64/) # mlx-whisper transcription
      checks["python_packages"] = system(py.executable, "-c", "import PIL, numpy", out: File::NULL, err: File::NULL)
      emit checks
      emit(native_tools: { medit: File.file?(Media::Edit::BIN), mgraphics: File.file?(Media::Graphics::BIN), mvfx: File.file?(Media::Vfx::BIN) },
           next: "run setup to build missing native tools") unless [Media::Edit::BIN, Media::Graphics::BIN, Media::Vfx::BIN].all? { |b| File.file?(b) }
      raise "Missing prerequisites; see the README requirements (brew bundle) and run setup" if ENV["STRICT"] == "1" && checks.values.any? { |v| !v }
    end
    def setup
      shell = Media::Shell.new
      shell.run(RbConfig.ruby, "-S", "bundle", "install")
      shell.run("python3", "-m", "venv", ".venv") unless File.directory?(".venv")
      shell.run(File.expand_path(".venv/bin/python3"), "-m", "pip", "install", "-r", "requirements.txt")
      Media::Graphics.new.build
      Media::Vfx.new.build
      Media::Edit.new.build
      doctor
    end
  end
end
