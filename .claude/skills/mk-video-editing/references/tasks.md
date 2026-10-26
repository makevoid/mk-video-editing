# Ruby entry points and task reference

## Layout

```text
mk-video-editing/
  SKILL.md                       workflow (start here)
  references/
    footage-editing.md           medit, EDL schema, generator pattern, jump cuts, lessons
    finishing.md                 music bed, sound effects, VFX, order of passes
    tasks.md                     this file: every task and the directory layers
    credentials.md               optional Fal key (narration, music, prompt SFX)
    testing.md                   RSpec profiles and behavioral review
  scripts/
    mv.rb                        Ruby CLI: init, setup, every task
    mcp.rb                       MCP server for paid tasks in plugin sessions
    Rakefile, Gemfile(.lock)     task registry and Ruby dependencies (incl. RSpec)
    requirements.txt             Python packages for the project venv (numpy, Pillow)
    lib/
      tasks.rb                   thin rake declarations from Toolkit::Operations::TASKS
      toolkit/                   operations (task bodies), initializer, MCP server, fonts
      workflow/                  plan approval, dependency waves, worker journal
      media/                     services: edit (medit), speech, cuts, graphics, anim, vfx, sfx, guard, ffmpeg, python…
      fal/                       queue client, schemas, ElevenLabs TTS/Music and Stable Audio SFX adapters
    tools/
      edit/                      medit: Swift footage editor (analysis, virtual camera, deflicker, grade, render)
      graphics/                  MotionGraphics library + mgraphics CLI (titles, SoundSynth); examples/ title templates
      vfx/                       mvfx: Core Image + Metal effects on rendered video
      python/                    transcription, speech flow, Demucs stems, beats/energy, cut detection, SFX mix
    spec/                        RSpec contracts and end-to-end tests
```

`init` copies the runtime (`scripts/` minus build caches and outputs) into the project. It also copies `SKILL.md` and `references/` into `.skill/`, and creates `source/` (symlinks to the footage), `audio/`, `analysis/`, `edit/`, `docs/`, `output/`, `scenes/` and `config/`. A project runs **its own copy** of `lib/` and `tools/`: after changing the skill, `rsync` the changed files into the project and rebuild its Swift tools.

Run tasks with `ruby "${CLAUDE_SKILL_DIR}/scripts/mv.rb" --project /abs/project 'task[a,b]'`. Inside a project, `bundle exec rake 'task[a,b]'` is equivalent. In examples below, `mv` stands for the former. Quote bracket expressions in zsh. Rake splits arguments on commas, so rename inputs whose names contain commas. Options are environment variables (`JOBS=1 mv …`).

## Setup

| Task | Purpose |
| --- | --- |
| `init --project DIR --media PATH… --prompt-file brief.md` | New footage project (media is symlinked, never copied or changed) |
| `setup` | Bundler, `.venv` with numpy/Pillow, then builds mgraphics, mvfx and medit |
| `doctor` | JSON checks: ffmpeg, ffprobe, magick, python3, swift, uv, Ruby ≥ 3.2, Apple Silicon, Python packages, built tools; `STRICT=1` fails on a missing one |
| `edit:build`, `graphics:build`, `vfx:build` | Rebuild one Swift tool after changing its sources |
| `fonts:list`, `fonts:copy[config/fonts.json]` | List installed macOS TTF/OTF faces, then copy the selected ones into the project's `tools/graphics/fonts/` (refuses to replace different bytes) |
| `test` | RSpec; `PROFILE=all|core|media|swift` ([testing.md](testing.md)) |

`MV_PYTHON` overrides the venv interpreter. Before `setup`, Python scripts run in an ephemeral `uv` environment. `MV_WHISPER_MODEL`, `MV_WHISPER_LANG` and `MV_DEMUCS_MODEL` choose the local models.

## Footage editing (medit)

The full reference is in [footage-editing.md](footage-editing.md).

| Task | Purpose |
| --- | --- |
| `edit:transcribe[out_dir,source…]` | mlx-whisper word transcripts, one JSON per source; `VERBATIM=1` keeps fillers |
| `edit:analyze[source,out.json]` | Stabilization path, flicker tiles, color stats, Vision people; `REGION`, `DETECT_REGION`, `DETECT_EVERY`, `FROM`/`TO` |
| `edit:track[analysis,out.json]` | Speaker track; `SEED`, `STAGE`, `SIZE`, `SPACE=frame` |
| `edit:stats[analysis,from,to]` | Exposure/color/flicker summary |
| `edit:stills[edl,dir,t…]` | Review stills; `DEBUG=1` adds crop/subject/safe outlines on the full frame |
| `edit:sheet[edl,out.jpg,every_s]` | Contact sheet of the timeline |
| `edit:preview[edl,out.mp4,from,to]` | Half-res draft of a range; `SCALE`, `JOBS` |
| `edit:render[edl,out.mp4]` | Final; `FROM`/`TO`, `BITRATE`, `CODEC`, `JOBS` (keep 1 below 32 GB RAM) |

## Speech and narration

| Task | Purpose |
| --- | --- |
| `speech:clean[in,out.wav]` | Dialogue cleanup; `PRESET=room|light|<ffmpeg chain>`, `ISOLATE=1` (local Demucs vocals), `AMBIENCE` |
| `speech:flow[transcript,audio,out.json]` | Fillers, hums, repeats, false starts and pauses with proposed cuts; writes `out.txt` to read |
| `speech:mix[edl,out.wav]` | Timeline mix: clip audio, crossfades, `audio_duck`, `sounds`, ducked `music`, two-pass loudnorm (`LUFS`, `TP`) |
| `speech:measure[path…]`, `speech:loudnorm[in,out.wav]` | Loudness/noise report; standalone normalization |
| `voice:tts[text.txt,out.mp3]` | Narration via Fal ElevenLabs (paid, approved plans only); `VOICE`, `SPEED`, `STABILITY`, `STYLE`, `MODEL=v4` |
| `audio:transcribe_local[audio,out.json,from,seconds]` | mlx-whisper on any audio range |
| `media:stems_local[audio,out_dir,from,seconds]` | Local Demucs: vocals, no_vocals, drums, bass, other |

## Titles and graphics (mgraphics)

The scene format and title templates are in `scripts/tools/graphics/README.md`.

```sh
ONLY=0,60,150 mv 'graphics:render[edit/titles/opening.json,edit/review/opening,300,1920,1080,30]'      # stills
CODEC=prores4444 SUPERSAMPLE=2 mv 'graphics:render[edit/titles/opening.json,edit/titles/opening.mov,300,1920,1080,30]'
mv 'graphics:preview[edit/titles/opening.json,output/opening_draft.mp4,0,6]'                               # 1x, 30 fps draft
```

`graphics:render[scene,out,frames,width,height,fps]` takes `frames` = seconds × fps and accepts `PLATE`, `AUDIO`, `CODEC`, `SUPERSAMPLE`, `BITRATE`, `GLOW=gpu|cg`, `JOBS` and `ONLY`. `graphics:preview` takes `FPS`, `SUPERSAMPLE`, `WIDTH`, `HEIGHT`, `JOBS`, `GLOW` and `AUDIO`. `anim:render` writes PNG frames of a scene, and `graphics:benchmark` reports fps without writing files.

## Music, sound effects and VFX

The recipes are in [finishing.md](finishing.md).

| Task | Purpose |
| --- | --- |
| `music:score[prompt.txt,out.mp3,seconds]` | Instrumental bed via Fal ElevenLabs Music v2.5 (paid, approved plans only) |
| `audio:analyze[audio,out_dir]` | `beats.json` + `energy.json`, for timing titles or cuts to music |
| `sfx:gen`, `sfx:mix` | `SFX=name`: synthesize the sounds in `prompts/<name>/sfx.yml`, then mix them on their cues |
| `vfx:analyze`, `vfx:stills[f…]`, `vfx:clip[from,to]`, `vfx:render` | `VFX=name`: cue analysis, stills, interval, full render from `prompts/<name>/cues.yml` |
| `media:cuts[video,out.json]` | Picture cut detection |

## Media utilities and delivery

| Task | Purpose |
| --- | --- |
| `media:probe[path]` | ffprobe summary |
| `media:frame[video,s,out.png]`, `media:frames[video,dir,fps,width]` | One frame; frames at an interval |
| `media:sheet[video,out.jpg]`, `media:montage[out.jpg,cols,width,img…]` | Contact sheets |
| `media:cut[video,out.mp4,start,s]`, `media:audio_cut[src,out.wav,start,s]` | Cut a range |
| `media:concat[out.mp4,a,b…]`, `media:mux[video,audio,out.mp4]` | Join clips; replace audio |
| `media:twitter[video,out.mp4]` | X upload spec (below) |
| `media:youtube[video,out.mp4]` | 4K master: scaled to fill 3840×2160, converted and tagged BT.709 |
| `media:faststart[video,out.mp4]` | Lossless copy with the index moved to the front |

**X/Twitter delivery.** `media:twitter[video,out.mp4]` produces:
- MP4, H.264 High@4.2, yuv420p, square pixels, tagged BT.709 (untagged/BT.601 sources are converted);
- the 16:9 1920×1080, 9:16 1080×1920 or 1:1 1080×1080 box, fitted without upscaling (a source within 1 % of the ratio is fill-cropped);
- the source frame rate, capped at 60;
- closed 1 s GOPs and faststart;
- CRF 16 under a 24 Mb/s cap (`CRF`, `MAX_MBPS` ≤ 25, `TUNE`);
- AAC-LC audio.

It refuses to overwrite `out`, and reports `mbps`, `fits_free` (≤ 140 s, ≤ 512 MB) and `fits_premium`.

## Approval, waves and progress

```sh
NOTE='User approved the plan in chat' mv plan:approve      # binds approval to the current docs/PLAN.md
mv work:next                                               # SIZE=… allocates dependency-ready jobs from config/production.json
JOB=titles EVIDENCE=edit/review/titles.md mv work:accept
AGENT=titles EVENT=render MESSAGE='opening.mov done' mv work:log
mv work:watch                                              # LIMIT=…
```

Paid tasks check the approval and fail if `docs/PLAN.md` changed after it was recorded. Waves let parallel sub-agents take independent jobs (titles, narration lines, review stills) and log progress. Each job names its `depends`, and two jobs never share a `run`. Heavy media jobs still run one at a time ([SKILL.md](../SKILL.md#memory-safety-mandatory)).

## Fal schemas

`openapi:fetch` saves the current input schemas of the bundled Fal endpoints (ElevenLabs TTS v2/v4, ElevenLabs Music, Stable Audio SFX) under `specs/`, and `openapi:summary` prints them. Requests are validated against a saved schema before submission. Identical requests resume from their receipt in `output/requests/`; `NEW_REQUEST=1` forces a fresh, paid request.

To add a capability, put a method on a service under `lib/media/`, add a task line to `Toolkit::Operations::TASKS` and its `call` branch, and add a spec.
