require "json"
require_relative "shell"

module Media
  # Runs analysis scripts in ./scripts with the local python3 (PIL + numpy)
  # and parses their JSON stdout.
  class Python < Shell
    SCRIPTS = File.expand_path("../../tools/python", __dir__)

    def executable = ENV["MV_PYTHON"] || (File.file?(File.expand_path(".venv/bin/python3")) ? File.expand_path(".venv/bin/python3") : "python3")

    # Interpreter argv for the PIL/numpy scripts: the project venv from `setup` (or MV_PYTHON), else an ephemeral uv
    # environment, so a fresh project works before setup on a Mac whose python3 has no numpy.
    def command
      return [executable] if executable != "python3" || !Shell.available?("uv")
      ["uv", "run", "--quiet", "--no-project", "--python", "3.12", "--with", "numpy", "--with", "Pillow", "python"]
    end

    def call(script, *args)
      JSON.parse(run(*command, File.join(SCRIPTS, script), *args, quiet: true))
    end

    # Local word timestamps through mlx-whisper in an ephemeral uv environment (Apple Silicon; local processing).
    # Returns Whisper-style { "text", "chunks" => [{ "text", "timestamp" => [s, e] }] } in whole-song seconds.
    def transcribe_local(audio, from: 0.0, seconds: 0.0, model: ENV["MV_WHISPER_MODEL"] || "mlx-community/whisper-large-v3-turbo", language: ENV["MV_WHISPER_LANG"].to_s, prompt: "")
      raise CommandError, "uv is required for local transcription (https://docs.astral.sh/uv/)" unless Shell.available?("uv")
      JSON.parse(run("uv", "run", "--quiet", "--no-project", "--python", "3.12", "--with", "mlx-whisper",
                     "python", File.join(SCRIPTS, "transcribe_local.py"), audio, from.to_s, seconds.to_s, model, language, prompt.to_s, quiet: true).lines.last)
    end


    # Local Demucs stem WAVs (vocals, no_vocals, drums, bass, other) (full-song aligned) through an ephemeral uv environment; local processing.
    def stems_local(audio, out, from: 0.0, seconds: 0.0, model: ENV["MV_DEMUCS_MODEL"] || "htdemucs")
      raise CommandError, "uv is required for local stems (https://docs.astral.sh/uv/)" unless Shell.available?("uv")
      JSON.parse(run("uv", "run", "--quiet", "--no-project", "--python", "3.12", "--with", "demucs", "--with", "soundfile",
                     "python", File.join(SCRIPTS, "stems_local.py"), audio, out, from.to_s, seconds.to_s, model, quiet: true).lines.last)
    end

    # Speech flow (tools/python/speech_flow.py): fillers, hums, repeats, possible false starts and unnatural pauses with
    # proposed cuts, from a (verbatim) word transcript and the clip audio; writes out.json and out.txt.
    def speech_flow(transcript, audio, out)
      raise CommandError, "uv is required for speech flow (https://docs.astral.sh/uv/)" unless Shell.available?("uv")
      JSON.parse(run("uv", "run", "--quiet", "--no-project", "--python", "3.12", "--with", "numpy", "--with", "soundfile",
                     "python", File.join(SCRIPTS, "speech_flow.py"), transcript, audio, out, quiet: true).lines.last)
    end

    # RMS loudness + vocal-band energy per window, for a mono wav.
    def audio_energy(wav, window: 0.5)
      call("audio_energy.py", wav, window.to_s)
    end

    # Music ducking gain envelope (mono 16-bit wav, `length` s) from a voice key wav: an exact `depth` dB dip wherever
    # the key is above `threshold` dBFS, ramped with lookahead so the first word is already ducked. Returns the spans.
    def duck_envelope(key, out, length:, depth: -12, threshold: -42, attack: 0.12, release: 0.6, hold: 0.25, lookahead: 0.15, bridge: 0.6)
      call("duck_envelope.py", key, out, *[length, depth, threshold, attack, release, hold, lookahead, bridge].map(&:to_s))
    end
  end
end
