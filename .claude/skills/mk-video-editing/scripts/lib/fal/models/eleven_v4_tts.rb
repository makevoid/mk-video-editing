require_relative "base"

module Fal
  module Models
    # https://fal.ai/models/elevenlabs/tts/eleven-v4 — Eleven v4 narration (paid, explicit request only). Supports audio
    # tags such as [whispering] and IPA in /slashes/; no speed/style controls (unlike multilingual v2).
    class ElevenV4Tts < Base
      ENDPOINT = "elevenlabs/tts/eleven-v4".freeze
      DEFAULTS = { voice: "Brian", stability: 0.5, similarity_boost: 0.75, output_format: "mp3_44100_192" }.freeze

      def speak(text:, **opts)
        call(text: text, **opts)
      end
    end
  end
end
