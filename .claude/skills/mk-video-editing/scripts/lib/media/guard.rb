require "open3"
require_relative "shell"

module Media
  # Memory watchdog for heavy native jobs (4K/HDR decode, Core Image, Vision). Machines may run without swap, where
  # exhausting RAM freezes the whole system instead of slowing it down. The guard polls the child's full footprint
  # (`footprint`, which counts IOSurface/GPU memory that RSS misses) and the system's available memory, and SIGKILLs the
  # job before either crosses its limit. Limits: MEDIT_MAX_FOOTPRINT_MB (job + decoder services, default 3500),
  # MEDIT_MIN_FREE_PCT (kernel free percentage, default 30). MEDIT_GUARD_LOG=path logs every sample (0.3 s): decoder memory can grow GBs per second.
  module Guard
    PAGE = (`sysctl -n hw.pagesize`.to_i.nonzero? || 16_384)

    def self.available_mb
      stats = `vm_stat`
      pages = %w[free inactive speculative purgeable].sum { |k| stats[/Pages #{k}:\s+(\d+)/, 1].to_i }
      pages * PAGE / 1_048_576
    end

    # Kernel view (what memory pressure/jetsam act on), 0..100.
    def self.free_pct = `memory_pressure -Q 2>/dev/null`[/free percentage:\s+(\d+)/, 1]&.to_i || 100

    # Hardware decode runs out of process: decoded frames live in VTDecoderXPCService, not in the job's footprint.
    def self.decoder_mb
      `pgrep -x VTDecoderXPCService`.split.sum { |pid| footprint_mb(pid) || 0 }
    end

    def self.footprint_mb(pid)
      out = `footprint -p #{pid.to_i} 2>/dev/null`
      value, unit = out.match(/Footprint:\s+([\d.]+)\s+(KB|MB|GB|B)/)&.captures
      return nil unless value
      value.to_f * { "B" => 1.0 / 1_048_576, "KB" => 1.0 / 1024, "MB" => 1, "GB" => 1024 }.fetch(unit)
    end

    def self.run(*cmd, max_footprint_mb: Integer(ENV["MEDIT_MAX_FOOTPRINT_MB"] || 3500),
                 min_free_pct: Integer(ENV["MEDIT_MIN_FREE_PCT"] || 30), interval: 0.3, quiet: false)
      start_free = free_pct
      raise CommandError, "System memory only #{start_free}% free (< #{min_free_pct + 15}%); close apps before heavy jobs" if start_free < min_free_pct + 15
      base_decoder = decoder_mb
      warn "  $ #{cmd.map(&:to_s).join(" ")}" unless quiet
      peak, low, killed = 0.0, start_free, nil
      out = err = nil
      Open3.popen3(*cmd.map(&:to_s)) do |stdin, stdout, stderr, wait|
        stdin.close
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        until wait.join(interval)
          own = footprint_mb(wait.pid) || 0
          dec = [decoder_mb - base_decoder, 0].max
          fp = own + dec
          av = free_pct
          File.open(ENV["MEDIT_GUARD_LOG"], "a") { |f| f.puts "#{Time.now.strftime("%T")} job_mb=#{own.round} decoder_mb=#{dec.round} free_pct=#{av} wired_mb=#{`vm_stat`[/wired down:\s+(\d+)/, 1].to_i * PAGE / 1_048_576}" } if ENV["MEDIT_GUARD_LOG"]
          peak = [peak, fp].max
          low = [low, av].min
          next unless fp > max_footprint_mb || av < min_free_pct
          killed = "job+decoder footprint #{fp.round} MB (limit #{max_footprint_mb}), system free #{av}% (floor #{min_free_pct}%)"
          Process.kill("KILL", wait.pid) rescue nil
          wait.join
          break
        end
        out, err = readers.map(&:value)
        status = wait.value
        warn "  guard: peak job+decoder footprint #{peak.round} MB, lowest system free #{low}%" unless quiet
        raise CommandError, "#{File.basename(cmd.first.to_s)} killed by memory guard: #{killed}" if killed
        raise CommandError, "#{cmd.first} failed (#{status.exitstatus}):\n#{err[-2000..] || err}" unless status.success?
      end
      out
    end
  end
end
