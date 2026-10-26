# mk-video-editing

A [Claude Code](https://claude.com/claude-code) skill and plugin that edits supplied camera or
phone footage into a finished video: talks, keynotes, interviews, events.

You give Claude the clips and a short brief ("a 4-minute excerpt of this keynote, with an opening title and
narration"). Claude transcribes the footage, picks the selects, plans the edit with you, then builds and renders it with
native macOS tools: a virtual camera that reframes the speaker inside wide 4K shots, HDR→SDR, deflicker, color matching,
cleaned and normalized dialogue, narration and motion-graphics titles. Everything runs locally except optional paid
narration and music.

No footage, music or fonts are bundled: you bring the media, and fonts are copied from your Mac per project.

[Skill instructions](.claude/skills/mk-video-editing/SKILL.md) ·
[Footage editing reference](.claude/skills/mk-video-editing/references/footage-editing.md) ·
[Finishing: music, SFX, VFX](.claude/skills/mk-video-editing/references/finishing.md) ·
[Task reference](.claude/skills/mk-video-editing/references/tasks.md) ·
[Testing](.claude/skills/mk-video-editing/references/testing.md)

## What it does

| Area | Functionality |
|---|---|
| **Selects** | Local word-level transcripts (mlx-whisper), selects cut at sentence boundaries, an approved plan (`docs/PLAN.md`) before any rendering |
| **Speech flow** | `speech:flow` detects fillers (um, uh), untranscribed hums, repeats, false starts and unnatural pauses from the audio itself, each with a proposed cut; `Media::Cuts` turns chosen cuts into jump cuts that land in the silence between words |
| **Virtual camera** | Vision-tracked speaker; wides, medium shots, punch-ins, slow pushes and pans written as camera beats; each jump cut opens on a contrasting framing; zooms never faster than 4.5 s; `safe` areas keep foreground heads out of frame |
| **Picture** | HLG/HDR → Rec.709 tone mapping, per-tile deflicker of LED/mains ripple, per-clip exposure/white-balance match, one shared look; optional stabilization (off for phone footage that the camera already stabilized) |
| **Audio** | Dialogue cleanup (rumble, denoise, de-ess, leveler, optional Demucs isolation), timeline mix with crossfades and ducking, two-pass loudness to −16 LUFS / −1.5 dBTP, optional ElevenLabs narration and music bed |
| **Graphics** | Native Swift motion-graphics renderer (`mgraphics`) for opening titles, lower thirds and end cards, rendered as ProRes 4444 alpha overlays; editable JSON templates included |
| **Finishing** | Optional music bed (supplied or ElevenLabs Music, beat analysis for timing), procedural sound effects (whoosh, riser, impact, tick…), Core Image / Metal picture effects (flash, dip, punch, glow, lens, streaks) |
| **Review** | Debug stills with crop/subject/safe-area overlays, contact sheets, half-res previews, QA re-transcription of the mix and the final render |
| **Delivery** | H.264/HEVC masters, X/Twitter and YouTube upload encodes |

## Requirements

- macOS 14+ on **Apple Silicon** (VideoToolbox, Vision, Metal, mlx-whisper)
- Xcode or the command line tools (Swift 5.9+): `xcode-select --install`
- Ruby 3.2+ with Bundler — the Ruby bundled with macOS is too old
- FFmpeg, ImageMagick, Python 3 and [uv](https://docs.astral.sh/uv/) (Whisper, Demucs and the speech-flow detector run
  in ephemeral uv environments, downloaded on first use)
- 16 GB RAM or more; 4K HDR sources are decoded one heavy job at a time (see [Memory safety](#memory-safety))

With [Homebrew](https://brew.sh), from a clone of this repository:

```sh
brew bundle                     # ruby, ffmpeg, imagemagick, python, uv (see Brewfile)
xcode-select --install          # if Swift is not installed yet

# Homebrew Ruby is keg-only: put it first in PATH (add this line to ~/.zshrc)
export PATH="$(brew --prefix ruby)/bin:$PATH"
ruby -v                         # 3.2 or newer
```

## Install

### As a Claude Code plugin (recommended)

```sh
claude plugin marketplace add makevoid/mk-video-editing
claude plugin install mk-video-editing@makevoid-video-editing --scope user
```

Start Claude Code in any folder that holds (or can reach) your footage and invoke `/mk-video-editing:mk-video-editing`,
or just describe the edit — the skill triggers when you supply video files to cut. The first project runs `setup`, which
installs gems and builds the three Swift tools (about a minute on a cold cache).

Optional paid narration/music: `/plugin configure mk-video-editing` and set the **Fal API key**. It is passed only to
the bundled MCP server; see [credentials](.claude/skills/mk-video-editing/references/credentials.md).

### As a standalone skill

Clone the repository and either use it as your editing workspace (Claude Code picks the skill up from
`.claude/skills/`, and `projects/` is git-ignored), or link it into your personal skills folder:

```sh
git clone https://github.com/makevoid/mk-video-editing.git
cd mk-video-editing
ln -s "$PWD/.claude/skills/mk-video-editing" ~/.claude/skills/mk-video-editing   # optional: every session

rake setup      # gems, Python venv, build medit / mgraphics / mvfx
rake doctor     # prerequisite check (STRICT=1 rake doctor fails on anything missing)
```

For paid narration in standalone use, export `FAL_AI_API_KEY` in the shell that starts Claude Code.

## Usage

Describe the edit in plain language, with absolute paths to the clips:

> Edit the four clips in `~/Movies/conference/` into a 5-minute excerpt of the talk. Opening title with the event name,
> talk title and speaker; a lower third when they first appear. Clean up the audio, remove the ums and long pauses, and
> keep the camera off the audience on the left.

Claude follows the workflow in `SKILL.md`: intake → analysis → plan for your approval → EDL generator → audio →
review stills → render → QA. Each project is a self-contained folder (e.g. `projects/my-talk/`) holding symlinked
sources, analysis, the EDL generator `edit/build_edl.rb`, docs (`BRIEF.md`, `PLAN.md`, `REVIEW.md`) and outputs. Your
original media is never copied or modified. Revisions are new versions (`final_v2.mp4`, `final_v3.mp4`…); delivered
masters are never overwritten.

Source filenames must be unique, including case differences. If two cameras produced the same filename, rename the
clips before importing; `init` reports the conflicting paths and leaves the project untouched.

### Running the tools directly

Everything goes through one Ruby entry point:

```sh
MV="ruby /abs/path/to/.claude/skills/mk-video-editing/scripts/mv.rb"
$MV init --project /abs/projects/my-talk --media /abs/clip1.MOV --media /abs/clip2.MOV --prompt-file brief.md
cd /abs/projects/my-talk
$MV --project . setup

$MV --project . 'edit:transcribe[analysis/transcripts,source/clip1.MOV]'
VERBATIM=1 $MV --project . 'edit:transcribe[analysis/transcripts_verbatim,source/clip1.MOV]'
REGION=0,0,1,0.62 DETECT_REGION=0.15,0.3,0.85,0.8 $MV --project . 'edit:analyze[source/clip1.MOV,analysis/clip1.json]'
SPACE=frame $MV --project . 'edit:track[analysis/clip1.json,analysis/clip1.track.json]'
$MV --project . 'speech:clean[audio/raw/clip1.wav,audio/clean/clip1.wav]'
$MV --project . 'speech:flow[analysis/transcripts_verbatim/clip1.json,audio/clean/clip1.wav,analysis/flow/clip1.json]'

ruby edit/build_edl.rb                                   # your generator writes edit/edl.json
$MV --project . 'speech:mix[edit/edl.json,audio/mix.wav]'
DEBUG=1 $MV --project . 'edit:stills[edit/edl.json,edit/review/v1,10,42,95]'
$MV --project . 'edit:render[edit/edl.json,output/final_v1.mp4]'
```

`$MV -T` lists every task with its arguments. The most used:

| Task | Purpose |
|---|---|
| `edit:transcribe` | Local word transcripts; `VERBATIM=1` keeps fillers |
| `edit:analyze` | Camera path, flicker tiles, color stats and people detection per source |
| `edit:track` | Speaker track (`SPACE=frame` for unstabilized renders, `SEED=x,y` to pick the speaker) |
| `speech:flow` | Filler / false start / repeat / pause detector with proposed cuts and a readable `.txt` |
| `speech:clean`, `speech:mix`, `speech:measure` | Dialogue cleanup, timeline mix + loudness, measurements |
| `voice:tts`, `music:score` | Narration line, music bed (paid, only on explicit request) |
| `graphics:render`, `graphics:preview` | Titles from JSON scenes (ProRes 4444 alpha), fast drafts |
| `sfx:gen`/`sfx:mix`, `vfx:stills`/`vfx:render` | Sound effects and picture effects from cue sheets |
| `edit:stills`, `edit:sheet`, `edit:preview` | Review stills, contact sheets, half-res drafts |
| `edit:render` | Final render of an EDL |
| `media:twitter`, `media:youtube` | Upload encodes |

The EDL schema (clips, camera beats, `safe`, `grade`, `deflicker`, `stabilize`, `audio_duck`, `audio_xfade`, overlays,
sounds) and a worked generator example are in
[`footage-editing.md`](.claude/skills/mk-video-editing/references/footage-editing.md).

## Memory safety

4K HDR decoding keeps frames in a system decoder process outside the job's own memory. On a 16 GB Mac, running several
heavy jobs at once can freeze the machine. The skill therefore runs one heavy job at a time, and every native render goes
through `Media::Guard`, which watches job + decoder memory and system free memory and stops the job before it gets
dangerous (`MEDIT_MAX_FOOTPRINT_MB`, default 3500; `MEDIT_MIN_FREE_PCT`, default 30). A typical 1080p render from 4K
sources peaks around 2–2.5 GB. Close memory-hungry apps before long renders.

## Layout

```
.claude-plugin/             plugin.json + marketplace.json (Claude Code plugin install)
.claude/skills/mk-video-editing/
  SKILL.md                  instructions Claude follows
  references/               footage editing, finishing (music/SFX/VFX), tasks, testing, credentials
  scripts/mv.rb             Ruby CLI entry point (rake tasks)
  scripts/mcp.rb            MCP server for paid Fal tasks in plugin sessions
  scripts/lib/media/        Ruby services: edit, speech, cuts, guard, ffmpeg, graphics, sfx, vfx
  scripts/lib/fal/          Fal client + ElevenLabs TTS/Music and Stable Audio SFX adapters
  scripts/lib/workflow/     plan approval, dependency waves for parallel sub-agents, progress journal
  scripts/tools/edit/       medit — Swift footage editor (analysis, virtual camera, deflicker, grade, render)
  scripts/tools/graphics/   mgraphics — Swift motion-graphics renderer, title templates in examples/
  scripts/tools/vfx/        mvfx — Swift video effects
  scripts/tools/python/     speech flow, local transcription, Demucs stems, beats/energy, cut detection, SFX mix
  scripts/spec/             RSpec suite
Brewfile                    command-line prerequisites
Rakefile                    rake setup / doctor / test
```

The motion-graphics renderer and VFX come from
[motion-graphics-music-video-skill-noimage](https://github.com/makevoid/motion-graphics-music-video-skill-noimage),
trimmed to what footage editing uses. Use that skill for beat-synced music videos.

## Development and tests

```sh
rake test                                  # everything (needs the full macOS toolchain)
PROFILE=core  rake test                    # contracts, CLI, cut helpers — fast, no media
PROFILE=media rake test                    # real FFmpeg / ImageMagick / Python
PROFILE=swift rake test                    # native renderers
(cd .claude/skills/mk-video-editing/scripts/tools/graphics && swift test)
claude --plugin-dir .                      # try local plugin changes
```

No test makes paid calls or needs footage; fixtures are synthesized. Projects run their own copy of `lib/` and
`tools/` (made at `init`), so after changing the skill, start a new project or rsync the changed files into the
existing one.

Contributions are welcome — camera and framing heuristics, grading and deflicker, speech-flow detection, title
templates, and lessons from real edits (as generic notes, without your footage). Please run `PROFILE=core rake test`
and, for Swift changes, the swift profile before opening a pull request.

## Network use and privacy

Transcription, analysis, editing, audio processing and rendering run locally; your footage never leaves the Mac by
default. Setup downloads gems and Python packages (the Swift tools have no third-party dependencies); the first transcription or Demucs run
downloads model weights. Explicitly requested Fal tasks (narration, music bed, prompt-based sound effects) send their text
prompts to Fal and incur charges. There is no telemetry.
Normal Claude conversation and tool-result handling still applies.

## License

[MIT](LICENSE)
