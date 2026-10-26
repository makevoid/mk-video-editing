require_relative "base"

module Fal
  module Models
    # https://fal.ai/models/elevenlabs/music/v2.5 — background score from a prompt (paid, explicit request only).
    # music_length_ms 3000..600000; force_instrumental keeps vocals out.
    class ElevenMusic < Base
      ENDPOINT = "elevenlabs/music/v2.5".freeze
      DEFAULTS = { force_instrumental: true, output_format: "mp3_48000_192" }.freeze

      def compose(prompt:, seconds:, **opts)
        call(prompt: prompt, music_length_ms: (seconds * 1000).round, **opts)
      end
    end
  end
end
