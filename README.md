# mk-video-editing

**Turn raw camera or phone footage into a finished video by describing the edit to
[Claude Code](https://claude.com/claude-code)** — talks and presentations, vlogs, interviews and podcasts, tutorials
and product demos, event recaps.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)
![Ruby](https://img.shields.io/badge/Ruby-3.2%2B-CC342D?logo=ruby&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

> Edit the four clips in `~/Movies/conference/` into a 5-minute excerpt of the talk. Opening title with the event name,
> talk title and speaker; a lower third when they first appear. Clean up the audio, remove the ums and long pauses, and
> keep the camera off the audience on the left.

It works best on footage where people talk, since the edit is driven by the transcript. Claude transcribes the
footage, picks selects at sentence boundaries, shows you a plan, then builds and renders the edit with native macOS
tools — a tracking virtual camera inside wide 4K shots, HDR→SDR, deflicker, color matching, dialogue cleanup and Swift
motion-graphics titles.

- **Local by default** — transcription, analysis, audio and rendering run on your Mac; footage never leaves it.
- **Non-destructive** — sources are symlinked, never copied or modified; every revision is a new `final_vN.mp4`.
- **Reviewable** — plain JSON EDLs, debug stills with framing overlays, and QA re-transcription of the final mix.

## Quick start

```sh
brew bundle                                   # ruby, ffmpeg, imagemagick, python, uv
export PATH="$(brew --prefix ruby)/bin:$PATH" # Homebrew Ruby is keg-only; add to ~/.zshrc

claude plugin marketplace add makevoid/mk-video-editing
claude plugin install mk-video-editing@makevoid-video-editing --scope user
```

Open Claude Code next to your footage and describe the edit (or run `/mk-video-editing:mk-video-editing`). The first
project installs gems and builds the Swift tools — about a minute on a cold cache.

## Features

| | |
|---|---|
| **Selects** | Word-level local transcripts (mlx-whisper), sentence-boundary cuts, an approved `PLAN.md` before any render |
| **Speech flow** | Detects ums, hums, repeats, false starts and long pauses from the audio; jump cuts land in the silence between words |
| **Virtual camera** | Vision speaker tracking; wides, punch-ins, pushes and pans as camera beats; `safe` areas keep foreground heads out |
| **Picture** | HLG/HDR → Rec.709, per-tile LED/mains deflicker, per-clip exposure and white-balance match, optional stabilization |
| **Audio** | Rumble/denoise/de-ess/leveler, optional Demucs isolation, ducking and crossfades, two-pass −16 LUFS / −1.5 dBTP |
| **Graphics** | Native Swift renderer for titles, lower thirds and end cards (ProRes 4444 alpha), editable JSON templates |
| **Finishing** | Optional music bed with beat analysis, procedural SFX, Core Image / Metal effects |
| **Delivery** | H.264/HEVC masters, X/Twitter and YouTube encodes |

Optional paid extras — ElevenLabs narration and music via Fal — run only on explicit request.

## How it works

```
intake → transcribe & analyze → plan (you approve) → EDL generator → audio → review stills → render → QA
```

Each edit is a self-contained project folder:

```
projects/my-talk/
  source/          symlinks to your clips
  analysis/        transcripts, camera tracks, flicker and color stats, speech-flow reports
  audio/           raw, cleaned and mixed dialogue
  edit/            build_edl.rb → edl.json, review stills
  docs/            BRIEF.md, PLAN.md, REVIEW.md
  output/          final_v1.mp4, final_v2.mp4, …
```

Under the hood: a Ruby CLI (`scripts/mv.rb`) orchestrates three Swift tools — `medit` (analysis, virtual camera, grade,
render), `mgraphics` (titles) and `mvfx` (effects) — plus FFmpeg and Python helpers run in ephemeral uv environments.

## Requirements

- macOS 14+ on Apple Silicon, 16 GB RAM or more
- Swift 5.9+ (`xcode-select --install`)
- Ruby 3.2+ (the system Ruby is too old), FFmpeg, ImageMagick, Python 3, [uv](https://docs.astral.sh/uv/) — all in the
  [Brewfile](Brewfile)

No footage, music or fonts are bundled; fonts are copied from your Mac per project. Source filenames must be unique
(case-insensitively) — `init` reports clashes and leaves the project untouched.

<details>
<summary><b>Standalone skill (without the plugin)</b></summary>

Use the clone as your editing workspace (`projects/` is git-ignored), or link the skill into every session:

```sh
git clone https://github.com/makevoid/mk-video-editing.git && cd mk-video-editing
ln -s "$PWD/.claude/skills/mk-video-editing" ~/.claude/skills/mk-video-editing   # optional

rake setup      # gems, Python venv, build medit / mgraphics / mvfx
rake doctor     # prerequisite check (STRICT=1 fails on anything missing)
```

For paid narration, export `FAL_AI_API_KEY` in the shell that starts Claude Code. With the plugin, set the key via
`/plugin configure mk-video-editing` instead; it is passed only to the bundled MCP server
([credentials](.claude/skills/mk-video-editing/references/credentials.md)).

</details>

<details>
<summary><b>Running the tools directly</b></summary>

Everything goes through one Ruby entry point. Point this function at your installed skill (works in zsh and Bash, keeps
arguments with spaces intact):

```sh
mv_edit() {
  ruby "/abs/path/to/.claude/skills/mk-video-editing/scripts/mv.rb" "$@"
}

mv_edit init --project /abs/projects/my-talk --media /abs/clip1.MOV --media /abs/clip2.MOV --prompt-file brief.md
cd /abs/projects/my-talk
mv_edit --project . setup

mv_edit --project . 'edit:transcribe[analysis/transcripts,source/clip1.MOV]'
VERBATIM=1 mv_edit --project . 'edit:transcribe[analysis/transcripts_verbatim,source/clip1.MOV]'
REGION=0,0,1,0.62 DETECT_REGION=0.15,0.3,0.85,0.8 mv_edit --project . 'edit:analyze[source/clip1.MOV,analysis/clip1.json]'
SPACE=frame mv_edit --project . 'edit:track[analysis/clip1.json,analysis/clip1.track.json]'
mv_edit --project . 'speech:clean[audio/raw/clip1.wav,audio/clean/clip1.wav]'
mv_edit --project . 'speech:flow[analysis/transcripts_verbatim/clip1.json,audio/clean/clip1.wav,analysis/flow/clip1.json]'

ruby edit/build_edl.rb                                   # your generator writes edit/edl.json
mv_edit --project . 'speech:mix[edit/edl.json,audio/mix.wav]'
DEBUG=1 mv_edit --project . 'edit:stills[edit/edl.json,edit/review/v1,10,42,95]'
mv_edit --project . 'edit:render[edit/edl.json,output/final_v1.mp4]'
```

`mv_edit -T` lists every task. The most used:

| Task | Purpose |
|---|---|
| `edit:transcribe` | Local word transcripts; `VERBATIM=1` keeps fillers |
| `edit:analyze` | Camera path, flicker tiles, color stats and people detection per source |
| `edit:track` | Speaker track (`SPACE=frame` for unstabilized renders, `SEED=x,y` to pick the speaker) |
| `speech:flow` | Filler / false start / repeat / pause detector with proposed cuts |
| `speech:clean`, `speech:mix`, `speech:measure` | Dialogue cleanup, timeline mix + loudness, measurements |
| `voice:tts`, `music:score` | Narration line, music bed (paid, explicit request only) |
| `graphics:render`, `graphics:preview` | Titles from JSON scenes, fast drafts |
| `sfx:gen`/`sfx:mix`, `vfx:stills`/`vfx:render` | Sound and picture effects from cue sheets |
| `edit:stills`, `edit:sheet`, `edit:preview` | Review stills, contact sheets, half-res drafts |
| `edit:render` | Final render of an EDL |
| `media:twitter`, `media:youtube` | Upload encodes |

The EDL schema and a worked generator example are in
[`footage-editing.md`](.claude/skills/mk-video-editing/references/footage-editing.md).

</details>

## Memory safety

4K HDR frames are decoded in a system process outside the job's own memory, so parallel heavy jobs can freeze a 16 GB
Mac. The skill runs one heavy job at a time, and every native render goes through `Media::Guard`, which stops the job
before memory gets dangerous (`MEDIT_MAX_FOOTPRINT_MB`, default 3500; `MEDIT_MIN_FREE_PCT`, default 30). A 1080p render
from 4K sources typically peaks at 2–2.5 GB.

## Privacy

Footage stays on your Mac. Setup downloads gems and Python packages, and the first transcription or Demucs run
downloads model weights. Only explicitly requested Fal tasks (narration, music, prompt-based SFX) send text prompts out,
and they are billed. No telemetry. Normal Claude conversation and tool-result handling still applies.

## Development

```sh
PROFILE=core  rake test     # contracts, CLI, cut helpers — fast, no media
PROFILE=media rake test     # real FFmpeg / ImageMagick / Python
PROFILE=swift rake test     # native renderers
rake test                   # everything
claude --plugin-dir .       # try local plugin changes
```

Tests make no paid calls and need no footage; fixtures are synthesized. Projects get their own copy of `lib/` and
`tools/` at `init`, so after changing the skill, start a new project or rsync the changes in.

<details>
<summary><b>Repository layout</b></summary>

```
.claude-plugin/             plugin.json + marketplace.json
.claude/skills/mk-video-editing/
  SKILL.md                  instructions Claude follows
  references/               footage editing, finishing, tasks, testing, credentials
  scripts/mv.rb             Ruby CLI entry point (rake tasks)
  scripts/mcp.rb            MCP server for paid Fal tasks in plugin sessions
  scripts/lib/media/        edit, speech, cuts, guard, ffmpeg, graphics, sfx, vfx
  scripts/lib/fal/          Fal client + ElevenLabs TTS/Music and Stable Audio SFX adapters
  scripts/lib/workflow/     plan approval, parallel sub-agent waves, progress journal
  scripts/tools/edit/       medit — Swift footage editor
  scripts/tools/graphics/   mgraphics — Swift motion-graphics renderer + title templates
  scripts/tools/vfx/        mvfx — Swift video effects
  scripts/tools/python/     speech flow, transcription, Demucs, beats, cut detection, SFX mix
  scripts/spec/             RSpec suite
Brewfile                    command-line prerequisites
Rakefile                    rake setup / doctor / test
```

</details>

Contributions welcome — framing heuristics, grading and deflicker, speech-flow detection, title templates, and lessons
from real edits (as generic notes, without your footage). Run `PROFILE=core rake test`, plus the swift profile for Swift
changes, before opening a PR. Release follow-ups live in [TODO.md](TODO.md).

**Docs:** [SKILL.md](.claude/skills/mk-video-editing/SKILL.md) ·
[Footage editing](.claude/skills/mk-video-editing/references/footage-editing.md) ·
[Finishing](.claude/skills/mk-video-editing/references/finishing.md) ·
[Tasks](.claude/skills/mk-video-editing/references/tasks.md) ·
[Testing](.claude/skills/mk-video-editing/references/testing.md)

The motion-graphics renderer and VFX are trimmed from
[motion-graphics-music-video-skill-noimage](https://github.com/makevoid/motion-graphics-music-video-skill-noimage) —
use that for beat-synced music videos.

## License

[MIT](LICENSE)
