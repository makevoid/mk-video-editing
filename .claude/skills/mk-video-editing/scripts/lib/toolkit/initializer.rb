require "fileutils"
require "json"
module Toolkit
  class Initializer
    EXCLUDED = %w[node_modules .venv .bundle output tmp specs .build prompts config docs audio .skill __pycache__ .DS_Store].freeze
    def initialize(runtime) = @runtime = runtime
    def copy_tree(source, destination)
      FileUtils.mkdir_p(destination)
      Dir.children(source).each do |entry|
        next if EXCLUDED.include?(entry)
        src, dst = File.join(source, entry), File.join(destination, entry)
        File.directory?(src) ? copy_tree(src, dst) : FileUtils.cp(src, dst)
      end
    end
    VIDEO = /\.(mov|mp4|m4v|mxf|avi|mkv)\z/i
    # Footage edit project: the runtime plus source/ (media is linked unless it already lives in project/source),
    # audio/ analysis/ edit/ docs/ output/. An existing folder is accepted when it has no Rakefile (e.g. one holding source/).
    def create_edit(project:, media:, prompt:)
      raise ArgumentError, "init requires --project, --media (file or folder, repeatable), --prompt-file" unless project && !media.empty? && prompt
      raise ArgumentError, "Prompt file missing" unless File.file?(prompt)
      raise ArgumentError, "Project already initialized: #{project}" if File.exist?(File.join(project, "Rakefile"))
      files = media.flat_map { |m| File.directory?(m) ? Dir[File.join(m, "*")].sort : [m] }.select { |f| File.file?(f) && f.match?(VIDEO) }
      raise ArgumentError, "No video files in #{media.join(", ")}" if files.empty?
      copy_tree(@runtime, project)
      copy_skill(project)
      %w[source audio analysis edit docs output scenes config].each { |d| FileUtils.mkdir_p(File.join(project, d)) }
      sources = files.map do |f|
        dest = File.join(project, "source", File.basename(f))
        File.symlink(f, dest) unless File.expand_path(f) == File.expand_path(dest) || File.exist?(dest)
        "source/#{File.basename(f)}"
      end
      FileUtils.cp(prompt, File.join(project, "docs", "BRIEF.md")) unless File.expand_path(prompt) == File.expand_path(File.join(project, "docs", "BRIEF.md"))
      File.write(File.join(project, "config/production.json"), JSON.pretty_generate(wave: 0, jobs: []))
      File.write(File.join(project, "config/project.json"), JSON.pretty_generate(kind: "edit", sources: sources, fps: 30))
      { project: project, sources: sources, next: "setup, then edit:transcribe[analysis/transcripts,...] and edit:analyze per source; write docs/PLAN.md" }
    end
    def copy_skill(project)
      origin = File.file?(File.expand_path("../SKILL.md", @runtime)) ? File.expand_path("..", @runtime) : File.join(@runtime, ".skill")
      return unless File.file?(File.join(origin, "SKILL.md"))
      target = File.join(project, ".skill")
      FileUtils.mkdir_p(target)
      %w[SKILL.md references assets].each { |entry| FileUtils.cp_r(File.join(origin, entry), target) if File.exist?(File.join(origin, entry)) }
    end
  end
end
