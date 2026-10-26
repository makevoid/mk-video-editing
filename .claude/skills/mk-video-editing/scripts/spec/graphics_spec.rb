require_relative "spec_helper"

RSpec.describe Media::Graphics, :core do
  it "routes JSON scenes through Swift with cue files and sparse frames" do
    service = Media::Anim.new
    allow(service).to receive(:build)
    expect(Media::Guard).to receive(:run).with(Media::Graphics::BIN, "scene.json", "--out", "frames", "--width", 320, "--height", 180, "--fps", 24, "--frames", 48, "--only", "0,24", "--data", "words=words.json").and_return('{"frames":2}')
    expect(service.render("scene.json", "frames", width: 320, height: 180, fps: 24, frames: 48, data: { words: "words.json" }, only: [0,24])["frames"]).to eq(2)
  end

  it "rejects removed JavaScript scenes without launching a process" do
    service = Media::Anim.new
    expect(service).not_to receive(:run)
    expect(Media::Guard).not_to receive(:run)
    expect { service.render("scene.js", "frames", width: 320, height: 180, fps: 24, frames: 48) }.to raise_error(ArgumentError, /JavaScript rendering has been removed/)
  end

  it "passes video options as separate argv values and propagates renderer failures" do
    service = described_class.new
    allow(service).to receive(:build)
    expect(Media::Guard).to receive(:run).with(described_class::BIN, "scene with spaces.json", "--out", "out.mov", "--width", 320, "--height", 180, "--fps", 29.97, "--frames", 60,
      "--plate", "plate with spaces.mp4", "--audio", "song.m4a", "--codec", "prores4444", "--data", "words=word cues.json").and_raise(Media::CommandError, "fixture")
    expect { service.render("scene with spaces.json", "out.mov", width: 320, height: 180, fps: 29.97, frames: 60, plate: "plate with spaces.mp4", audio: "song.m4a", codec: "prores4444", data: { words: "word cues.json" }) }.to raise_error(Media::CommandError, "fixture")
  end
end

RSpec.describe "Native graphics package", :swift do
  it "renders ProRes titles through the CLI with alpha, sequentially by default and in explicit parallel chunks" do
    scene = file("alpha.json")
    json(scene, version: 1, nodes: [{ type: "rect", x: 16, y: 8, width: 32, height: 16, fill: "#ffffff" }])
    [nil, "2"].each do |jobs|
      out = file(jobs ? "parallel.mov" : "default.mov")
      stdout, err, status = cli("graphics:render[#{scene},#{out},48,64,32,24]", env: { "CODEC" => "prores4444", "JOBS" => jobs })
      expect(status.success?).to be(true), err
      report = JSON.parse(stdout)
      expect(report["frames"]).to eq(48)
      if jobs
        expect(report["jobs"]).to eq(2)
      else
        expect(report).not_to have_key("jobs")
      end
      info = ff.summary(out)
      expect(info.dig(:video, :codec)).to eq("prores")
      expect(info.dig(:video, :frames)).to eq(48)
      rgba = ff.run("ffmpeg", "-v", "error", "-i", out, "-vf", "select=eq(n\\,24)", "-frames:v", "1", "-pix_fmt", "rgba", "-f", "rawvideo", "-", quiet: true)
      expect(rgba.getbyte(3)).to eq(0)
      expect(rgba.getbyte((16 * 64 + 32) * 4 + 3)).to eq(255)
      expect(File.exist?("#{out}.parts")).to be(false)
    end
  end

  it "passes geometry, animation, alpha, GPU, and native video round-trip tests" do
    package = Media::Graphics::PACKAGE
    expect(Media::Shell.new.run("swift", "test", "--package-path", package)).to include("0 failures")
  end

  it "renders sparse JSON overlay frames through the existing Anim interface" do
    scene = File.join(Media::Graphics::PACKAGE, "examples", "overlay.json")
    result = Media::Anim.new.render(scene, file("native"), width: 320, height: 180, fps: 24, frames: 48, only: [0, 24, 47])
    expect(result["frames"]).to eq(3)
    expect(Dir[File.join(file("native"), "*.png")].map { |f| File.basename(f) }).to contain_exactly("0000.png", "0024.png", "0047.png")
    coverage = magick.alpha_coverage(file("native/0024.png"))
    expect(coverage).to be_between(0.01, 0.5)
  end
end
