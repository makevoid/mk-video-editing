# Footage editing reference (medit)

`medit` (`scripts/tools/edit`) is a native Swift editor: AVFoundation decode (HDR → Rec.709 tone mapping), Core Image
picture pipeline, the MotionGraphics compositor/encoder. It reads an **EDL JSON** and renders frames; `Media::Edit`
(`lib/media/edit.rb`) wraps it with the memory guard, chunking and audio muxing.

## Commands (through mv.rb)

| Task | Purpose |
|---|---|
| `edit:analyze[src,out.json]` | One decode pass: stabilization path (FFT phase correlation, sub-pixel, re-anchored), 16×18 flicker tiles, luma percentiles, mean RGB, Vision people boxes. `REGION`, `DETECT_REGION`, `DETECT_EVERY`, `FROM`/`TO`. |
| `edit:track[analysis,out.json]` | Speaker track. World space by default (stabilization removed); `SPACE=frame` for clips rendered with `stabilize: 0`. `SEED=x,y`, `STAGE=ymin,ymax`, `SIZE=hmin,hmax`. |
| `edit:stats[analysis,from,to]` | Exposure/color/ripple summary. |
| `edit:transcribe[dir,src...]` | Local mlx-whisper word transcripts. `VERBATIM=1` primes Whisper with a disfluent prompt so it writes fillers (um, uh) it normally drops — use for `speech:flow`. |
| `speech:flow[transcript,audio,out.json]` | Speech-flow detector: fillers, untranscribed hums, repeats, possible false starts, unnatural pauses, each with a proposed `cut`; plus `words` (speech centroids), `speech_runs` and a 10 ms `energy` curve for snapping cuts. Writes `out.txt` (phrases with pause lengths + markers) to read. |
| `edit:stills[edl,dir,t...]` | Review PNGs; `DEBUG=1` adds the source frame with crop/subject/safe outlines. |
| `edit:sheet[edl,out.jpg,every]` | Contact sheet. |
| `edit:preview[edl,out.mp4,from,to]` | Half-res draft of a range. |
| `edit:render[edl,out.mp4]` | Final. `FROM`/`TO`, `BITRATE`, `CODEC=h264|hevc`, `JOBS` (keep 1 below 32 GB RAM). |
| `speech:clean`, `speech:mix`, `speech:measure`, `speech:loudnorm`, `voice:tts` | Dialogue cleanup, timeline mix, loudness, narration (`MODEL=v4` = Eleven v4, audio tags, no speed/style). |
| `music:score[prompt.txt,out.mp3,seconds]` | Instrumental bed with ElevenLabs Music v2.5 (paid). Ask for the final timeline length + ~0.5 s; place it as EDL `music` (ducked under narration). |

Debug env for medit: `MEDIT_DEBUG_DEFLICKER=1` (per-frame deflicker log), `MEDIT_GUARD_LOG=path` (memory samples).

## EDL schema

Top level: `width`, `height`, `fps` (default 1920×1080@30), `audio` (final mix muxed by render), `duration`,
`clips`, `overlays`, `look` (Grade applied to everything), `fade_in`, `fade_out`. Keys not used by medit (`sounds`,
`music`, `duck`, per-clip `audio`, `audio_gain_db`, `audio_duck`) drive `speech:mix`. A sound with `duck_clips: db`
(narration) ducks every overlapping clip's audio by `db` over its span, ramped by `duck_ramp` (0.25 s), so voice-over on
live sound needs no hand-written `audio_duck`. `duck: {mode: "envelope", …}` ducks the music by an exact gain envelope
([finishing.md](finishing.md#soundtrack-music-bed)).

Clip: `source`, `in`, `out` (source s), `at` (timeline s), `analysis`, `track`, `stabilize` (1 = world-locked from the
analysis path, default; **0 = off** — use for in-camera stabilized phone footage, with a `SPACE=frame` track),
`follow_smooth` (s, 0.8), `deadzone` (0.02 of frame), `fit_smooth` (s, 2), `max_zoom` (3.6), `anchor`,
`safe` [x0,y0,x1,y1] (crop never leaves it), `deflicker` {strength, window (source frames, 0 = auto period)},
`grade`, `camera` [keys], `transition` (dissolve-in seconds, overlapping the previous clip), `fade_in`, `fade_out`,
`speed` (0.5 = half-speed slow motion: the clip lasts (out − in) / speed on the timeline; a 60 fps source on a 30 fps
timeline stays smooth at exactly 0.5, other fractions repeat frames), `label`. Mix-only keys: `audio`,
`audio_gain_db`, `audio_duck` [[t0, t1, db, ramp]] (clip-local s), `audio_xfade` (audio crossfade into this clip;
default = `transition` — set 0.15 under a 0.6 s dissolve so the last word survives), `mute: true` (picture only; for
noisy B-roll under narration and music; slowed clips that keep sound get `atempo`).

Camera key (clip-local `t`, values fill forward): `zoom` (source width / crop width; 2.0 = 1:1 at 1080p from 4K) or
`fit` (speaker box height / crop height), `x`,`y` (crop center, normalized world coords when `follow` 0), `follow`
(0..1 blend to the tracked speaker), `frame` [fx,fy] (where the speaker box center sits in the crop), `ease`
(`linear`, `in`, `out`, `inOut`, `smooth`, `cut` = hold then jump), `blur` (px), `dim` (0..1).

Grade: `exposure` (EV), `gain` [r,g,b], `temperature` (6500 neutral), `tint`, `contrast`, `saturation`, `vibrance`,
`lift`, `gamma`, `highlights` (1 = none, lower recovers), `shadows` (0 = none), `sharpen`, `vignette` (0..1, centered
`CIVignetteEffect`; 0.25 is gentle), `hue_shift` [center°, width°, shift°, min_saturation] (secondary correction via a
33³ color cube: rotates only saturated hues near `center`, cosine falloff over ±`width`; colors below
min_saturation − 0.15 untouched, so skin stays put).

Overlay: `source` (ProRes 4444 alpha .mov or any video), `at`, `from`, `duration`, `opacity`, `fade_in`, `fade_out`,
`blend`.

## Generator pattern

Write `edit/build_edl.rb`; keep camera beats in source seconds next to the transcript line they serve:

```ruby
WIDE  = { zoom: 1.4, follow: 0.75, frame: [0.58, 0.52] }   # follow < ~0.7 lets a walking speaker reach the edge
MWIDE = { fit: 0.40, follow: 1, frame: [0.58, 0.50] }
MED   = { fit: 0.56, follow: 1, frame: [0.54, 0.50] }
PUNCH = { fit: 0.72, follow: 1, frame: [0.50, 0.52] }

clip("B main argument", "A", 17.1, 56.6, 0.6, [
  [17.1, MWIDE],
  [31.0, MED],                       # slow push into the key sentence
  [32.25, WIDE, { ease: "cut" }],    # topic change -> wide
  [47.9, PUNCH, { ease: "cut" }],    # emphasis line: the headline number
])
```

Place clips sequentially, subtracting each dissolve from `at`. Duck the speaker under narration with `duck_clips: -18`
on the narration sound (or by hand with `audio_duck: [[t0, t1, db, ramp]]`, clip-local s). Start a narration line at the
clip's `at` when the clip opens mid-speech: the ramp then begins before the cut and the first frame is already ducked.

## Removing fillers, false starts, repeats and pauses (jump cuts)

1. `VERBATIM=1 mv 'edit:transcribe[analysis/transcripts_verbatim,source/A.MOV]'` (one source at a time).
2. `mv 'speech:flow[analysis/transcripts_verbatim/A.json,audio/clean/A.wav,analysis/flow/A.json]'`; read
   `analysis/flow/A.txt`. Candidates are proposals: decide each by meaning (a "false start?" may be a dramatic pause;
   a self-correction like "brought into the system, included in the system" is cut by hand).
3. In `edit/build_edl.rb` use `lib/media/cuts.rb`:

```ruby
require_relative "../lib/media/cuts"
fl   = Media::Cuts.flow("analysis/flow/A.json")
cuts = [[10.46, 12.67],                 # false start "In order to be,"
        [5.68, 6.22, { snap: false }]]  # boundary pinned by hand (energy decays without a dip)
cuts += Media::Cuts.pause_cuts(fl, inn, out)   # phrase > 0.6 s -> 0.25, comma > 0.8 -> 0.4, sentence > 1.2 -> 0.7
segs = Media::Cuts.segments(inn:, out:, cuts:, beats:, flow: fl,
                            tight: ->(s) { s[:fit].to_f >= 0.5 }, contrast: ->(s) { s[:fit].to_f >= 0.5 ? MWIDE : MED })
# each seg: { in:, out:, beats: (source s, first beat = state at the cut, ease cut), jump: }
# -> one EDL clip per segment, transition 0 for jump cuts; log Media::Cuts.text(fl, prev_out, seg_in).
```

   Boundaries inside speech snap to the quietest 10 ms frame within ±0.12 s; boundaries already in silence stay put.
   After a jump cut the segment opens on a contrasting framing (tight ↔ wide), or directly on a `cut` beat that falls
   within 1 s. Segments under 0.5 s are warned about: widen the cut instead (a lone word between two jump cuts flashes).
   No eased zoom runs faster than `min_move` (4.5 s): medit eases INTO a key over the whole interval since the previous
   key, so a cut just before a planned slow move used to squeeze it into a 1 s zoom-out or a 0.1 s pop
   (`Media::Cuts.settle_moves` opens the segment on the move's shot or delays it). Audit moves after generating:
   list consecutive `camera` keys with different zoom/fit and their interval; anything under 4 s is a visible snap.
4. QA before rendering video: `speech:mix`, then `edit:transcribe` the mix and read the words around each clip `at`.
   Fix boundaries from the `energy` curve (print `flow["energy"]["db"]` around the cut) when a word is clipped.

## Lessons

- Far speaker: detect on a stage crop (`DETECT_REGION`), reject wide boxes (heads), seed the track when the first
  seconds have no detections. Where there are none at all, frame by hand (`follow: 0`, `x`, `y`, `zoom`).
- Phone repositioning / handheld moves in the first seconds of a clip are usually unusable; trim them.
- Projection screens dominate whole-frame stats: match exposure on the speaker area, check WB on stills.
- Mains/LED ripple shows as ~10 Hz luminance on 60 fps clips: per-tile deflicker with an auto period removes it
  (measured on a 60 fps 4K phone clip → 30 fps output: frame-to-frame ripple 0.060 → 0.006). The gain is looked up by the decoded
  frame's PTS (not the requested time) and the gain map rows run top-down like the analysis tiles; rolling-shutter
  flicker is a vertical band pattern, so a flipped map makes it worse. Check with `MEDIT_DEBUG_DEFLICKER=1` (logs
  t, analysis frame, window and mean gain per frame) and an A/B analysis of two short renders.
- Keep front-row heads out of wides with the `safe` bottom edge; check `DEBUG=1` stills on the widest shot of each clip.
- iPhone footage is already stabilized in camera (residual shake measured ≈ 0.9 px RMS on 4K). Our phase-correlation
  path can lock onto moving slide content and produce 60–175 px one-frame jumps that read as sudden horizontal
  glitches; count `|Δshift| > 8 px` per frame in the analysis — if any, or if the footage is phone-stabilized, render
  with `stabilize: 0` and `SPACE=frame` tracks.
- A dissolve's audio crossfade eats the last word of the outgoing clip and the first of the incoming one: end clips
  in silence after the last word, start ≥ 0.6 s before the first, and use `audio_xfade: 0.15`.
- Zoom-outs read as distracting when faster than ~4 s; several jump cuts within a few seconds read as busy — keep a
  natural repeat ("of course, of course") rather than add a third cut in 6 s.
- Whisper word times are rough (words absorb neighbouring pauses); place cuts with `speech_runs`/`energy`, not word
  timestamps. Without a verbatim prompt Whisper silently drops most fillers.
- B-roll / event recap without speech (e.g. exhibits at an expo): pick the best few seconds per subject from 1–2 fps contact
  sheets, play hero moments at `speed: 0.5`, frame by hand (`follow: 0`, zoom 1.05–1.35), `mute` every clip except a
  few seconds of live sound under the title, write narration first and time picture and overlays to its measured
  durations (QA-transcribe each line for word offsets: fact chips appear on the word that names them).
- Apple's HLG → SDR conversion renders saturated oranges (e.g. an orange carpet) much redder than ffmpeg's untone-mapped
  preview. A global hue shift turns skin green; use `hue_shift: [12, 20, 14, 0.55]` (reds/oranges near 12° with
  saturation ≥ ~0.4 move +14° toward orange) with `saturation` ~0.84. Check faces and red props (ropes, logos) on stills.
- Before the fix, `vignette` used `CIVignette` with a radius in the thousands of px, which clipped the frame corners to
  pure black at any intensity. Probe corner pixels on a still after grade changes.
- Whisper stretches words over applause; leave ~0.3 s before the first word at a dissolve so the crossfade does not
  eat it.
