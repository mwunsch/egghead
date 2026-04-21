---
title: TUI theming
weight: 16
---

The terminal UI ships with a handful of themes and an
extensible format for adding your own. On first launch the TUI
uses `terminal-dark`, which keeps your terminal's own
background and foreground — it drops into any existing colour
scheme without fighting it. If you want something with more
personality, the picker is a slash command away.

## Picking a theme

In either **records** or **chat** mode, press `/` and pick
**theme**, or just type `/theme` and hit enter. A panel opens
in the middle of the screen.

- `↑` / `↓` — preview a theme live; the TUI repaints under the
  panel as you move.
- Type letters to filter the list.
- `Enter` — commit the focused theme. Writes the choice to
  `config.yml` so it's there on the next launch.
- `Esc` — cancel and revert to the theme you started with.

To switch directly without the picker, pass a name as the
argument: `/theme hot-dog-stand`, `/theme dos`,
`/theme catppuccin-mocha`. Unknown names report an error
in-line and leave the active theme alone.

## Built-in themes

| Name               | Display                 | Notes |
|--------------------|-------------------------|-------|
| `terminal-dark`    | Terminal Default (Dark) | Default. Transparent background; inherits your terminal. Dark foreground. |
| `terminal-light`   | Terminal Default (Light)| Transparent background, ink foreground. Pairs with light terminals. |
| `scholastic`       | Scholastic              | Warm cream paper, deep ink. Mirrors the website's aesthetic. |
| `dos`              | DOS BIOS                | Teal on blue, yellow accents. The old IBM setup utility. |
| `hot-dog-stand`    | Hot Dog Stand           | Yellow on red. Windows 3.1, 1991. Uncompromising. |
| `catppuccin-mocha` | Catppuccin Mocha        | The canonical pastel-dark. |
| `solarized-light`  | Solarized Light         | Ethan Schoonover's classic. |
| `gruvbox-dark`     | Gruvbox Dark            | Retro warm, muted contrast. |

## Authoring your own theme

Drop a JSON file into `~/.config/egghead/themes/` and it
shows up in the picker next to the built-ins. If a user
theme has the same `name` as a built-in, it wins.

Minimal example:

```json
{
  "name": "my-theme",
  "display_name": "My Theme",
  "mode": "dark",
  "palette": {
    "accent": "#ff5f87",
    "syntax_heading": "#ffd787"
  }
}
```

Missing palette slots inherit from the built-in default for
your declared `mode` — `terminal-dark` when `mode` is
`"dark"`, `scholastic` when `"light"`. So you can ship a
theme with two or three overrides and the rest takes care of
itself.

### Fields

- `name` *(required)* — the identifier used in `/theme <name>`
  and written to config. Keep it lowercase and
  dash-separated.
- `display_name` — the label shown in the picker. Defaults
  to `name` if omitted.
- `mode` *(required)* — `"dark"` or `"light"`. Determines
  the inheritance base and affects how neighbouring
  elements pick contrast.
- `use_terminal_bg` — when `true`, `bg` and `bg_alt` are
  painted as transparent (alpha 0). The OpenTUI bridge
  flips respect-alpha on the frame buffer so those cells
  are serialized as `SGR 49` (terminal default background)
  instead of a literal colour. Your terminal's real
  background shows through.
- `palette` *(required)* — map of slot names to `#rrggbb`
  or `#rrggbbaa` hex strings.

### Palette slots

Seventeen semantic slots cover everything the TUI draws.
You don't need to set them all — leave the ones you don't
care about to inherit.

| Slot             | What it paints |
|------------------|----------------|
| `bg`             | Main background. |
| `bg_alt`         | Secondary surfaces: sidebar, user-message rail. |
| `fg`             | Primary text. |
| `fg_dim`         | Chrome text (headers, status). |
| `fg_muted`       | Subdued text (captions, hints, disabled items). |
| `selection_bg`   | Selection highlight behind focused rows. |
| `accent`         | Primary accent — active state, brand. |
| `border`         | Hairlines and dividers. |
| `error`          | Error text and indicators. |
| `warning`        | Warning text and indicators. |
| `success`        | Active agent status, confirmations. |
| `info`           | Informational highlights. |
| `syntax_heading` | Markdown headings in previews and transcripts. |
| `syntax_link`    | Wikilinks and inline links. |
| `syntax_code`    | Code spans and fenced blocks. |
| `syntax_keyword` | Reserved for future syntax highlighting. |
| `syntax_string`  | Reserved for future syntax highlighting. |

### Hex format

- `#rrggbb` — opaque.
- `#rrggbbaa` — with alpha. Most slots render opaque; alpha
  is only meaningful for overlays.

Anything else is rejected at parse time. If a theme file
fails to load, Egghead logs a warning and skips it; the rest
of your themes still appear.

## Persistence

The selected theme is saved to `config.yml` under the
`theme:` key. See
[Configuration]({{< ref "configuration" >}}) for the full
file layout. If the configured theme can't be found on next
launch (e.g. you deleted a user theme file), Egghead falls
back to `terminal-dark` and logs the miss.
