require_relative "spec_helper"

RSpec.describe "Native rendering memory safety", :core do
  it "refuses graphics renders, previews and synthesis before launching when system memory is low" do
    service = Media::Graphics.new
    allow(service).to receive(:build)
    allow(Media::Guard).to receive(:free_pct).and_return(20)
    expect(Open3).not_to receive(:popen3)
    expect { service.render("scene.json", file("out.mov"), width: 64, height: 32, fps: 24, frames: 48) }.to raise_error(Media::CommandError, /System memory only/)
    expect { service.preview("scene.json", file("preview.mp4"), from: 0, to: 2) }.to raise_error(Media::CommandError, /System memory only/)
    expect { service.synth(file("sound.wav"), { "synth" => "whoosh" }) }.to raise_error(Media::CommandError, /System memory only/)
  end

  it "refuses VFX full renders, clips and stills before launching when system memory is low" do
    service = Media::Vfx.new("guard-spec-#{Process.pid}-#{object_id}")
    allow(service).to receive(:build)
    allow(service).to receive(:config).and_return({ "source" => file("source.mp4"), "out" => file("out.mp4"), "cues" => [] })
    allow(Media::FFmpeg).to receive(:new).and_return(double(duration: 2))
    allow(Media::Guard).to receive(:free_pct).and_return(20)
    expect(Open3).not_to receive(:popen3)
    expect { service.render }.to raise_error(Media::CommandError, /System memory only/)
    expect { service.clip(0, 24) }.to raise_error(Media::CommandError, /System memory only/)
    expect { service.stills([0]) }.to raise_error(Media::CommandError, /System memory only/)
  end

  it "runs one guarded VFX worker by default" do
    ENV.delete("JOBS")
    service = Media::Vfx.new("guard-default-#{Process.pid}-#{object_id}")
    allow(service).to receive(:build)
    allow(service).to receive(:config).and_return({ "source" => file("source.mp4"), "out" => file("out.mp4"), "cues" => [] })
    allow(Media::FFmpeg).to receive(:new).and_return(double(duration: 10))
    expect(Media::Guard).to receive(:run).once.with(Media::Vfx::BIN, "--in", file("source.mp4"), "--cues", service.path("cues.json"), "--out", file("out.mp4"), quiet: false).and_return('{}')
    expect(service.render).to eq(file("out.mp4"))
    expect(File.exist?(file("out.mp4.parts"))).to be(false)
  end

  it "terminates a running child when its memory footprint exceeds the limit" do
    allow(Media::Guard).to receive(:free_pct).and_return(100)
    allow(Media::Guard).to receive(:decoder_mb).and_return(0)
    allow(Media::Guard).to receive(:footprint_mb).and_return(2)
    expect do
      Media::Guard.run(RbConfig.ruby, "-e", "sleep 10", max_footprint_mb: 1, interval: 0.01, quiet: true)
    end.to raise_error(Media::CommandError, /killed by memory guard: job\+decoder footprint 2 MB/)
  end
end
