require "json"
require_relative "shell"
require_relative "python"

module Media
  # Dialogue audio for footage edits: cleanup of phone/camera recordings, two-pass EBU R128 loudness, the timeline mix
  # (clip audio, narration, music with ducking) from an EDL, and measurements for review.
  class Speech < Shell
    # Cleanup presets (ffmpeg filter chains), applied to a mono fold-down.
    #   room:  far-mic talk in a hall/PA (phone in the audience): rumble cut, FFT denoise, mud cut, presence, de-ess, leveler
    #   light: decent mic, just tone + leveling
    PRESETS = {
      "room" => "highpass=f=90,lowpass=f=12500,afftdn=nr=12:nf=-44:tn=1,equalizer=f=280:t=q:w=1.1:g=-3.5," \
                "equalizer=f=3000:t=q:w=1.0:g=2.5,equalizer=f=9500:t=h:w=0.7:g=1.0,deesser=i=0.35," \
                "agate=threshold=0.025:ratio=1.6:range=0.45:attack=6:release=220:knee=3,acompressor=threshold=0.07:ratio=3:attack=8:release=220:makeup=2.5:knee=4",
      "light" => "highpass=f=70,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3500:t=q:w=1:g=1.5," \
                 "acompressor=threshold=0.1:ratio=2.5:attack=10:release=250:makeup=2"
    }.freeze

    # Cleaned mono speech at 48 kHz. isolate: run local Demucs first and keep its vocal stem (removes crowd, music beds and
    # hum; mix back `ambience` (0..1) of the original for a natural room).
    def clean(input, out, preset: "room", isolate: false, ambience: 0.12)
      FileUtils.mkdir_p(File.dirname(out))
      chain = PRESETS.fetch(preset) { preset } # a custom ffmpeg chain is accepted too
      source = input
      if isolate
        stems = File.join(File.dirname(out), "stems", File.basename(out, ".*"))
        Python.new.stems_local(input, stems) unless File.file?(File.join(stems, "vocals.wav"))
        source = File.join(File.dirname(out), "#{File.basename(out, ".*")}.isolated.wav")
        run("ffmpeg", "-y", "-v", "error", "-i", File.join(stems, "vocals.wav"), "-i", input, "-filter_complex",
            "[0:a]pan=mono|c0=0.5*c0+0.5*c1[v];[1:a]pan=mono|c0=0.5*c0+0.5*c1,volume=#{ambience}[r];[v][r]amix=inputs=2:normalize=0[a]",
            "-map", "[a]", "-ar", "48000", source)
      end
      run("ffmpeg", "-y", "-v", "error", "-i", source, "-af", "pan=mono|c0=0.5*c0+0.5*c1,#{chain}", "-ar", "48000", "-c:a", "pcm_s24le", out)
      { out: out, preset: preset, isolate: isolate }.merge(measure(out))
    end

    # Integrated loudness, true peak, LRA and the noise floor/RMS.
    def measure(path)
      err = run_err("ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "loudnorm=print_format=json", "-f", "null", "-")
      j = loudnorm_json(err)
      st = run_err("ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "astats=metadata=0:measure_overall=Noise_floor+RMS_level", "-f", "null", "-")
      { lufs: j["input_i"].to_f, true_peak: j["input_tp"].to_f, lra: j["input_lra"].to_f,
        noise_floor_db: st.scan(/Noise floor dB: (-?[\d.]+)/).flatten.last.to_f, rms_db: st.scan(/RMS level dB: (-?[\d.]+)/).flatten.last.to_f }
    end

    # Two-pass loudnorm (linear gain when possible) to `lufs` / `tp`, 48 kHz.
    def loudnorm(input, out, lufs: -16, tp: -1.5, lra: 11, channels: 2)
      err = run_err("ffmpeg", "-hide_banner", "-nostats", "-i", input, "-af", "loudnorm=I=#{lufs}:TP=#{tp}:LRA=#{lra}:print_format=json", "-f", "null", "-")
      m = loudnorm_json(err)
      filter = "loudnorm=I=#{lufs}:TP=#{tp}:LRA=#{lra}:measured_I=#{m["input_i"]}:measured_TP=#{m["input_tp"]}:measured_LRA=#{m["input_lra"]}:" \
               "measured_thresh=#{m["input_thresh"]}:offset=#{m["target_offset"]}:linear=true"
      run("ffmpeg", "-y", "-v", "error", "-i", input, "-af", filter, "-ar", "48000", "-ac", channels.to_s, "-c:a", "pcm_s24le", out)
      { out: out }.merge(measure(out))
    end

    # Timeline audio for an EDL -> loudness-normalized stereo WAV.
    # Clip audio comes from clip["audio"] (default: the clip source), trimmed to in/out, placed at `at`, with fades over the
    # clip's dissolve (`transition`) or 60 ms; clip["audio_xfade"] (seconds) overrides the audio crossfade into that clip
    # (a 0.6 s picture dissolve with a 0.15 s audio crossfade keeps the last word before it intact). clip["audio_gain_db"] and clip["audio_duck"] = [[t0, t1, db], ...]
    # (clip-local seconds) shape it. doc["sounds"]: [{source, at, gain_db, fade_in, fade_out}] (narration, SFX) on top.
    # doc["music"]: [{source, at, from, duration, gain_db, duck_db, fade_in, fade_out}] ducks under clip speech and sounds.
    def mix(edl, out, lufs: -16, tp: -1.5)
      doc = JSON.parse(File.read(edl))
      base = File.dirname(edl)
      abs = ->(p) { File.expand_path(p, base) }
      inputs, filters, labels = [], [], []
      doc.fetch("clips").each_with_index do |c, i|
        next if c["mute"] # picture only (music/narration carry the sound)
        src = abs.(c["audio"] || c["source"])
        speed = c.fetch("speed", 1).to_f
        dur = (c["out"].to_f - c["in"].to_f) / speed # timeline seconds
        fin = c["audio_xfade"]&.to_f || [c.fetch("transition", 0).to_f, 0.06].max
        nxt = doc["clips"][i + 1]
        fout = nxt&.dig("audio_xfade")&.to_f || [nxt&.dig("transition").to_f, 0.06].max
        inputs << src
        chain = "[#{inputs.size - 1}:a]atrim=start=#{c["in"]}:duration=#{(dur * speed).round(4)},asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo"
        chain += ",atempo=#{speed}" if speed != 1
        chain += ",volume=#{c["audio_gain_db"]}dB" if c["audio_gain_db"]
        Array(c["audio_duck"]).each do |t0, t1, db, ramp| # smooth ramps (default 0.5 s) into and out of the dip
          r = (ramp || 0.5).to_f
          chain += ",volume=eval=frame:volume='pow(10,(#{db})*min(1,max(0,(t-(#{t0}))/#{r}))*min(1,max(0,((#{t1})-t)/#{r}))/20)'"
        end
        chain += ",afade=t=in:d=#{fin},afade=t=out:st=#{(dur - fout).round(4)}:d=#{fout},adelay=#{(c["at"].to_f * 1000).round}:all=1[c#{i}]"
        filters << chain
        labels << "[c#{i}]"
      end
      voice = labels.dup
      Array(doc["sounds"]).each_with_index do |s, i|
        inputs << abs.(s["source"])
        chain = "[#{inputs.size - 1}:a]aformat=sample_rates=48000:channel_layouts=stereo,volume=#{s.fetch("gain_db", 0)}dB"
        chain += ",afade=t=in:d=#{s["fade_in"]}" if s["fade_in"]
        chain += ",areverse,afade=t=in:d=#{s["fade_out"]},areverse" if s["fade_out"]
        chain += ",adelay=#{(s["at"].to_f * 1000).round}:all=1[s#{i}]"
        filters << chain
        labels << "[s#{i}]"
        voice << "[s#{i}]"
      end
      music = Array(doc["music"])
      unless music.empty?
        # The sidechain key is padded with silence: sidechaincompress stops at its shorter input, which would cut a
        # music tail that runs past the last word.
        filters << "#{voice.join}amix=inputs=#{voice.size}:normalize=0:duration=longest,asplit=2[vox][key0]"
        filters << "[key0]apad[key]"
        music.each_with_index do |m, i|
          inputs << abs.(m["source"])
          chain = "[#{inputs.size - 1}:a]atrim=start=#{m.fetch("from", 0)}#{m["duration"] ? ":duration=#{m["duration"]}" : ""},asetpts=PTS-STARTPTS," \
                  "aformat=sample_rates=48000:channel_layouts=stereo,volume=#{m.fetch("gain_db", -18)}dB"
          chain += ",afade=t=in:d=#{m["fade_in"]}" if m["fade_in"]
          chain += ",areverse,afade=t=in:d=#{m["fade_out"]},areverse" if m["fade_out"]
          chain += ",adelay=#{(m["at"].to_f * 1000).round}:all=1[m#{i}]"
          filters << chain
        end
        filters << "#{music.each_index.map { |i| "[m#{i}]" }.join}amix=inputs=#{music.size}:normalize=0:duration=longest[mus]"
        ratio = 10**(music.first.fetch("duck_db", -10).to_f.abs / 20.0)
        filters << "[mus][key]sidechaincompress=threshold=0.02:ratio=#{ratio.round(2)}:attack=40:release=600[ducked]"
        filters << "[vox][ducked]amix=inputs=2:normalize=0:duration=longest[mix]"
      else
        filters << "#{labels.join}amix=inputs=#{labels.size}:normalize=0:duration=longest[mix]"
      end
      FileUtils.mkdir_p(File.dirname(out))
      raw = out.sub(/(\.\w+)\z/, '.premix\1')
      args = inputs.flat_map { |p| ["-i", p] }
      run("ffmpeg", "-y", "-v", "error", *args, "-filter_complex", filters.join(";"), "-map", "[mix]", "-ar", "48000", "-c:a", "pcm_s24le", raw)
      loudnorm(raw, out, lufs: lufs, tp: tp).merge(premix: raw)
    end

    private

    def loudnorm_json(stderr)
      start = stderr.rindex("{") or raise CommandError, "loudnorm printed no measurement"
      JSON.parse(stderr[start..stderr.index("}", start)])
    end

    def run_err(*cmd)
      _out, err, status = Open3.capture3(*cmd.map(&:to_s))
      raise CommandError, "#{cmd.first} failed:\n#{err[-1500..] || err}" unless status.success?
      err
    end
  end
end
