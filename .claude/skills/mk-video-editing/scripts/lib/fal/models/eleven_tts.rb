require_relative "base"

module Fal
  module Models
    # https://fal.ai/models/fal-ai/elevenlabs/tts/multilingual-v2 — narrator / voice-over lines (paid, explicit request only).
    # Voices include Brian, George, Daniel, Bill, Eric, Chris, Roger, Liam, Will, Charlie, Callum (male) and Rachel, Aria,
    # Sarah, Laura, Charlotte, Alice, Matilda, Jessica, Lily (female).
    class ElevenTts < Base
      ENDPOINT = "fal-ai/elevenlabs/tts/multilingual-v2".freeze
      DEFAULTS = { voice: "Brian", stability: 0.55, similarity_boost: 0.75, style: 0.15, speed: 1.0 }.freeze

      def speak(text:, **opts)
        call(text: text, **opts)
      end
    end
  end
end
