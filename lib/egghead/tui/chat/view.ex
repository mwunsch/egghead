defmodule Egghead.TUI.Chat.View do
  @moduledoc """
  Pure view function for the chat screen.

  Layout (Phase 6c — sidebar lands in 6g):

      ┌───────────────────────────────────┐
      │ egghead · #room · N agents        │  header (1 row)
      ├───────────────────────────────────┤
      │ user: hi                          │
      │ scout: hello                      │  transcript region
      │ scout:▌                           │  (live ghost bubble at bottom)
      │                                   │
      ├───────────────────────────────────┤
      │ ❯ what about activation?▌         │  input row (1 row)
      ├───────────────────────────────────┤
      │ CHAT │ ⏎ send │ esc records │ ^q  │  status bar (1 row)
      └───────────────────────────────────┘

  The transcript region soft-wraps long entry lines on
  whitespace. We always show the *tail* of the rendered lines
  (newest at the bottom), padding with blank space if there
  isn't enough content to fill the region.
  """

  import Egghead.OpenTUI.View

  alias Egghead.OpenTUI.Colors
  alias Egghead.TUI.Chat.{Entry, Model, Stream}

  @prompt "❯ "

  @spec render(Model.t()) :: Egghead.OpenTUI.View.tree()
  def render(%Model{} = model) do
    width = model.width
    height = model.height
    transcript_height = max(height - 3, 1)

    vbox([
      header(model, width),
      transcript_region(model, width, transcript_height),
      input_row(model, width),
      status_bar(model, width)
    ])
  end

  # ---- header --------------------------------------------------------------

  defp header(model, width) do
    label =
      " egghead · ##{model.room_id || "—"} · #{length(model.agents)} agents · #{length(model.transcript)} msgs "

    line = pad_to(label, width)

    text(line, height: 1, fg: Colors.white(), bg: Colors.selected_bg())
  end

  # ---- transcript ----------------------------------------------------------

  defp transcript_region(%Model{} = model, width, height) do
    lines = render_transcript_lines(model, width)
    visible = take_tail(lines, height)
    padded = pad_top(visible, height)

    vbox([height: height], Enum.map(padded, &line_to_node/1))
  end

  defp render_transcript_lines(%Model{} = model, width) do
    transcript_lines =
      model.transcript
      |> Enum.flat_map(fn entry -> entry_to_lines(entry, width) end)

    stream_lines =
      model.streams
      |> Map.values()
      |> Enum.sort_by(& &1.started_at)
      |> Enum.flat_map(fn stream -> stream_to_lines(stream, width) end)

    transcript_lines ++ stream_lines
  end

  defp entry_to_lines(%Entry{kind: :user, sender_name: name, text: text}, width) do
    wrap_speaker_lines("#{name}: ", text, width, Colors.cyan())
  end

  defp entry_to_lines(%Entry{kind: :agent, sender_name: name, text: text}, width) do
    wrap_speaker_lines("#{name}: ", text, width, agent_color(name))
  end

  defp entry_to_lines(%Entry{kind: :action, sender_name: name, text: text}, width) do
    wrap_speaker_lines("* #{name} ", text, width, Colors.muted())
  end

  defp entry_to_lines(%Entry{kind: :system, text: text}, width) do
    wrap_speaker_lines("— ", text, width, Colors.muted())
  end

  defp entry_to_lines(%Entry{kind: :handoff, text: text}, width) do
    wrap_speaker_lines("» ", text, width, Colors.accent())
  end

  defp stream_to_lines(%Stream{name: name, current: ""}, width) do
    # Activated but nothing yet — render an ellipsis ghost row.
    wrap_speaker_lines("#{name}: ", "…", width, Colors.muted())
  end

  defp stream_to_lines(%Stream{name: name, current: current}, width) do
    # Append a cursor block to the last line so the ghost bubble
    # looks alive. Soft newlines inside `current` are preserved.
    text = current <> "▌"
    wrap_speaker_lines("#{name}: ", text, width, agent_color(name))
  end

  # Soft-wrap an entry's text body under a speaker prefix. The
  # first wrapped line carries the prefix; continuation lines are
  # indented to the prefix width.
  defp wrap_speaker_lines(prefix, text, width, color) do
    indent_width = String.length(prefix)
    body_width = max(width - indent_width, 1)
    indent = String.duplicate(" ", indent_width)

    text
    |> String.split("\n")
    |> Enum.flat_map(fn paragraph ->
      case soft_wrap(paragraph, body_width) do
        [] -> [""]
        lines -> lines
      end
    end)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} ->
      lead = if idx == 0, do: prefix, else: indent
      {lead <> chunk, color}
    end)
  end

  # Whitespace-friendly soft wrap. Long single tokens hard-break.
  defp soft_wrap("", _width), do: [""]

  defp soft_wrap(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [current | rest] ->
      cond do
        current == "" and String.length(word) <= width ->
          [word | rest]

        String.length(current) + 1 + String.length(word) <= width ->
          [current <> " " <> word | rest]

        String.length(word) <= width ->
          [word, current | rest]

        true ->
          # Hard-break a token longer than the window.
          chunks = hard_break(word, width)

          acc_with_first =
            case current do
              "" -> rest
              _ -> [current | rest]
            end

          Enum.reverse(chunks) ++ acc_with_first
      end
    end)
    |> Enum.reverse()
  end

  defp hard_break(text, width) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp line_to_node({line, color}) do
    text(line, height: 1, fg: color)
  end

  defp take_tail(list, n) do
    len = length(list)

    if len <= n do
      list
    else
      Enum.drop(list, len - n)
    end
  end

  defp pad_top(lines, height) do
    pad = height - length(lines)

    if pad > 0 do
      List.duplicate({"", Colors.dim()}, pad) ++ lines
    else
      lines
    end
  end

  # ---- input ---------------------------------------------------------------

  defp input_row(%Model{input: input, cursor: cursor}, _width) do
    # Split the input at the cursor and emit a zero-width
    # `cursor` leaf between the two halves. Same pattern as the
    # records search bar — see `Egghead.TUI.Records.View.search/2`.
    prefix = String.slice(input, 0, cursor)
    suffix = String.slice(input, cursor, String.length(input))

    fg = Colors.white()

    hbox(
      [height: 1],
      [
        text(@prompt <> prefix,
          width: String.length(@prompt) + String.length(prefix),
          fg: fg
        ),
        cursor(),
        text(suffix, width: String.length(suffix), fg: fg),
        fill(flex: 1)
      ]
    )
  end

  # ---- status --------------------------------------------------------------

  defp status_bar(%Model{status_message: nil}, width) do
    label = " CHAT │ ⏎ send │ esc records │ ^q quit "
    text(pad_to(label, width), height: 1, fg: Colors.white(), bg: Colors.selected_bg())
  end

  defp status_bar(%Model{status_message: msg}, width) do
    label = " ! #{msg} "
    text(pad_to(label, width), height: 1, fg: Colors.white(), bg: Colors.red())
  end

  # ---- helpers -------------------------------------------------------------

  defp pad_to(line, width) do
    len = String.length(line)

    cond do
      len >= width -> String.slice(line, 0, width)
      true -> line <> String.duplicate(" ", width - len)
    end
  end

  # Deterministic-by-name agent colour rotation. Mirrors the
  # convention on `main` of hashing the agent display name into
  # a small palette so the same agent gets the same colour
  # across the session.
  @agent_palette [
    :green,
    :blue,
    :cyan,
    :magenta,
    :yellow,
    :red
  ]

  defp agent_color(name) do
    idx = :erlang.phash2(name, length(@agent_palette))

    case Enum.at(@agent_palette, idx) do
      :green -> Colors.green()
      :blue -> Colors.blue()
      :cyan -> Colors.cyan()
      :magenta -> Colors.magenta()
      :yellow -> Colors.yellow()
      :red -> Colors.red()
    end
  end
end
