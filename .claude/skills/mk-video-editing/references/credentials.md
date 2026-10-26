# Optional Fal credentials

Footage editing needs no API key: transcription (mlx-whisper), analysis, the virtual camera, grading, dialogue cleanup, mixing, titles and rendering all run locally. A Fal key is used only for work the user explicitly asks for:

| Task | Model | When |
|---|---|---|
| `voice:tts[text.txt,out.mp3]` | ElevenLabs TTS (`MODEL=v4` for Eleven v4) | narration lines |
| `music:score[prompt.txt,out.mp3,seconds]` | ElevenLabs Music v2.5 | a background music bed |
| `audio:transcribe`, `media:stems`, `sfx:gen` (prompt sounds) | Whisper, Demucs, Stable Audio | only when the local equivalents are not wanted |

Write the requested calls (lines, voice, expected count and retries) into `docs/PLAN.md` and record approval with `NOTE='...' plan:approve` before the first paid call. Existing approval within that scope stays valid; do not ask again per line.

## Plugin sessions

Configure the optional **Fal API key** with `/plugin configure mk-video-editing`. The sensitive `FAL_AI_API_KEY` option is passed only to the bundled `mk-video-editing` MCP server. Never ask the user to paste it into chat or read credential files. The server starts without a key; `credential_status` reports whether one is configured without revealing it.

Initialize the project, run setup, write the plan and record approval through the Ruby CLI. Run paid tasks with the server's `run_task` (for example `voice:tts[audio/narration/intro.txt,audio/narration/intro.mp3]` with `options: {"VOICE": "Brian", "MODEL": "v4"}`) and poll `task_status` until it completes. Cancellation stops the local process; an already submitted Fal request may still incur charges. Resume from saved receipts rather than resubmitting.

## Standalone use

Outside the plugin the Ruby CLI reads only `FAL_AI_API_KEY` from its environment (export it in the shell that starts Claude Code). Do not put keys in source, prompts or config files. The MCP server prefers its plugin option and falls back to the exported key when the option is unset; ordinary shell tasks cannot see the plugin option.

Uploaded media URLs may be accessible to anyone with the link. `doctor` checks local dependencies only; a missing Fal key never fails it.
