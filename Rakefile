require "rake"
SKILL = ".claude/skills/mk-video-editing/scripts/mv.rb"
desc "Install gems and the Python venv, build the Swift tools (medit, mgraphics, mvfx) and check prerequisites"
task(:setup) { ruby SKILL, "setup" }
desc "Check local prerequisites (STRICT=1 fails on anything missing)"
task(:doctor) { ruby SKILL, "doctor" }
desc "Run the skill's RSpec suite (PROFILE=all|core|media|swift)"
task(:test) { ruby SKILL, "test" }
task default: :test
