---
name: mk-video-editing
description: Edit supplied camera/phone footage into a finished video — talks, keynotes, interviews, events — with transcript-driven selects, a stabilized virtual camera that tracks and reframes the speaker (wides, punch-ins, pushes, pans) over wide 4K shots, HDR→SDR, deflicker, per-clip color matching, dialogue cleanup and loudness, narration, and native Swift motion-graphics titles. Use when the user supplies video files to cut, reframe, grade, fix or title; not for generating footage.
license: MIT
---

# mk-video-editing

Turn supplied footage into a watchable, homogeneous edit: the right words in the right order, a camera that frames the subject well, a consistent picture, clean and level sound, and tasteful titles. Motion graphics (the bundled Swift renderer) are used for titles, lower thirds and end cards; the music-video storyboard workflow is **not** used — the structure comes from the footage and what is said in it, never from an audio track's beats.

## Execution contract

Designed for Claude Code on macOS 14+ on Apple Silicon (Swift 5.9+, Ruby 3.2+, Bundler, FFmpeg, ImageMagick, uv for local Whisper). Run `doctor` first when a task fails on a missing tool; `setup` builds the Swift tools. **Ruby is the only execution entry layer**: run `ruby "${CLAUDE_SKILL_DIR}/scripts/mv.rb" --project /abs/project 'task[args]'`. Tasks delegate to Ruby services (`lib/media/edit.rb`, `speech.rb`, `guard.rb`) that drive the native editor `medit` (`scripts/tools/edit`) and `mgraphics` (`scripts/tools/graphics`). Add a Ruby method and a thin task when a capability is missing. A project runs **its own copy** of `lib/` and `tools/`: after changing the skill, `rsync` the changed files into the project.

### Memory safety (mandatory)

4K/HDR hardware decode keeps frames in `VTDecoderXPCService`, outside the job's own footprint. On a 16 GB machine without swap, exhausting memory **freezes the computer** instead of slowing it down. Therefore:

- Run **one heavy job at a time** (medit analyze/render/stills, mgraphics encodes, Demucs, big ffmpeg encodes). Never launch several in parallel or in background alongside each other; chain them sequentially in one background command if needed. `JOBS` stays 1 unless RAM ≥ 32 GB.
- Every medit/mgraphics call goes through `Media::Guard` (automatic in `Media::Edit`): it samples job + decoder footprint and kernel free % every 0.3 s and SIGKILLs before `MEDIT_MAX_FOOTPRINT_MB` (default 3500) or below `MEDIT_MIN_FREE_PCT` (default 30). It refuses to start when free memory is already low.
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

Write `edit/build_edl.rb` (see [footage-editing.md](references/footage-editing.md) for the full EDL schema and a worked example). Define a shot vocabulary (WIDE zoom≈1.2–1.4, MWIDE fit≈0.4, MED fit≈0.56, PUNCH fit≈0.72 capped by `max_zoom` 3.6) and write camera beats in **source seconds** taken from the transcript: slow pushes over 6–12 s, cut punch-ins on emphasis lines, cut to wide on topic/slide changes, reframe on every jump cut. Per clip: `safe` area (keep distracting foreground out), `deflicker`, `grade` match; one shared `look`. Overlays are ProRes 4444 alpha titles rendered from mgraphics scenes (`edit/titles/*.json`, see the graphics README).

Remove words and pauses inside a select with `lib/media/cuts.rb`: `Media::Cuts.pause_cuts` (auto-shorten unnatural pauses), `Media::Cuts.segments` (split the select into jump-cut segments, snap boundaries to the quietest point between words, open each segment on a contrasting framing, keep every zoom ≥ 4.5 s), `Media::Cuts.text` (log what each cut removes to `edit/cuts.txt`). Start and end each select in silence and away from camera handling (check shift velocity near the edges). Worked example in [footage-editing.md](references/footage-editing.md#removing-fillers-false-starts-repeats-and-pauses-jump-cuts).

## 5. Audio

`speech:clean[audio/raw/A.wav,audio/clean/A.wav]` (PRESET=room: rumble cut, FFT denoise, mud cut, presence, de-ess, gentle expander, leveler; `ISOLATE=1` for local Demucs vocals), narration via `voice:tts` when requested (`MODEL=v4` for Eleven v4), a music bed via `music:score` (ElevenLabs Music v2.5) when requested, then `speech:mix[edit/edl.json,audio/mix.wav]` (clip audio with crossfades on dissolves — `audio_xfade: 0.15` keeps the last word before a 0.6 s dissolve — `audio_duck` under narration, `sounds`, optional `music` with sidechain ducking, two-pass loudnorm to −16 LUFS / −1.5 dBTP).

## 6. Review, render, deliver

- `DEBUG=1 edit:stills[edit/edl.json,edit/review/vN,t1,t2,...]` — each still plus the full source frame with crop (red), subject (green) and safe area (yellow). Check framing, headroom, foreground intrusions, exposure/WB continuity across cuts.
- `edit:sheet` contact sheets; `edit:preview[edl,out.mp4,from,to]` half-res drafts of changed ranges.
- `edit:render[edit/edl.json,output/final.mp4]` (JOBS=1). Never overwrite a delivered master.
- QA before rendering video: `speech:mix`, then `edit:transcribe` the mix and read the words around each clip's `at` (cheap; catches clipped words and lone-word flashes). After the render, re-transcribe the final; log versions and issues in `docs/REVIEW.md`.

Deliver the video, the plan/brief/review docs and a short summary of choices and known issues. Run RSpec profiles from [testing.md](references/testing.md) after changing the toolkit and `swift test` in `tools/graphics` after renderer changes.

## Motion graphics

Titles and graphic inserts use the native renderer's JSON scenes (`scripts/tools/graphics/README.md`, [scene-cookbook.md](references/scene-cookbook.md)). Render with `mgraphics scene.json --out title.mov --codec prores4444 --width 1920 --height 1080 --fps 30 --frames N --supersample 2` (through `Media::Guard`) and place as EDL `overlays`. The older beat-synced music-video workflow and its references ([native-workflow.md](references/native-workflow.md), [planning.md](references/planning.md)) remain available when the user explicitly wants a motion-graphics piece.
