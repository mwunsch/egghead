---
title: TUI theming
section: Operations
weight: 39
summary: The built-in themes, the slash-command picker, and the JSON format for authoring your own.
---

The TUI ships with a handful of themes and a JSON format for
adding your own. The default on first launch is
`terminal-dark`, which has a transparent background that
inherits your terminal's existing colors instead of fighting
them. If you want a theme with more personality, the picker is
one slash command away.

## Picking a theme

In either records mode or chat mode, type `/theme` and press
Enter. A panel opens in the middle of the screen with a list
of every theme Egghead knows about, both built-in and
user-supplied.

Use the up and down arrows to preview a theme; the rest of the
TUI repaints under the panel as you move, so you see the
choice live before committing. Type letters to filter the list
by name. Press Enter to commit the focused theme; Egghead
writes the choice to `config.yml`, so the next launch starts
in the same theme. Press Esc to cancel and revert to the
theme you started with.

To switch directly without opening the picker, pass the theme
name as an argument: `/theme hot-dog-stand`, `/theme dos`,
`/theme catppuccin-mocha`. An unknown name leaves the active
theme alone and prints an error inline.

## Built-in themes

| Name               | Display                 | Notes |
|--------------------|-------------------------|-------|
| `terminal-dark`    | Terminal Default (Dark) | The default. Transparent background; inherits your terminal. |
| `terminal-light`   | Terminal Default (Light)| Transparent background; pairs with light terminals. |
| `scholastic`       | Scholastic              | Warm cream paper and deep ink. Mirrors the website's aesthetic. |
| `dos`              | DOS BIOS                | Teal on blue with yellow accents. The old IBM setup utility. |
| `hot-dog-stand`    | Hot Dog Stand           | Yellow on red. Windows 3.1, 1991. Uncompromising. |
| `catppuccin-mocha` | Catppuccin Mocha        | The canonical pastel-dark scheme. |
| `solarized-light`  | Solarized Light         | Ethan Schoonover's classic. |
| `gruvbox-dark`     | Gruvbox Dark            | Retro warm with muted contrast. |

## Authoring your own theme

Drop a JSON file into `~/.config/egghead/themes/` and it
appears in the picker next to the built-ins. A user-supplied
theme that shares a `name` with a built-in takes precedence,
which is useful when you want to tweak one of the bundled
themes without forking it.

A minimal theme file:

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
your declared `mode` — `terminal-dark` if `mode` is `"dark"`,
`scholastic` if `mode` is `"light"`. You can ship a theme with
two or three overrides and let the rest take care of itself.

### Top-level fields

- `name` (required) is the identifier used in
  `/theme <name>` and written to the config file. Keep it
  lowercase and dash-separated.
- `display_name` is the label shown in the picker. Defaults
  to `name` if omitted.
- `mode` (required) is either `"dark"` or `"light"`. It
  determines which built-in theme provides the inheritance
  base.
- `use_terminal_bg`, when `true`, paints `bg` and `bg_alt` as
  transparent (alpha 0) so your terminal's real background
  shows through.
- `palette` (required) is a map of slot names to hex color
  strings.

### Palette slots

Seventeen semantic slots cover everything the TUI draws. You
do not need to set every slot; the unset ones inherit from
the mode's base theme.

| Slot             | What it paints |
|------------------|----------------|
| `bg`             | Main background. |
| `bg_alt`         | Secondary surfaces — sidebar, user-message rail. |
| `fg`             | Primary text. |
| `fg_dim`         | Chrome text such as headers and status bars. |
| `fg_muted`       | Subdued text — captions, hints, disabled items. |
| `selection_bg`   | Selection highlight behind focused rows. |
| `accent`         | Primary accent — active state, brand. |
| `border`         | Hairlines and dividers. |
| `error`          | Error text and indicators. |
| `warning`        | Warning text and indicators. |
| `success`        | Active agent status and confirmations. |
| `info`           | Informational highlights. |
| `syntax_heading` | Markdown headings in previews and transcripts. |
| `syntax_link`    | Wikilinks and inline links. |
| `syntax_code`    | Code spans and fenced blocks. |
| `syntax_keyword` | Reserved for future syntax highlighting. |
| `syntax_string`  | Reserved for future syntax highlighting. |

### Hex format

Colors are written as `#rrggbb` for opaque values or
`#rrggbbaa` for values with alpha. Anything else is rejected
at parse time. If a theme file fails to load, Egghead logs a
warning and skips it; the rest of your themes still appear in
the picker.

## Persistence

The selected theme is saved to `config.yml` under the
`theme:` key. See [Configuration]({{< ref "configuration" >}})
for the full file layout. If the configured theme cannot be
found on the next launch — for example, because you deleted a
user-supplied theme file — Egghead falls back to
`terminal-dark` and logs the miss.
