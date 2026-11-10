# Finishing: soundtrack, sound effects and VFX

Optional passes after the cut is locked. A talk edit usually needs none of them: clean dialogue, a title and an end card are enough. Use them when the brief asks for a music bed, a recap/promo feel, or a punchier opening. Always keep the clean master, and give every finish revision a new output name.

## Soundtrack (music bed)

The EDL `music` key is a list of music entries mixed under the timeline. `speech:mix` trims each entry (`from`, `duration`), sets its level, fades it, places it at `at`, and **sidechain-ducks** it under the clip speech and `sounds` (narration). It then runs two-pass loudnorm on the whole mix: −16 LUFS / −1.5 dBTP by default, overridable with `LUFS`/`TP`. Nothing loops or stretches, so the music must be at least as long as the part it covers. Set `duration` so it ends with the timeline, with a `fade_out`.

```ruby
edl[:music] = [{ source: "audio/music/score.mp3", at: 0, from: 0, duration: timeline_end,
                 gain_db: -20, duck_db: -10, fade_in: 1.5, fade_out: 4.0 }]   # gain_db default -18, duck_db -10
```

Bring a bed up at the start and end, where nobody is speaking, by splitting it into several entries with different `gain_db`. Ducking alone handles the speech in between.

**Envelope ducking (recommended for narration-driven edits).** The default sidechain compressor reduces the bed by an amount that depends on how loud the voice is (fixed threshold, `duck_db` sets its ratio) and reacts after each onset. `duck: {mode: "envelope"}` instead renders the voice key (clip speech + `sounds`), detects voice from 10 ms RMS and multiplies the bed by a gain envelope: exactly `depth_db` down while anyone speaks, already down at the first word (`lookahead`), held over short gaps (`bridge`), and released smoothly after the last word.

```ruby
edl[:duck] = { mode: "envelope", depth_db: -12, threshold_db: -45, attack: 0.15, release: 0.7, hold: 0.3,
               lookahead: 0.2, bridge: 0.8 }   # defaults: depth = music duck_db, -42 dBFS, 0.12, 0.6, 0.25, 0.15, 0.6
```

`speech:mix` writes `<out>.duck.json` (voice spans, ducked seconds) and keeps `<out>.duckkey.wav` / `<out>.duckenv.wav` for review. Wall-to-wall talk ducks almost continuously, which is right: set `gain_db` for the level the bed should have in the gaps and on the end card, `depth_db` for under speech (−10 to −14 keeps narration 14–18 dB above the bed). Raise `threshold_db` if room tone holds the duck down; lower `bridge` if the bed should breathe between turns.

**Generated score (paid, explicit request only).** `music:score[prompt.txt,out.mp3,seconds]` uses ElevenLabs Music v2.5 through Fal and is always instrumental.
- Ask for the final timeline length plus ~0.5 s.
- Describe mood, tempo, instrumentation and structure ("soft piano and pads, builds at 0:40, resolves for the last 10 s, no drums under speech").
- Record the call in `docs/PLAN.md` and get `plan:approve` first. In plugin sessions, run it through the MCP server ([credentials.md](credentials.md)).
- Listen before placing it: generated music can change key or end abruptly. Regenerating costs again, so trim/fade in the EDL instead when you can.

**Supplied music.** Put the file in `audio/music/` and reference it the same way. Confirm the user has the rights to it.

**Timing picture to music.** `audio:analyze[audio/music/score.mp3,analysis/music]` writes `beats.json` (bpm, beat times, 24 fps frames) and `energy.json` (RMS per 0.5 s). Use it to:
- land a title reveal or the end card on a downbeat;
- start the music swell where the energy rises;
- cut the opening montage on beats.

The structure of a talk edit still comes from what is said; music never decides where selects cut.

**Checks.**
- Dialogue must stay clearly on top: `speech:measure` the mix.
- Re-transcribe the mix around every `at` to catch words masked by the bed.
- Listen to the transitions into and out of narration.

## Sound effects (procedural, free)

For two or three effects, render each with `mgraphics --sfx out.wav --spec '{"synth":"whoosh","duration":0.7}'` and add it to the EDL `sounds` (`{source, at, gain_db}`), so `speech:mix` levels it with everything else. For more effects, use a cue sheet instead. Use effects sparingly on titles and transitions: a soft whoosh under a lower third sliding in, a tick on a counter, an impact on the end card. Write `prompts/<name>/sfx.yml` and run the mix on a rendered video:

```yaml
source: output/final.mp4
out: output/final_sfx.mp4
rel_db: -6          # default cue level relative to the programme in that window
peak_db: -6
max_gain_db: 18
sounds:
  swoosh: {synth: whoosh, duration: 0.7, peak: 0.75, from: 300, to: 4200, seed: 2}
  tick:   {synth: tick, duration: 0.15, seed: 7}
  hit:    {synth: impact, duration: 0.9, freq: 48}
  beep:   {tone: 1000, duration: 0.3}
cues:
  - {at: 4.475, sound: swoosh, rel_db: -14}   # 4.475 = title at 5.0 - peak_at 0.525: the whoosh crests on the title
  - {at: 61.2, sound: tick, rel_db: -10, len: 0.25, fade: 0.03}
```

```sh
SFX=<name> mv sfx:gen    # synthesize/cache the sounds (free for synth:/tone:)
SFX=<name> mv sfx:mix    # mix them on their cues
```

- **`synth:`** is the Swift `SoundSynth`. Its types are whoosh, riser, reverse, impact, subdrop, tick, type, zap, glitch and shimmer. Each takes `duration`, `seed` and its own knobs (frequencies, `peak`, `pan`, `q`). It is deterministic and cached by its settings.
- **`at`** is where the sound starts, after its leading silence is trimmed. To crest on an event, start a whoosh at `event - peak_at` (the cache sidecar records `peak_at`) and a riser or reverse at `event - duration`.
- **Levels:** keep effects subordinate to speech, with `rel_db` around −10 to −16 under dialogue. The mix caps gain and peak-limits.
- **`prompt:`** sounds call Stable Audio through Fal (paid). Use them only on request and with approval.

## VFX (Core Image + Metal, local)

`mvfx` applies cued effects to a rendered video and keeps the audio. Write `prompts/<name>/cues.yml`:

```yaml
source: output/final_sfx.mp4
out: output/final_fx.mp4
cues:
  - {fx: flash, f: 0, dur: 6, amt: 0.6}            # open from white
  - {fx: punch, f: 240, dur: 8, amt: 0.04}         # tiny push on a key line
  - {fx: glow, f: 1200, dur: 30, amt: 0.3, radius: 10}
  - {fx: dark, f: 2400, dur: 24, hold: 12, amt: 0.9}   # dip before the end card
```

```sh
VFX=<name> mv 'vfx:stills[0,240,1200]'   # check single cued frames first
VFX=<name> mv 'vfx:clip[1180,1260]'      # then a short interval
VFX=<name> JOBS=1 mv vfx:render          # then the full video (one heavy job at a time)
```

- **Timing:** `f` and `dur` are integer frames **on a 24 fps cue grid at any video rate**. A 30 or 60 fps video is rendered frame by frame with the cues sampled at each frame's exact time. Convert seconds × 24.
- **Core Image effects:** punch, zoom, shake, whip, mblur, edgeblur, glow, flash, dark, rgb (radial split; sideways with `radius`), glitch, tv, grain, stretch, echo, and bands (VHS tracking bands).
- **Metal effects:** shockwave (refraction ring at `x`,`y`), streaks (anamorphic flares from thin highlights), lens (barrel + dispersion + vignette) and heat (shimmer).
- **Light effects:** leak, flare and glints.
- The knobs for each effect are in `scripts/tools/vfx/Sources/mvfx/Effects.swift` and `Shaders.swift`.
- `vfx:analyze` lists the source's beats and picture cuts (`beats.py`/`cuts.py`) for placing cues. `media:cuts[video,out.json]` gives the cuts alone.
- For footage, prefer quiet effects: a flash or dark dip into a section, a light punch, gentle glow on a title. Glitch, bands, rgb, tv and shake read as music-video styling. Do not stack grain on grainy footage.
- `bitrate:` in cues.yml sets the encode in bits/s. Use H.264/HEVC for delivery; the VFX pass is the last re-encode before `media:twitter`/`media:youtube`.
- **Color caveat:** `mvfx` interprets untagged sources as BT.709. A source encoded untagged with ffmpeg's BT.601 default can shift saturated colors (greens most) across the whole video, not only on cued frames. Camera files and `medit` renders are tagged. Check a no-cue frame against the source before a full render.

## Order of passes

```text
edit:render → output/final.mp4 (clean master, never overwritten)
  → SFX=… sfx:mix   → output/final_sfx.mp4
  → VFX=… vfx:render → output/final_fx.mp4
  → media:twitter / media:youtube / media:faststart → delivery files
```

When there are no effects, deliver from the clean master directly. Narration and the music bed belong in `speech:mix` before `edit:render`, not in the SFX pass.
