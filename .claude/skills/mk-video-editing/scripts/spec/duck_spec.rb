require_relative "spec_helper"
RSpec.describe "Music and narration ducking", :media do
  def silence(path, duration)
    ff.run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", duration, "-c:a", "pcm_s16le", path)
    path
  end
  def sine(path, freq:, from:, to:, total:)
    ff.run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=#{freq}:sample_rate=48000:duration=#{to - from}",
           "-af", "adelay=#{(from * 1000).round}:all=1,apad=whole_dur=#{total}", "-t", total, "-ac", "1", "-c:a", "pcm_s16le", path)
    path
  end
  def gain_at(env, t)
    data = File.binread(env)[44..].unpack("s<*")
    data[(t * 48_000).round] / 32_767.0
  end
  def window_db(wav, from, to)
    ff.run("ffmpeg", "-y", "-v", "error", "-i", wav, "-ss", from, "-to", to, "-ac", "1", "-c:a", "pcm_s16le", file("w.wav"))
    py.audio_energy(file("w.wav"), window: to - from)["windows"].first["rms_db"]
  end

  it "builds an exact-depth envelope that is fully down before the first word and back up after the release" do
    key = sine(file("key.wav"), freq: 700, from: 1.0, to: 2.0, total: 4)
    report = py.duck_envelope(key, file("env.wav"), length: 5, depth: -12, attack: 0.1, release: 0.5, hold: 0.2, lookahead: 0.15)
    expect(report["spans"].size).to eq(1)
    expect(report["spans"][0][0]).to be_within(0.03).of(1.0)
    expect(report["spans"][0][1]).to be_within(0.03).of(2.0)
    expect(gain_at(file("env.wav"), 0.5)).to be_within(0.001).of(1.0)
    expect(gain_at(file("env.wav"), 1.0)).to be_within(0.01).of(10**(-12 / 20.0))  # already down at the onset (lookahead)
    expect(gain_at(file("env.wav"), 1.6)).to be_within(0.01).of(10**(-12 / 20.0))
    expect(gain_at(file("env.wav"), 3.5)).to be_within(0.001).of(1.0)
    expect(File.size(file("env.wav")) - 44).to eq(5 * 48_000 * 2)                  # covers the music past the voice
  end

  it "keeps the music ducked across short gaps between words (bridge)" do
    a = sine(file("a.wav"), freq: 700, from: 0.5, to: 1.0, total: 3)
    ff.run("ffmpeg", "-y", "-v", "error", "-i", a, "-i", sine(file("b.wav"), freq: 700, from: 1.3, to: 2.0, total: 3),
           "-filter_complex", "amix=inputs=2:normalize=0", "-c:a", "pcm_s16le", file("words.wav"))
    report = py.duck_envelope(file("words.wav"), file("env2.wav"), length: 3, depth: -10, bridge: 0.5)
    expect(report["spans"]).to eq([[0.5, 2.0]])
  end

  it "handles voice keys shorter than one analysis window" do
    key = silence(file("short.wav"), 0.005)
    report = py.duck_envelope(key, file("short-env.wav"), length: 1)
    expect(report["spans"]).to be_empty
    expect(gain_at(file("short-env.wav"), 0.5)).to be_within(0.001).of(1)
  end

  it "uses lookahead before timeline zero when speech starts immediately" do
    key = sine(file("onset.wav"), freq: 700, from: 0, to: 1, total: 2)
    py.duck_envelope(key, file("onset-env.wav"), length: 2, depth: -12)
    expect(gain_at(file("onset-env.wav"), 0)).to be_within(0.001).of(10**(-12 / 20.0))
  end

  it "creates the output directory before rendering the envelope key" do
    key = sine(file("key.wav"), freq: 700, from: 0.5, to: 1, total: 2)
    music = tone(file("bed.wav"), duration: 3)
    edl = file("nested.json")
    json(edl, { "clips" => [], "sounds" => [{ "source" => key }],
                "music" => [{ "source" => music }], "duck" => { "mode" => "envelope" } })
    out = file("new-output/mix.wav")
    Media::Speech.new.mix(edl, out)
    expect(File.file?(out)).to be(true)
    expect(File.file?(file("new-output/mix.duck.json"))).to be(true)
  end

  it "preserves stereo bed gain outside speech and applies the exact dip during speech" do
    key = sine(file("key.wav"), freq: 700, from: 1, to: 2, total: 2.1)
    music = file("stereo.wav")
    ff.run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
           "aevalsrc=0.1*sin(2*PI*300*t)|0.05*sin(2*PI*500*t):s=48000:d=5", "-c:a", "pcm_s16le", music)
    edl = file("exact.json")
    json(edl, { "clips" => [], "sounds" => [{ "source" => key, "gain_db" => -45 }],
                "music" => [{ "source" => music, "gain_db" => 0 }],
                "duck" => { "mode" => "envelope", "threshold_db" => -75, "depth_db" => -12 } })
    Media::Speech.new.mix(edl, file("exact.wav"))
    premix = file("exact.premix.wav")
    expect(window_db(premix, 0.2, 0.5)).to be_within(0.1).of(window_db(music, 0.2, 0.5))
    expect(window_db(premix, 1.3, 1.7)).to be_within(0.1).of(window_db(music, 1.3, 1.7) - 12)
    expect(window_db(premix, 3.5, 4.0)).to be_within(0.1).of(window_db(music, 3.5, 4.0))
    expect(ff.duration(premix)).to be_within(0.01).of(5)
  end

  %w[sidechain envelope].each do |mode|
    it "keeps a music-only edit at full gain with #{mode} ducking" do
      music = file("bed.wav")
      ff.run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=300:duration=4", "-ac", "2", music)
      edl = file("music-only.json")
      json(edl, { "clips" => [{ "source" => "muted.mp4", "in" => 0, "out" => 4, "at" => 0, "mute" => true }],
                  "music" => [{ "source" => music, "gain_db" => 0, "at" => 0.5, "from" => 1, "duration" => 2 }],
                  "duck" => { "mode" => mode } })
      Media::Speech.new.mix(edl, file("music-only.wav"))
      premix = file("music-only.premix.wav")
      expect(window_db(premix, 1.0, 1.5)).to be_within(0.1).of(window_db(music, 1.0, 1.5))
      expect(ff.duration(premix)).to be_within(0.01).of(2.5)
      if mode == "envelope"
        report = JSON.parse(File.read(file("music-only.duck.json")))
        expect(report["spans"]).to be_empty
        expect(report["ducked_s"]).to eq(0)
      end
    end
  end

  it "ducks clip audio under narration with duck_clips and the music with an envelope in speech:mix" do
    clip = video(audio: tone(file("clip.wav"), duration: 4), seconds: 4)
    narration = silence(file("narration.wav"), 1.0)
    music = sine(file("music.wav"), freq: 300, from: 0, to: 6, total: 6)
    edl = file("edl.json")
    json(edl, { "clips" => [{ "source" => clip, "in" => 0, "out" => 4, "at" => 0 }],
                "sounds" => [{ "source" => narration, "at" => 1.5, "duck_clips" => -20, "duck_ramp" => 0.1 }],
                "music" => [{ "source" => music, "at" => 0, "duration" => 4, "gain_db" => -20 }],
                "duck" => { "mode" => "envelope", "depth_db" => -12 } })
    Media::Speech.new.mix(edl, file("mix.wav"))
    duck = JSON.parse(File.read(file("mix.duck.json")))
    expect(duck["spans"].first[0]).to be_within(0.05).of(0.0)        # the clip's own speech is part of the key
    premix = file("mix.premix.wav")
    expect(window_db(premix, 0.5, 1.2) - window_db(premix, 1.7, 2.3)).to be > 12
  end

  it "ducks sped-up clips across a cut for the narration's rendered duration, including zero-length ramps" do
    clip = sine(file("clip.wav"), freq: 700, from: 0, to: 8, total: 8)
    narration = silence(file("narration.wav"), 2)
    edl = file("cut.json")
    json(edl, { "clips" => [
      { "source" => clip, "in" => 2, "out" => 4, "at" => 0 },
      { "source" => clip, "in" => 2, "out" => 8, "speed" => 2, "at" => 2 }],
      "sounds" => [{ "source" => narration, "at" => 1, "duck_clips" => -20, "duck_ramp" => 0 }] })
    Media::Speech.new.mix(edl, file("cut.wav"))
    premix = file("cut.premix.wav")
    expect(window_db(premix, 0.3, 0.7) - window_db(premix, 1.1, 1.4)).to be_within(0.2).of(20)
    expect(window_db(premix, 3.5, 3.9) - window_db(premix, 2.3, 2.7)).to be_within(0.2).of(20)
  end
end
