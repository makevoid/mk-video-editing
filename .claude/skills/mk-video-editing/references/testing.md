# RSpec verification

Routine tests make no paid calls; the Fal contracts use mocked responses. Run from the skill directory:

```sh
ruby scripts/mv.rb setup
ruby scripts/mv.rb test                  # PROFILE=all (default)
PROFILE=core ruby scripts/mv.rb test
PROFILE=media ruby scripts/mv.rb test
PROFILE=swift ruby scripts/mv.rb test
(cd scripts/tools/graphics && swift test)
```

The repository root also has `rake setup`, `rake doctor` and `rake test`.
- Tests fail, rather than skip, when a backend they need cannot run (FFmpeg, ImageMagick, Python, Metal, codec services, Swift). Use a narrower profile in that case and report what was not exercised.
- Fixtures go to `scripts/tmp/` and review outputs to `scripts/output/`; both are ignored by git.
- No API key is needed. `uv` may download local Python packages on first use.

## What is tested

| Profile | Observable behavior |
|---|---|
| core | Skill metadata and Markdown links; CLI help and task discovery, including that removed music-video tasks stay removed; footage project init and overwrite rejection; literal shell arguments and subprocess errors; plan approval and invalidation; dependency waves; worker journals; local fonts; jump-cut helpers (`Media::Cuts`); Fal adapters (receipts, resume, schema validation, queue errors); credential isolation and the MCP server's task allowlist |
| media | Footage project init with a linked source; real FFmpeg/ImageMagick/Python audio duration, silence and energy; title rendering from the bundled template; cut detection; timed SFX mix with peak limiting; procedural SFX caching and timing; X/Twitter encode |
| swift | Native graphics package tests; sparse JSON overlays; Swift VFX renders (cue-on/cue-off pixels, audio and frame preservation, invalid-effect rejection); fast previews; parallel chunk renders identical to sequential ones; Metal shader cues; 60 fps video with 24 fps cues |

`swift test` in `scripts/tools/graphics` covers geometry, alpha, text, seeking, JSON validation (removed node types are rejected), GPU glow against Core Graphics, and the video and audio round trips. `swift build -c release --package-path scripts/tools/edit` (or `edit:build`) checks that medit compiles.

When changing the renderer, render every existing title scene before and after the change and compare the PNG frames byte for byte. The scenes are `edit/titles/*.json` in real projects, or the bundled examples. Identical frames show the change did not move a pixel.

## Behavioral review

Use a disposable project and your own footage (none is bundled):

1. Init with two or three clips of one speaker, then `setup`. Transcribe, analyze one source at a time, and track the speaker.
2. Write a short plan, approve it, and generate `edit/edl.json` with one dissolve and one jump cut from `speech:flow`.
3. `DEBUG=1 edit:stills` on the widest shot of each clip; check the crop, subject and safe outlines.
4. Render a lower third from `examples/lower_third.json` as ProRes 4444 and place it as an overlay.
5. Run `speech:mix`, QA-transcribe the mix around each `at`, then `edit:preview` a 10 s range before `edit:render`.
6. Optional: add a music bed and one whoosh, and check that the dialogue stays on top (`speech:measure`).

Executable checks do not establish editorial quality. Watch the opening, every join and the ending with sound, and record findings in `docs/REVIEW.md`.
