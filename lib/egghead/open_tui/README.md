# OpenTUI

Elm-architecture TUI framework built on [OpenTUI](https://github.com/anomalyco/opentui)
(Zig) via a NIF bridge.

## Architecture

```
Screen (your app)          Framework (this directory)
┌──────────────────┐       ┌──────────────────────────┐
│ init/1           │       │ Runtime     — event loop  │
│ update/2         │◄─────►│ Terminal    — lifecycle   │
│ view/1           │       │ Renderer    — draw calls  │
│ subscriptions/1  │       │ Layout      — flex/fixed  │
└──────────────────┘       │ Input       — key parser  │
                           │ Bridge      — Zig NIF     │
                           │ View        — tree DSL    │
                           │ Markdown    — AST→spans   │
                           │ EditBuffer  — text editing │
                           │ Readline    — line editing │
                           │ Clipboard   — OSC 52      │
                           │ Colors      — palette     │
                           │ Attrs       — bitfields   │
                           │ Style       — helpers     │
                           └──────────────────────────┘
```

A screen implements the `Runtime` behaviour with four callbacks:

- `init/1` — initial model + startup command
- `update/2` — pure reducer: `(msg, model) -> {model, cmd}`
- `view/1` — pure projection: `model -> view_tree`
- `subscriptions/1` — declares input sources (`:keys`, `{:pubsub, topic, wrap}`)

The runtime drives the loop: draw, poll input, dispatch to update, execute
commands, repeat. Screens never touch I/O directly.

## View tree

Views are nested tuples:

```elixir
{:vbox, opts, [child, ...]}    # vertical stack
{:hbox, opts, [child, ...]}    # horizontal stack
{:text, content, opts}         # leaf text node
{:fill, opts}                  # background fill
{:overlay, [child, ...]}       # z-stacked layers
:nothing                       # empty placeholder
```

Common opts: `:flex`, `:width`, `:height`, `:fg`, `:bg`, `:attrs`, `:padding`.

## Commands

Screens return commands from `update/2` to express side effects:

| Command | Effect |
|---|---|
| `:none` | No-op |
| `{:exec, fn}` | Run function, queue its return as next message |
| `{:suspend, fn}` | Tear down terminal, run function (e.g. `$EDITOR`), restore |
| `{:batch, [cmd]}` | Execute commands in sequence |
| `:halt` | Exit the runtime |

## NIF bridge

The Zig NIF (`native/bridge/`) links against `libopentui.dylib` and exposes:

- **Rendering**: `create_renderer`, `begin_frame`, `draw_text`, `fill_rect`,
  `end_frame`, `clear`, `resize`, `set_cursor_position`
- **Terminal**: `setup_terminal`, `destroy_renderer`, `enter_raw_mode`,
  `leave_raw_mode`, `tty_size`, `drain_input`
- **Input**: `read_key` (dirty I/O NIF, non-blocking with timeout)
- **Mouse**: `enable_mouse`, `disable_mouse`

The bridge uses 13 of ~251 symbols exported by `libopentui.dylib`. This is
intentionally minimal. See "Unexposed capabilities" below for what's available.

## PubSub

Screens can subscribe to Phoenix.PubSub topics via the `subscriptions/1`
callback. The PubSub server name is passed as `:pubsub_server` in the
runtime opts — the framework has no compile-time dependency on any
particular application's PubSub.

```elixir
Runtime.run(MyScreen, pubsub_server: MyApp.PubSub)
```

## Modules

| Module | Purpose |
|---|---|
| `Runtime` | Elm event loop, command execution, subscription management |
| `Terminal` | GenServer owning the renderer lifecycle (suspend/resume) |
| `Renderer` | Walks the view tree and issues draw calls via Bridge |
| `Layout` | Flex/fixed layout engine for hbox/vbox trees |
| `Input` | Raw byte stream parser (keys, mouse SGR, bracketed paste) |
| `Bridge` | NIF interface to libopentui.dylib |
| `View` | View tree constructors and helpers |
| `Markdown` | Earmark AST to styled terminal spans (with wikilink support) |
| `EditBuffer` | Functional multi-line text buffer with visual wrapping |
| `Readline` | Line-editing operations (kill/yank, word movement) |
| `Clipboard` | OSC 52 clipboard write (cross-platform, works over SSH) |
| `Colors` | Named color palette |
| `Attrs` | Text attribute bitfield constants (bold, italic, etc.) |
| `Style` | Color/attribute composition helpers |

## Unexposed capabilities

The following `libopentui.dylib` capabilities are available but not yet
wired through the NIF bridge:

**Text selection** — `textBufferViewSetSelection`, `UpdateSelection`,
`GetSelectedText`, `ResetSelection`. Needed for mouse-based text
selection in the terminal. The coordinate mapping (screen coords to
content coords) must account for layout offsets.

**Kitty keyboard protocol** — `enableKittyKeyboard`, `disableKittyKeyboard`.
Better modifier disambiguation (Shift+Arrow vs Alt+B), key release events.

**Hit testing** — `checkHit`, `addToHitGrid`, scissor rects. Click target
detection for mouse-driven UIs.

**Hyperlinks** — `attributesWithLink`. OSC 8 clickable links.

**Editor/text buffer widgets** — Full subsystem with undo/redo, file loading,
syntax highlighting registration. An alternative to the pure-Elixir
`EditBuffer` for heavy text editing.

**Advanced rendering** — Box/grid drawing, alpha blending, color matrices,
direct cell access, grayscale buffers.

## Testing

Tests live in `test/egghead/open_tui/`. The runtime can be tested headlessly
by skipping the terminal (screens receive synthetic messages directly).
Pure modules (EditBuffer, Readline, Layout, Input, Markdown) are tested
without any terminal at all.
