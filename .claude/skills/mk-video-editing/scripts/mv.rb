#!/usr/bin/env ruby
if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.2")
  abort "mk-video-editing needs Ruby 3.2+ (this is #{RUBY_VERSION} at #{RbConfig.ruby}).\n" \
        "Install it with `brew install ruby` and put Homebrew's Ruby first in PATH:\n" \
        "  export PATH=\"$(brew --prefix ruby)/bin:$PATH\""
end
require "optparse"
require "fileutils"
require "json"
require "rbconfig"
require "open3"
runtime = __dir__
options = {}
parser = OptionParser.new do |o|
  o.banner = "Usage: ruby scripts/mv.rb [--project DIR] TASK [task arguments]\n       ruby scripts/mv.rb init --project DIR --media FOOTAGE_DIR --prompt-file FILE   (footage edit)\n       ruby scripts/mv.rb init --project DIR --song FILE --prompt-file FILE          (motion-graphics music video)\nRuby is the only execution entry. Tasks use ENV ONLY/FORCE/VFX/SFX."
  o.on("--project DIR", "Project workspace (defaults to bundled runtime)") { |v| options[:project] = File.expand_path(v) }
  o.on("--media PATH", "Footage file or folder for an edit project (repeatable)") { |v| (options[:media] ||= []) << File.expand_path(v) }
  o.on("--song FILE", "Local soundtrack for a motion-graphics music video project") { |v| options[:song] = File.expand_path(v) }
  o.on("--prompt-file FILE", "Creative brief for init") { |v| options[:prompt] = File.expand_path(v) }
  o.on("-T", "List all rake tasks") { options[:list] = true }
  o.on("--help", "Show tasks and exit") { puts o; puts "Edit tasks: edit:transcribe, edit:analyze, edit:track, edit:stats, edit:stills, edit:sheet, edit:preview, edit:render, speech:clean, speech:mix, speech:measure, voice:tts.\nTasks: init, setup, doctor, test, plan:approve, work:next, work:accept, audio:analyze, audio:map, audio:transcribe_local, media:stems_local, graphics:preview, graphics:render, sfx:gen, sfx:mix, vfx:render. Use -T for the complete rake task list.\nExit: 0 success; 1 task/runtime failure; 2 invalid CLI or missing input. No interactive shell prompts."; exit }
end
begin
  parser.parse!(ARGV)
  command = options[:list] ? "-T" : (ARGV.shift || "doctor")
  if command == "init"
    require_relative "lib/toolkit/initializer"
    init = Toolkit::Initializer.new(runtime)
    puts JSON.pretty_generate(options[:media] ? init.create_edit(project: options[:project], media: options[:media], prompt: options[:prompt]) :
                                                init.create(project: options[:project], song: options[:song], prompt: options[:prompt]))
    exit
  end
  project = options[:project] || runtime
  raise ArgumentError, "No project Rakefile in #{project}; use init first" unless File.file?(File.join(project, "Rakefile"))
  Dir.chdir(project)
  if command == "setup"
    # Bootstrap gems before loading any runtime dependencies.
    ok = system(RbConfig.ruby, "-S", "bundle", "install")
    raise "bundle install failed" unless ok
  end
  ENV["BUNDLE_GEMFILE"] = File.join(project, "Gemfile")
  require "bundler/setup"
  require "rake"
  args = command == "-T" ? ["-T"] : [command, *ARGV]
  Rake.application.run(args)
rescue OptionParser::ParseError, ArgumentError => e
  warn "Error: #{e.message}\n#{parser}"
  exit 2
rescue StandardError => e
  warn "Error: #{e.message}"
  exit 1
end
