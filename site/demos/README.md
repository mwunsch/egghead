# Landing-page demos

VHS tape scripts for the figures in `site/layouts/index.html`.

## Render

```bash
cd site/demos
vhs records.tape    # → ../static/assets/demos/records.{mp4,gif}
vhs chat.tape       # → ../static/assets/demos/chat.{mp4,gif}
```

Install VHS: `brew install vhs` (also needs `ffmpeg` and `ttyd`, pulled
in as deps).

## Sizing

Tapes render at **960×1200** (4:5 portrait), matching the
`.feature__image` aspect ratio in `site/static/assets/css/site.css`.
Going narrower wraps nick-prefixed chat lines awkwardly; going wider
breaks the figure aspect.

## Demo store

These tapes assume a curated, gitignored demo records directory. Don't
record against your real `~/.egghead/` store — real notes are noisy and
personal. Set `EGGHEAD_CONFIG` or `records_dir` to point at a demo store
before recording.

## Re-shooting

Chat responses are non-deterministic (real LLM calls). Expect to tune
`Sleep` durations after watching a few takes. If you want deterministic
playback, pre-record a transcript, save it as a `class: transcript`
record, and `/join` it in the tape instead of prompting live.
