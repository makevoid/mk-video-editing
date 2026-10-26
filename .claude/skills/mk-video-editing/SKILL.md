---
name: mk-video-editing
description: Edit supplied camera/phone footage into a finished video — talks, keynotes, interviews, events — with transcript-driven selects, a stabilized virtual camera that tracks and reframes the speaker (wides, punch-ins, pushes, pans) over wide 4K shots, HDR→SDR, deflicker, per-clip color matching, dialogue cleanup and loudness, narration, native Swift motion-graphics titles, and optional music beds, sound effects and picture effects. Use when the user supplies video files to cut, reframe, grade, fix or title; not for generating footage.
license: MIT
---

# mk-video-editing

Turn supplied footage into a watchable, consistent edit: the right words in the right order, a camera that frames the subject well, a consistent picture, clean and level sound, and tasteful titles. The structure comes from the footage and what is said in it.

## What the skill can do

| Need | Tools | Cost | Reference |
| --- | --- | --- | --- |
| Word transcripts, filler/false-start/pause detection | `edit:transcribe` (mlx-whisper), `speech:flow` | free, local | [footage-editing.md](references/footage-editing.md) |
| Stabilize, track the speaker, reframe 4K wides (pushes, punch-ins, pans), HDR→SDR, deflicker, color match, dissolves, jump cuts | `edit:analyze`, `edit:track`, EDL + `medit` (`edit:render`) | free, local | [footage-editing.md](references/footage-editing.md) |
| Dialogue cleanup, mix, ducking, loudness | `speech:clean` (`ISOLATE=1` Demucs), `speech:mix`, `speech:measure` | free, local | [footage-editing.md](references/footage-editing.md) |
| Narration | `voice:tts` (ElevenLabs via Fal) | paid, approved | [credentials.md](references/credentials.md) |
| Titles, lower thirds, end cards (ProRes 4444 alpha) | `mgraphics` JSON scenes, `graphics:render`, templates in `scripts/tools/graphics/examples/` | free, local | [graphics README](scripts/tools/graphics/README.md) |
| Music bed under the edit | EDL `music` (ducked), `music:score` (ElevenLabs Music via Fal), `audio:analyze` for beat timing | paid only if generated | [finishing.md](references/finishing.md) |
| Sound effects on titles/transitions | `SoundSynth` (`synth:` whoosh, riser, impact, tick…), `sfx:gen`/`sfx:mix` or EDL `sounds` | free (Stable Audio `prompt:` paid) | [finishing.md](references/finishing.md) |
| Picture effects (flash, dip, punch, glow, lens, streaks…) | `mvfx` cue sheets, `vfx:stills`/`vfx:render` | free, local | [finishing.md](references/finishing.md) |
| Delivery encodes | `media:twitter`, `media:youtube`, `media:faststart` | free, local | [tasks.md](references/tasks.md) |
| Parallel sub-agents on independent jobs | `work:next`/`work:accept`/`work:log`/`work:watch` | free | [tasks.md](references/tasks.md#approval-waves-and-progress) |

Every task with its arguments and options is in [tasks.md](references/tasks.md). Test profiles are in [testing.md](references/testing.md).

## Execution contract

Designed for Claude Code on macOS 14+ on Apple Silicon (Swift 5.9+, Ruby 3.2+, Bundler, FFmpeg, ImageMagick, uv for local Whisper). Run `doctor` first when a task fails on a missing tool; `setup` builds the Swift tools. **Ruby is the only execution entry layer**: run `ruby "${CLAUDE_SKILL_DIR}/scripts/mv.rb" --project /abs/project 'task[args]'`. Tasks delegate to Ruby services (`lib/media/edit.rb`, `speech.rb`, `guard.rb`, …) that drive the native Swift tools `medit` (`scripts/tools/edit`), `mgraphics` (`scripts/tools/graphics`) and `mvfx` (`scripts/tools/vfx`). Add a Ruby method and a thin task when a capability is missing. A project runs **its own copy** of `lib/` and `tools/`: after changing the skill, `rsync` the changed files into the project.

### Memory safety (mandatory)

4K/HDR hardware decode keeps frames in `VTDecoderXPCService`, outside the job's own footprint. On a 16 GB machine without swap, exhausting memory **freezes the computer** instead of slowing it down. Therefore:

- Run **one heavy job at a time** (medit analyze/render/stills, mgraphics encodes, Demucs, big ffmpeg encodes). Never launch several in parallel or in background alongside each other; chain them sequentially in one background command if needed. `JOBS` stays 1 unless RAM ≥ 32 GB.
- Every medit/mgraphics/mvfx render call goes through `Media::Guard` (automatic in the Ruby services): it samples job + decoder footprint and kernel free % every 0.3 s and SIGKILLs before `MEDIT_MAX_FOOTPRINT_MB` (default 3500) or below `MEDIT_MIN_FREE_PCT` (default 30). It refuses to start when free memory is already low. All three renderers default to `JOBS=1`; parallel chunks require an explicit `JOBS` setting.
- Validate any new decode/render code path on a **short range with tight limits first** (`TO=15 MEDIT_MAX_FOOTPRINT_MB=1500 MEDIT_GUARD_LOG=/path/log`), check the log is flat, then run full length.
- In Swift media loops wrap each `copyNextSampleBuffer` and Core Image render in `autoreleasepool` (async code never drains the default pool: frames leak at ~1.5 GB/s).

Measured steady state: analysis ≈ 1.0 GB (job + decoder) per 4K HLG source; a render with a dissolve opens two sources.

## 1. Intake

Ask only for what is missing: footage paths, what the edit is (talk excerpt, recap…), titles/credits text, target length, narration wishes. Initialize with the media (symlinked, never copied or modified):

```sh
ruby "${CLAUDE_SKILL_DIR}/scripts/mv.rb" init --project /abs/project --media /abs/clip1.MOV --media /abs/clip2.MOV --prompt-file /abs/brief.md
ruby "${CLAUDE_SKILL_DIR}/scripts/mv.rb" --project /abs/project setup
```

Probe each source (`ffprobe`: size, fps, duration, HDR transfer). Extract audio (`audio/raw/*.wav`, 48 kHz) and transcribe locally: `edit:transcribe[analysis/transcripts,source/...]` (mlx-whisper large-v3-turbo, word times; free). Read every transcript and write what each clip says, with timestamps, into `docs/BRIEF.md`. Web-search event facts used in titles and record the sources.

## 2. Analyze (sequentially)

```sh
REGION=0,0,1,0.62 DETECT_REGION=0.15,0.3,0.85,0.8 mv 'edit:analyze[source/A.MOV,analysis/A.json]'   # one at a time
mv 'edit:track[analysis/A.json,analysis/A.track.json]'      # SEED=x,y when the speaker is not found early; SPACE=frame for stabilize: 0
mv 'edit:stats[analysis/A.json,from,to]'
```

- `REGION` limits stabilization (phase correlation) to static scenery (stage, screens), excluding the audience.
- `DETECT_REGION` crops the stage for Vision people detection at ~2× resolution — essential for a far speaker (detection went from 2 % to 40–90 % of samples).
- Tracks are world-locked (stabilization removed), continuity-picked, and drop wide foreground boxes (heads) via `max_aspect`.
- **Phone footage (iPhone etc.) is already stabilized in camera: render it with `stabilize: 0` and `SPACE=frame` tracks.** Our stabilizer can mistake moving slide content for camera motion and add sudden horizontal jumps. Check: count frames with `|Δshift| > 8 px` in the analysis; residual shake on iPhone 4K measured ≈ 0.9 px RMS, not worth correcting.

### Speech flow (fillers, false starts, repeats, unnatural pauses)

```sh
VERBATIM=1 mv 'edit:transcribe[analysis/transcripts_verbatim,source/A.MOV]'   # primes Whisper to write um/uh
mv 'speech:flow[analysis/transcripts_verbatim/A.json,audio/clean/A.wav,analysis/flow/A.json]'   # read analysis/flow/A.txt
```

The detector measures pauses acoustically (energy + voicing, not Whisper word times), classifies them (sentence/comma/phrase) and flags fillers, untranscribed hums, repeats and possible false starts, each with a proposed `cut`. Decide each by meaning, then apply cuts with `Media::Cuts` in the generator (step 4). Look for self-corrections and abandoned sentences ("in order to be—", an unfinished last sentence before applause) by reading the `.txt`; the detector only proposes candidates.
- Whole-frame color stats are dominated by projection screens; match exposure on the speaker area (tiles around the track) and judge white balance on stills.

## 3. Plan and approve

Write `docs/PLAN.md`: selects table (source, in/out at sentence boundaries, content, join: dissolve/jump cut), titles, narration text, camera language, picture and audio treatment. Summarize in chat; record approval with `NOTE='...' plan:approve` (also required before paid calls, e.g. ElevenLabs narration via `voice:tts`; see [credentials.md](references/credentials.md) — in plugin sessions paid tasks run through the `mk-video-editing` MCP server).

## 4. Build the EDL with a generator script

Write `edit/build_edl.rb` (see [footage-editing.md](references/footage-editing.md) for the full EDL schema and a worked example). Define a shot vocabulary (WIDE zoom≈1.2–1.4, MWIDE fit≈0.4, MED fit≈0.56, PUNCH fit≈0.72 capped by `max_zoom` 3.6) and write camera beats in **source seconds** taken from the transcript: slow pushes over 6–12 s, cut punch-ins on emphasis lines, cut to wide on topic/slide changes, reframe on every jump cut. Per clip: `safe` area (keep distracting foreground out), `deflicker`, `grade` match; one shared `look`. Overlays are ProRes 4444 alpha titles (see Titles below).

Remove words and pauses inside a select with `lib/media/cuts.rb`: `Media::Cuts.pause_cuts` (auto-shorten unnatural pauses), `Media::Cuts.segments` (split the select into jump-cut segments, snap boundaries to the quietest point between words, open each segment on a contrasting framing, keep every zoom ≥ 4.5 s), `Media::Cuts.text` (log what each cut removes to `edit/cuts.txt`). Start and end each select in silence and away from camera handling (check shift velocity near the edges). Worked example in [footage-editing.md](references/footage-editing.md#removing-fillers-false-starts-repeats-and-pauses-jump-cuts).

## 5. Audio

`speech:clean[audio/raw/A.wav,audio/clean/A.wav]` (PRESET=room: rumble cut, FFT denoise, mud cut, presence, de-ess, gentle expander, leveler; `ISOLATE=1` for local Demucs vocals). Add narration with `voice:tts` when requested (`MODEL=v4` for Eleven v4). Add a music bed only when the brief asks for one: a supplied track or `music:score`, placed as EDL `music` ([finishing.md](references/finishing.md#soundtrack-music-bed)). Then run `speech:mix[edit/edl.json,audio/mix.wav]`. It mixes the clip audio with crossfades on dissolves (`audio_xfade: 0.15` keeps the last word before a 0.6 s dissolve), `audio_duck` under narration, `sounds`, and `music` with sidechain ducking, then applies two-pass loudnorm to −16 LUFS / −1.5 dBTP.

## 6. Review, render, deliver

- `DEBUG=1 edit:stills[edit/edl.json,edit/review/vN,t1,t2,...]` — each still plus the full source frame with crop (red), subject (green) and safe area (yellow). Check framing, headroom, foreground intrusions, exposure/WB continuity across cuts.
- `edit:sheet` contact sheets; `edit:preview[edl,out.mp4,from,to]` half-res drafts of changed ranges.
- `edit:render[edit/edl.json,output/final.mp4]` (JOBS=1). Never overwrite a delivered master.
- QA before rendering video: `speech:mix`, then `edit:transcribe` the mix and read the words around each clip's `at` (cheap; catches clipped words and lone-word flashes). After the render, re-transcribe the final; log versions and issues in `docs/REVIEW.md`.

Deliver the video, the plan/brief/review docs and a short summary of choices and known issues. Run RSpec profiles from [testing.md](references/testing.md) after changing the toolkit and `swift test` in `tools/graphics` after renderer changes.

## Titles

Start from the templates in `scripts/tools/graphics/examples/`: `opening_title.json`, `lower_third.json` and `end_card.json` (1920×1080, AvenirNext, one accent color). Copy them to `edit/titles/`, change the text and timing, or generate them from `edit/make_titles.rb` when there are several. Web-check names, roles and event facts.

1. Render stills with `ONLY=` over a frame of the shot (`PLATE=`) and check legibility, the safe margin and accents.
2. Render `CODEC=prores4444 SUPERSAMPLE=2 graphics:render[edit/titles/x.json,edit/titles/x.mov,frames,1920,1080,fps]` at the edit's fps.
3. Place it as an EDL `overlays` entry, darkening or blurring the plate under an opening card with camera `dim`/`blur`.

The scene format (nodes, tracks, easing, glow, fonts) is in the [graphics README](scripts/tools/graphics/README.md). After renderer changes, run `swift test` in `scripts/tools/graphics` and compare old and new title renders byte for byte.

## Finishing (optional)

A music bed, sound effects and picture effects are optional passes, described in [finishing.md](references/finishing.md):
- the bed goes into `speech:mix` before the render;
- SFX (`sfx.yml`) and VFX (`cues.yml`) run on the rendered master and always write a new file.

Use them when the brief asks for a promo or recap feel. Clean talk edits rarely need them.

## Parallel work

For long edits, split independent jobs (titles, narration lines, review stills per section, QA transcripts) into `config/production.json` with their `depends`. Hand them to sub-agents through `work:next`, have them report with `work:log`, and accept each one after review (`work:accept`). Sub-agents may write scenes, scripts and docs in parallel. **Heavy media jobs (medit, mgraphics/mvfx encodes, Demucs) still run one at a time** (memory safety above).
