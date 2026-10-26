# MotionGraphics: native Swift titles and overlays

A macOS 14+ Swift package for rendering titles, lower thirds, end cards and other graphic overlays. It has a scene graph, deterministic keyframe animation, Quartz/Core Text drawing, GPU neon glow, Core Image composition and AVFoundation video I/O. It has no third-party Swift dependencies. `MotionGraphics` is the library and `mgraphics` is the CLI. The footage editor `medit` (`../edit`) and the VFX renderer `mvfx` (`../vfx`) link the same library.

[Swift sources](Sources/MotionGraphics) · [Tests](Tests/MotionGraphicsTests)

## Run

From this directory:

```sh
swift build -c release
.build/release/mgraphics examples/lower_third.json --out lower_third.mov --codec prores4444 --frames 180 --fps 30 --supersample 2
.build/release/mgraphics examples/opening_title.json --out stills --frames 300 --fps 30 --only 0,60,150
.build/release/mgraphics examples/overlay.json --plate plate.mp4 --out composed.mp4 --width 320 --height 180 --frames 48
.build/release/mgraphics --sfx whoosh.wav --spec '{"synth":"whoosh","duration":0.7,"peak":0.75}'
swift test
```

From a project (or the `scripts` directory):

```sh
ruby mv.rb graphics:build
CODEC=prores4444 SUPERSAMPLE=2 ruby mv.rb 'graphics:render[edit/titles/lower_third.json,edit/titles/lower_third.mov,180,1920,1080,30]'
ONLY=0,60,150 ruby mv.rb 'graphics:render[edit/titles/opening.json,edit/review/opening,300,1920,1080,30]'
ruby mv.rb 'graphics:preview[edit/titles/opening.json,output/opening_draft.mp4,0,6]'
```

`graphics:render` writes a PNG directory when `out` has no movie extension (with `ONLY`, only the listed frames). It accepts `PLATE`, `AUDIO`, `CODEC`, `SUPERSAMPLE`, `BITRATE`, `GLOW` and `JOBS`. `graphics:preview` renders a time range at 1× and 30 fps for iterating. Existing video files are never silently overwritten.

## Titles for footage edits

The [examples](examples) are 1920×1080 templates taken from real talk edits, with the content replaced by placeholders:

| Template | Use | Length |
| --- | --- | --- |
| [opening_title.json](examples/opening_title.json) | Centered event card: kicker line, title reveal, subtitle, speaker, event/date line; fades out at 8.6–9.8 s | ~10 s, over a darkened or blurred opening shot |
| [lower_third.json](examples/lower_third.json) | Speaker name and role on a translucent plate with an accent bar; slides in, holds, fades at 5.4–6.0 s | 6 s, bottom left |
| [end_card.json](examples/end_card.json) | Recap card: excerpt label, title, speaker, event line | 3–6 s, over a dissolve to black |
| [overlay.json](examples/overlay.json) | Small HUD smoke test (reticle, star, text reveal, trace) | 2 s at 320×180 |

To make a title:

1. Copy a template to `edit/titles/` and change the text, colors (the accent is `#50AF95`), and the timing in the `tracks`.
2. Use system fonts by PostScript name (`AvenirNext-Bold`, `AvenirNext-DemiBold`, `AvenirNext-Medium`, `AvenirNext-Regular`). Unknown names fail instead of falling back. For other faces, see `fonts:list` / `fonts:copy` and the scene `fonts` key.
3. Check stills with `ONLY=`. White type is invisible on a white image viewer, so composite the stills over a frame of the footage, or render with `PLATE=` a still of the shot.
4. Render ProRes 4444 with alpha at the edit's fps: `--frames` = seconds × fps, plus `SUPERSAMPLE=2`.
5. Place the `.mov` as an EDL `overlays` entry (see the skill's footage-editing reference). Keep text inside the 5 % title-safe margin. Contrast comes from the shot itself: darken or blur the plate under the title, or add a translucent plate (`#00000052`) as the lower third does.

Generate repeated titles with a small Ruby script that writes the JSON files (for example `edit/make_titles.rb`). That keeps names, roles and dates in one place.

## Scene files

The coordinate system is pixels with the origin at the top left and positive y down. Rotation is clockwise-positive in radians, animation time is in seconds, and frame time is `frame / fps`. Rectangles are placed by their upper-left corner, circles and ellipses by their center, and text by its left baseline (or its center/right point with `align`). Scenes do not rescale with the output size; wrap a scene in a scaled group to change its size.

Root keys:

| Key | Meaning |
| --- | --- |
| `version` | `1` (also the default) |
| `background` | Hex color; omitted means transparent (titles) |
| `nodes` | Ordered, nested drawing nodes; later siblings draw on top |
| `fonts` | Font files to register once; paths are relative to the scene file |
| `effects` | Ordered Core Image filters (`name` plus `parameters`), applied to the graphics before the plate |

Common node fields: `type`, `name`, `x`, `y`, `rotation`, `scale` or `scaleX`/`scaleY`, `anchor: [x,y]`, `opacity`, `start`, `end`, `blend`, `clip: [x,y,w,h]`, `tracks`, `children`.
- Visibility is `[start,end)`.
- Group opacity is isolated: overlapping children fade together.
- Blend modes: normal, screen, add, multiply, overlay, difference, exclusion, lighten, darken, erase.

Tracks have the form `"x": [[0, 100], [2, 800, "outCubic"]]`. Times must strictly increase, and the destination key selects the segment's easing.
- **Animated properties:** x, y, rotation, scaleX, scaleY, opacity, skewX, skewY (radians; these also work as static keys).
- **Easing:** linear, inCubic, outCubic, inOutCubic, inExpo, outExpo, outBack, outElastic, smooth, and hold (keeps the previous value until the key's time, for hard cuts).
- Values clamp to the endpoint keys.
- **`entrance`:** `"pop"`, `"slap"` or `"slam"` installs scale tracks starting at the node's `start`, replacing any tracks for those properties.
- **Shapes** also animate `trimStart` and `trimEnd` (0…1 of the outline length, for draw-on lines), `strokeWidth` and `dashPhase`.
- **Text** has `reveal`: a spatial left-to-right wipe track.

| Node | Additional fields |
| --- | --- |
| group | children |
| rect, square | width, height (rect), radius (corner rounding) |
| circle, ellipse | radius (circle), width/height (ellipse) |
| point | strokeWidth (diameter), fill |
| line, triangle, quad, polygon | points: `[[x,y],...]`; polygon accepts closed |
| spline | points (Catmull–Rom interpolation) |
| path | commands: `["M",x,y]`, `["L",x,y]`, `["Q",cx,cy,x,y]`, `["C",c1x,c1y,c2x,c2y,x,y]`, `["Z"]`; use multiple M commands for contours (logos) |
| arc | radius, arcStart, arcEnd, arcMode (open, chord, pie) |
| star | radius, inner, rays |
| paper | width, height, seed, roughness |
| text | text, font (PostScript name), size, fill (null for outline-only), outline, outlineWidth, reveal (track), align (left/center/right about x), tracking (px) |
| image | path, width, height (logos, photos; relative to the scene file) |
| sprite | path (directory of 0000.png…), frames, fps, width, height, loop, audioAt: an image sequence |
| trace | points, color, strokeWidth, progress (track) |
| grid, warpgrid | width, height, spacing, color (warpgrid: strokeWidth, center, strength, falloff, twist) |
| reticle, flare | radius, color |
| waveform | samples or samplesData (external numeric array), width, height, color, progress |
| karaoke | words or wordsData (external `[{w,s,e},...]`), font, size: word-timed captions |

All shape nodes accept:
- `fill`/`stroke` (hex, or null to disable), `strokeWidth`, `dash`, `evenOdd`;
- `gradient`: linear (`colors`, `from`, `to`) or radial (`colors`, `center`, `radius`);
- `trimStart`/`trimEnd`;
- hand-drawn line boil: `boil`, `boilRate`, `seed`.

Unknown keys, node types, effects and animated properties fail with an error.

**Glow:** any node accepts `glow` (halo in px; animatable) and `glowCore` (0…1, a whitened core over strokes); both are inherited by the subtree.
- Strokes, small fills and small type glow in their own color. Big fills and poster-size type never glow.
- Rendering runs on the GPU by default (`--glow gpu`): halos are blurred once per frame and knocked out by later opaque marks. `GLOW=cg` uses Core Graphics shadows instead, for an A/B check.
- Keep glow subtle on talk titles (2–6 px on thin rules).

Filters use native Core Image input names, e.g. `{"name":"CIBloom","parameters":{"inputRadius":12,"inputIntensity":0.5}}`. Numeric arrays become CIVectors and hex strings become CIColors. The filter chain is cropped to the canvas.

`--data name=file.json` paths (for `wordsData`/`samplesData`) are relative to the process working directory. Asset paths are relative to the scene JSON.

## Swift authoring

Add this directory as a local SwiftPM dependency and depend on the `MotionGraphics` product:

```swift
import MotionGraphics
import CoreGraphics

let canvas = try Canvas(width: 1920, height: 1080)
let scene = Scene()
let name = TextNode("Speaker Name", font: "AvenirNext-DemiBold", size: 46)
name.position = CGPoint(x: 146, y: 912)
try Designs.entrance(name, start: 0.2, kind: "pop")
try scene.root.add(name)
try scene.draw(on: canvas, at: FrameTime(frame: 24, fps: 24))
try canvas.writePNG(to: URL(fileURLWithPath: "frame.png"))
```

Subclass `Node` and override `draw(on:at:)` for new instruments, charts or generative geometry. Animate from absolute time, never by accumulating per frame, so sparse previews match sequential output. A node has one parent, and cycles are rejected.

Other building blocks:
- `Canvas`: immediate drawing, `withState`, affine transforms, shear, clips, and native CGContext access.
- `Path`: curves, splines, contours, stars and paper outlines.
- `TextLayout`: cached Core Text shaping, metrics and glyph paths.
- `Color`, and the seeded `Random`/`Noise`.

`Composition` stacks `VectorLayer`, `StillLayer`, `MovieLayer` and `GeneratedLayer` into a lazy Core Image graph; feed `composition.image(at:)` to `VideoWriter.append`. `MetalShader` runs runtime-compiled MSL compute kernels on a frame; mvfx's shader cues (shockwave, streaks, lens, heat) use it.

## Video, audio and performance

- **Parallel renders:** `--from A --to B` renders one chunk (times stay absolute). Through Ruby, `JOBS=N` splits a movie into chunks, joins them by stream copy and muxes the audio once. Keep `JOBS` low on 16 GB machines (see the skill's memory-safety rules).
- **Supersampling:** `--supersample N` (1–4) draws at N× and Lanczos-downscales, which costs about 2× the draw time at N=2. `--bitrate` sets the average H.264/HEVC bits/s.
- **Transparency:** PNG and ProRes 4444 MOV keep alpha. H.264/HEVC are opaque and flatten over black when there is no plate. Output is SDR sRGB/Rec.709.
- **Video in:** `VideoSource` streams with one-frame lookahead and honors orientation.
- **Video out:** `VideoWriter` requires contiguous frame indices starting at zero.
- **Audio:** `AudioSource` interleaves audio into the same writer. Explicit `--audio` replaces the plate's audio.
- **`SoundSynth`** (Synth.swift) renders procedural sound effects offline and deterministically: whoosh, riser, reverse, impact, subdrop, tick, type, zap, glitch and shimmer (48 kHz stereo WAV, −3 dBFS peak). It prints `peak_at`; Ruby uses it for `synth:` sounds in `sfx.yml`.
- **Benchmark:** `--benchmark` (`graphics:benchmark`) renders without encoding and reports fps.

The tests cover alpha and orientation, isolated groups, clipping, state restoration, frame seeking, sprites, text, JSON errors (including rejected node types), GPU glow against Core Graphics, H.264 frame counts, ProRes alpha, fractional fps, audio passthrough and trimming, and color-preserving round trips. Metal and video tests need macOS graphics/codec services; a restrictive sandbox can hide them.
