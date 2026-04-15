defmodule Egghead.TUI.Records.Model do
  @moduledoc """
  State for the records-list screen.

  Holds the filtered record set, the cursor, the hydrated body
  and total line count for the currently selected record, the
  display toggles, and the cached terminal dimensions.

  The model owns its own width/height — the runtime dispatches
  a `{:resize, w, h}` message whenever the terminal size
  changes (including once before the first frame), and the
  reducer stores them here. Any code that needs to know the
  visible window size (scroll clamp, scrollbar geometry, list
  pagination) reads from `model.width` / `model.height`
  instead of threading dimensions through call sites.
  """

  alias Egghead.OpenTUI.{Colors, Markdown, Readline}
  alias Egghead.RecordStore
  alias Egghead.TUI.Records.Slug

  @type date_format :: :relative | :iso

  @type link_kind :: :forward | :backlink
  @type link_entry :: %{
          required(:target) => String.t(),
          required(:kind) => link_kind()
        }

  @type command :: %{
          required(:name) => String.t(),
          required(:description) => String.t()
        }

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          filter: String.t(),
          filter_cursor: non_neg_integer(),
          selection: non_neg_integer(),
          all: [Egghead.Record.t()],
          filtered: [Egghead.Record.t()],
          selected_id: String.t() | nil,
          selected_record: Egghead.Record.t() | nil,
          selected_body: String.t() | nil,
          show_all_classes: boolean(),
          date_format: date_format(),
          preview_scroll: non_neg_integer(),
          preview_total_lines: non_neg_integer(),
          preview_rendered: Markdown.rendered() | nil,
          preview_rendered_width: pos_integer() | nil,
          preview_footer: Markdown.rendered(),
          preview_links: [link_entry()],
          link_index: non_neg_integer() | nil,
          nav_history: [String.t()],
          command_mode: boolean(),
          command_input: String.t(),
          command_cursor: non_neg_integer(),
          command_selected: non_neg_integer(),
          providers?: boolean()
        }

  defstruct width: 80,
            height: 24,
            filter: "",
            filter_cursor: 0,
            selection: 0,
            all: [],
            filtered: [],
            selected_id: nil,
            selected_record: nil,
            selected_body: nil,
            show_all_classes: false,
            date_format: :relative,
            preview_scroll: 0,
            preview_total_lines: 0,
            preview_rendered: nil,
            preview_rendered_width: nil,
            preview_footer: [],
            preview_links: [],
            link_index: nil,
            nav_history: [],
            command_mode: false,
            command_input: "",
            command_cursor: 0,
            command_selected: 0,
            providers?: false

  # The records-mode command palette. Each entry has a `name`
  # (the part the user types after `/`) and a one-line
  # description that shows in the dropdown.
  @records_commands [
    %{name: "quit", description: "Exit the TUI"},
    %{name: "help", description: "Show keybindings & commands"},
    %{name: "tools", description: "Catalog of tools available to agents"},
    %{name: "mcp", description: "MCP servers and their eligible agents"},
    %{name: "copy", description: "Copy current record to clipboard"},
    %{name: "debug", description: "Dump current view tree to /tmp/egghead-render.log"},
    %{name: "chat", description: "Enter chat mode"},
    %{name: "system", description: "Agent diagnostics (not yet implemented)"}
  ]

  @doc "All registered commands for records mode."
  @spec all_commands() :: [command()]
  def all_commands, do: @records_commands

  @doc "Build the initial model by listing records from the store."
  @spec init() :: t()
  def init do
    all =
      RecordStore.list_records()
      |> Enum.sort_by(&sort_key/1, :desc)

    %__MODULE__{all: all}
    |> refilter()
    |> hydrate_selection()
  end

  # ---- transformations ----------------------------------------------------

  @doc """
  Update cached width and height. Called from the `:resize`
  handler. If the width changed and a record is currently
  selected, the markdown preview cache is recomputed at the new
  width so the scrollbar geometry stays consistent.
  """
  @spec set_dimensions(t(), pos_integer(), pos_integer()) :: t()
  def set_dimensions(%__MODULE__{} = model, w, h) when w > 0 and h > 0 do
    width_changed = model.width != w
    model = %{model | width: w, height: h}

    if width_changed and is_binary(model.selected_body),
      do: recompute_preview(model),
      else: model
  end

  @doc "Reload records from the store, preserving filter / selection / toggles."
  @spec reload(t(), String.t() | nil) :: t()
  def reload(%__MODULE__{} = model, prefer_id \\ nil) do
    all =
      RecordStore.list_records()
      |> Enum.sort_by(&sort_key/1, :desc)

    # When navigating to a specific record (e.g. following a
    # wikilink from chat), clear the filter and show all classes
    # so the target is guaranteed to be visible — same behaviour
    # as follow_active_link / nav_back within records mode.
    model =
      if prefer_id do
        %{model | all: all, filter: "", filter_cursor: 0, show_all_classes: true}
      else
        %{model | all: all}
      end
      |> refilter()

    selection =
      case prefer_id && Enum.find_index(model.filtered, &(&1.id == prefer_id)) do
        nil -> 0
        idx when is_integer(idx) -> idx
      end

    %{model | selection: selection, selected_id: nil}
    |> clamp_selection()
    |> hydrate_selection()
  end

  @doc """
  Recompute `:filtered` from `:all`, the current `:filter`, and
  `:show_all_classes`.
  """
  @spec refilter(t()) :: t()
  def refilter(%__MODULE__{} = model) do
    needle = String.downcase(model.filter)

    filtered =
      model.all
      |> filter_by_class(model.show_all_classes)
      |> filter_by_query(needle)

    %{model | filtered: filtered}
  end

  defp filter_by_class(records, true), do: records

  defp filter_by_class(records, false) do
    Enum.filter(records, fn r -> r.class == :durable end)
  end

  defp filter_by_query(records, ""), do: records

  defp filter_by_query(records, needle) do
    Enum.filter(records, fn r ->
      String.contains?(String.downcase(r.id || ""), needle) or
        String.contains?(String.downcase(r.title || ""), needle)
    end)
  end

  @doc """
  Clamp the selection cursor to `[0, list_total - 1]` where
  `list_total` includes the phantom create row when present.
  """
  @spec clamp_selection(t()) :: t()
  def clamp_selection(%__MODULE__{} = model) do
    n = list_total(model)
    new_sel = if n == 0, do: 0, else: min(model.selection, n - 1)
    %{model | selection: new_sel}
  end

  @doc """
  Hydrate the body of the currently selected record. Cheap if
  the selection hasn't changed since last hydration (id check).
  Resets `:preview_scroll` to 0 whenever the selected record
  changes, exits link-nav mode, and (re)computes the markdown
  render cache so `preview_total_lines` reflects the wrapped
  row count.
  """
  @spec hydrate_selection(t()) :: t()
  def hydrate_selection(%__MODULE__{} = model) do
    case Enum.at(model.filtered, model.selection) do
      nil ->
        %{
          model
          | selected_body: nil,
            selected_id: nil,
            selected_record: nil,
            preview_scroll: 0,
            preview_total_lines: 0,
            preview_rendered: nil,
            preview_rendered_width: nil,
            preview_footer: [],
            preview_links: [],
            link_index: nil
        }

      record ->
        if record.id == model.selected_id do
          model
        else
          full_record =
            case RecordStore.get_record(record.id) do
              {:ok, full} -> full
              _ -> nil
            end

          body =
            case full_record do
              %{body: b} when is_binary(b) -> b
              _ -> "(failed to load)"
            end

          %{
            model
            | selected_body: body,
              selected_id: record.id,
              selected_record: full_record,
              preview_scroll: 0,
              preview_rendered: nil,
              preview_rendered_width: nil,
              preview_footer: [],
              preview_links: [],
              link_index: nil
          }
          |> recompute_preview()
        end
    end
  end

  @doc """
  Re-render the cached markdown body at the model's current text
  width and rebuild the metadata footer (Links + Backlinks) with
  custom span-aware wrapping. The footer is kept separate from
  `preview_rendered` so the body scrolls independently of it.

  Cheap if the cache is already fresh for the current
  `(body, width)` pair.
  """
  @spec recompute_preview(t()) :: t()
  def recompute_preview(%__MODULE__{selected_body: nil} = model) do
    %{
      model
      | preview_rendered: nil,
        preview_rendered_width: nil,
        preview_total_lines: 0,
        preview_footer: [],
        preview_links: []
    }
  end

  def recompute_preview(%__MODULE__{} = model) do
    width = preview_text_width(model)

    if model.preview_rendered != nil and model.preview_rendered_width == width do
      model
    else
      body_rows = Markdown.render(model.selected_body, width)

      forward_targets = forward_targets_for(model.selected_record)
      backlink_records = backlinks_for(model.selected_id)

      backlink_targets =
        backlink_records
        |> Enum.map(& &1.id)
        |> Enum.reject(fn id ->
          id == model.selected_id or id in forward_targets
        end)

      footer_rows = build_footer(forward_targets, backlink_targets, width)

      preview_links =
        Enum.map(forward_targets, &%{target: &1, kind: :forward}) ++
          Enum.map(backlink_targets, &%{target: &1, kind: :backlink})

      %{
        model
        | preview_rendered: body_rows,
          preview_rendered_width: width,
          preview_total_lines: length(body_rows),
          preview_footer: footer_rows,
          preview_links: preview_links
      }
      |> clamp_preview_scroll()
    end
  end

  # ---- link nav -----------------------------------------------------------

  @doc """
  Enter link-nav mode by selecting the first link, or — if
  already in link mode — cycle forward by one. No-op when there
  are no links to cycle.
  """
  @spec link_next(t()) :: t()
  def link_next(%__MODULE__{preview_links: []} = model), do: model

  def link_next(%__MODULE__{preview_links: links, link_index: idx} = model) do
    n = length(links)
    new_idx = if idx == nil, do: 0, else: rem(idx + 1, n)
    %{model | link_index: new_idx} |> scroll_to_active_link()
  end

  @doc """
  Cycle backward through `preview_links`. If not currently in
  link mode, jumps to the LAST link (mirrors how Shift+Tab works
  in browsers and form fields).
  """
  @spec link_prev(t()) :: t()
  def link_prev(%__MODULE__{preview_links: []} = model), do: model

  def link_prev(%__MODULE__{preview_links: links, link_index: idx} = model) do
    n = length(links)
    new_idx = if idx == nil, do: n - 1, else: rem(idx - 1 + n, n)
    %{model | link_index: new_idx} |> scroll_to_active_link()
  end

  @doc "Exit link-nav mode. Idempotent."
  @spec link_deselect(t()) :: t()
  def link_deselect(%__MODULE__{} = model), do: %{model | link_index: nil}

  @doc "True when the user is currently cycling links."
  @spec link_mode?(t()) :: boolean()
  def link_mode?(%__MODULE__{link_index: nil}), do: false
  def link_mode?(%__MODULE__{}), do: true

  @doc """
  The currently-active link entry, or nil. The view consults
  this to know which span gets the reverse-video highlight, and
  the reducer consults it to know what to follow on Enter.
  """
  @spec active_link(t()) :: link_entry() | nil
  def active_link(%__MODULE__{link_index: nil}), do: nil

  def active_link(%__MODULE__{preview_links: links, link_index: idx}) do
    Enum.at(links, idx)
  end

  @doc """
  Follow the active link: push the currently-selected record
  onto the nav history, locate the target in `:all`, jump
  selection to it, and rehydrate the preview. Returns the model
  unchanged if there is no active link or the target doesn't
  exist in the store.
  """
  @spec follow_active_link(t()) :: t()
  def follow_active_link(%__MODULE__{} = model) do
    case active_link(model) do
      nil ->
        model

      %{target: target} ->
        case Enum.find_index(model.all, &(&1.id == target)) do
          nil ->
            model

          idx_in_all ->
            history =
              case model.selected_id do
                nil -> model.nav_history
                id -> [id | model.nav_history]
              end

            %{
              model
              | filter: "",
                filter_cursor: 0,
                show_all_classes: true,
                nav_history: history,
                link_index: nil
            }
            |> refilter()
            |> jump_selection_to(target, idx_in_all)
            |> hydrate_selection()
        end
    end
  end

  @doc """
  Pop the most recent entry from `nav_history` and return to
  it. No-op if the history is empty or the prior record is no
  longer in the store.
  """
  @spec nav_back(t()) :: t()
  def nav_back(%__MODULE__{nav_history: []} = model), do: model

  def nav_back(%__MODULE__{nav_history: [prev | rest]} = model) do
    case Enum.find_index(model.all, &(&1.id == prev)) do
      nil ->
        %{model | nav_history: rest}

      _idx ->
        %{
          model
          | filter: "",
            filter_cursor: 0,
            show_all_classes: true,
            nav_history: rest,
            link_index: nil
        }
        |> refilter()
        |> jump_selection_to(prev, 0)
        |> hydrate_selection()
    end
  end

  defp jump_selection_to(model, target, _fallback_idx) do
    case Enum.find_index(model.filtered, &(&1.id == target)) do
      nil -> %{model | selection: 0}
      idx -> %{model | selection: idx}
    end
  end

  # When the active link is on a row outside the visible window,
  # adjust `preview_scroll` so the row sits in the middle third.
  defp scroll_to_active_link(%__MODULE__{} = model) do
    case active_link(model) do
      nil ->
        model

      %{target: target} ->
        case Markdown.find_wikilink_row(model.preview_rendered || [], target) do
          nil ->
            model

          row_idx ->
            visible = content_h(model)
            scroll = model.preview_scroll

            cond do
              row_idx < scroll ->
                %{model | preview_scroll: max(row_idx - div(visible, 3), 0)}

              row_idx >= scroll + visible ->
                %{
                  model
                  | preview_scroll: max(row_idx - div(visible * 2, 3), 0)
                }
                |> clamp_preview_scroll()

              true ->
                model
            end
        end
    end
  end

  # ---- command palette ---------------------------------------------------

  @doc """
  Enter command mode. Resets the input to "", the cursor to 0,
  and the dropdown cursor to 0. Idempotent.
  """
  @spec enter_command_mode(t()) :: t()
  def enter_command_mode(%__MODULE__{} = model) do
    %{
      model
      | command_mode: true,
        command_input: "",
        command_cursor: 0,
        command_selected: 0
    }
  end

  @doc "Exit command mode. Idempotent."
  @spec exit_command_mode(t()) :: t()
  def exit_command_mode(%__MODULE__{} = model) do
    %{
      model
      | command_mode: false,
        command_input: "",
        command_cursor: 0,
        command_selected: 0
    }
  end

  @doc """
  Insert a character at the command-input cursor. Resets the
  dropdown cursor to 0 because the filtered list shifts.
  """
  @spec command_input_char(t(), String.t()) :: t()
  def command_input_char(%__MODULE__{} = model, char) when is_binary(char) do
    apply_command_edit(model, &Readline.insert(&1, &2, char))
    |> Map.put(:command_selected, 0)
  end

  @doc """
  Delete the character before the cursor. If the input is
  empty, exits command mode (so Backspace at the start of an
  empty input feels like an escape hatch).
  """
  @spec command_backspace(t()) :: t()
  def command_backspace(%__MODULE__{command_input: ""} = model),
    do: exit_command_mode(model)

  def command_backspace(%__MODULE__{} = model) do
    apply_command_edit(model, &Readline.delete_before/2)
    |> Map.put(:command_selected, 0)
  end

  @doc "Kill from cursor to end of input."
  @spec command_kill_to_eol(t()) :: t()
  def command_kill_to_eol(model),
    do: apply_command_edit(model, &Readline.kill_to_eol/2)

  @doc "Kill from beginning of input to cursor."
  @spec command_kill_to_bol(t()) :: t()
  def command_kill_to_bol(model),
    do:
      apply_command_edit(model, &Readline.kill_to_bol/2)
      |> Map.put(:command_selected, 0)

  @doc "Kill the previous word."
  @spec command_kill_word(t()) :: t()
  def command_kill_word(model),
    do:
      apply_command_edit(model, &Readline.kill_word/2)
      |> Map.put(:command_selected, 0)

  @doc "Kill the next word."
  @spec command_kill_word_forward(t()) :: t()
  def command_kill_word_forward(model),
    do:
      apply_command_edit(model, &Readline.kill_word_forward/2)
      |> Map.put(:command_selected, 0)

  @doc "Move the cursor to the beginning of the input."
  @spec command_move_to_start(t()) :: t()
  def command_move_to_start(model),
    do: apply_command_edit(model, &Readline.move_to_start/2)

  @doc "Move the cursor to the end of the input."
  @spec command_move_to_end(t()) :: t()
  def command_move_to_end(model),
    do: apply_command_edit(model, &Readline.move_to_end/2)

  @doc "Move the cursor one character left."
  @spec command_move_left(t()) :: t()
  def command_move_left(model),
    do: apply_command_edit(model, &Readline.move_left/2)

  @doc "Move the cursor one character right."
  @spec command_move_right(t()) :: t()
  def command_move_right(model),
    do: apply_command_edit(model, &Readline.move_right/2)

  @doc "Move the cursor backward one word."
  @spec command_move_word_left(t()) :: t()
  def command_move_word_left(model),
    do: apply_command_edit(model, &Readline.move_word_left/2)

  @doc "Move the cursor forward one word."
  @spec command_move_word_right(t()) :: t()
  def command_move_word_right(model),
    do: apply_command_edit(model, &Readline.move_word_right/2)

  defp apply_command_edit(%__MODULE__{} = model, fun) do
    {new_input, new_cursor} = fun.(model.command_input, model.command_cursor)
    %{model | command_input: new_input, command_cursor: new_cursor}
  end

  @doc "Move the dropdown cursor by `delta`, clamped."
  @spec command_select(t(), integer()) :: t()
  def command_select(%__MODULE__{} = model, delta) do
    n = length(filtered_commands(model))

    new_sel =
      cond do
        n == 0 -> 0
        true -> model.command_selected |> Kernel.+(delta) |> max(0) |> min(n - 1)
      end

    %{model | command_selected: new_sel}
  end

  @doc """
  The list of commands matching the current `command_input` by
  case-insensitive prefix on the command name. Returns all
  commands when the input is empty.
  """
  @spec filtered_commands(t()) :: [command()]
  def filtered_commands(%__MODULE__{command_input: ""}), do: @records_commands

  def filtered_commands(%__MODULE__{command_input: input}) do
    needle = String.downcase(input)

    Enum.filter(@records_commands, fn cmd ->
      String.starts_with?(String.downcase(cmd.name), needle)
    end)
  end

  @doc """
  The currently-highlighted command in the dropdown, or nil if
  the filtered list is empty.
  """
  @spec selected_command(t()) :: command() | nil
  def selected_command(%__MODULE__{} = model) do
    Enum.at(filtered_commands(model), model.command_selected)
  end

  @doc """
  Replace the model's preview with a synthetic in-memory help
  record. The body is rendered through the regular markdown
  pipeline so it picks up theming, span output, and scrolling
  for free. Selecting any other record dismisses it.

  The synthetic record uses class `:synthetic` — it lives only
  in memory, never goes through the parser, never gets indexed,
  and exists for the duration of the user's session. The class
  is outside `Egghead.Record.@valid_classes` on purpose: nothing
  validates it because nothing persists it. `:synthetic` matches
  exactly what the record IS (built in code, not loaded from
  disk), so the preview label reads `── help ── synthetic ──`.
  """
  @spec show_help(t()) :: t()
  def show_help(%__MODULE__{} = model) do
    fake = %Egghead.Record{
      id: "help",
      title: "egghead — help",
      body: help_body(),
      class: :synthetic,
      links: [],
      wikilinks: []
    }

    %{
      model
      | selected_id: "help",
        selected_record: fake,
        selected_body: fake.body,
        preview_scroll: 0,
        preview_rendered: nil,
        preview_rendered_width: nil,
        preview_footer: [],
        preview_links: [],
        link_index: nil
    }
    |> recompute_preview()
  end

  @doc """
  True when the preview is currently showing the synthetic help
  record. We tag the help record with class `:synthetic` (the
  only thing in the model carrying that class), so this check
  is just a class lookup.
  """
  @spec help_visible?(t()) :: boolean()
  def help_visible?(%__MODULE__{selected_record: %{class: :synthetic}}), do: true
  def help_visible?(_), do: false

  @doc """
  Show a synthetic record with the full tools catalog (local +
  MCP servers). Same `:synthetic` class + preview pipeline as
  `/help`.
  """
  @spec show_tools(t()) :: t()
  def show_tools(%__MODULE__{} = model) do
    show_synthetic(model, "tools", "egghead — tools", Egghead.TUI.ToolCatalog.tools_markdown())
  end

  @doc "Show a synthetic record narrowed to MCP servers."
  @spec show_mcp(t()) :: t()
  def show_mcp(%__MODULE__{} = model) do
    show_synthetic(model, "mcp", "egghead — MCP servers", Egghead.TUI.ToolCatalog.mcp_markdown())
  end

  defp show_synthetic(model, id, title, body) do
    links = extract_wikilinks(body)

    fake = %Egghead.Record{
      id: id,
      title: title,
      body: body,
      class: :synthetic,
      # Populate `links:` so Tab cycles through wikilinks in the
      # generated body just like a real record. `wikilinks:` is the
      # parsed frontmatter field, unused here.
      links: links,
      wikilinks: []
    }

    %{
      model
      | selected_id: id,
        selected_record: fake,
        selected_body: fake.body,
        preview_scroll: 0,
        preview_rendered: nil,
        preview_rendered_width: nil,
        preview_footer: [],
        preview_links: [],
        link_index: nil
    }
    |> recompute_preview()
  end

  @doc """
  Dismiss the synthetic help record by re-hydrating the preview
  from the actual list selection. The help record's `selected_id`
  ("help") is cleared first so `hydrate_selection/1` doesn't
  short-circuit on the id-equality fast path.
  """
  @spec dismiss_help(t()) :: t()
  def dismiss_help(%__MODULE__{} = model) do
    %{model | selected_id: nil, selected_record: nil}
    |> hydrate_selection()
  end

  defp help_body do
    """
    # egghead — help

    ## Records mode

    | Key             | Action                                          |
    | :-------------- | :---------------------------------------------- |
    | `↑` / `↓`       | Move selection in the list                      |
    | `Enter`         | Open selected record in `$EDITOR`               |
    | `PgUp` / `PgDn` | Scroll preview ±5 lines                         |
    | `Ctrl+N` / `^P` | Scroll preview ±5 lines (emacs)                 |
    | `Mouse wheel`   | Scroll preview ±3 lines                         |
    | `Tab`           | Cycle forward through links / backlinks         |
    | `Shift+Tab`     | Cycle backward                                  |
    | `Enter` (link)  | Follow active link, push to nav history         |
    | `Backspace`     | Pop nav history (when filter is empty)          |
    | `Esc`           | Exit link mode / command mode                   |
    | `Ctrl+F`        | Toggle class filter (durable / all)             |
    | `Ctrl+T`        | Toggle date format (relative / iso)             |
    | `Ctrl+Z`        | Suspend to background                           |
    | `Ctrl+Q` / `^C` | Quit                                            |

    ## Search bar (readline-style)

    | Key                  | Action                              |
    | :------------------- | :---------------------------------- |
    | `←` / `→`            | Move cursor                         |
    | `Ctrl+A` / `Ctrl+E`  | Beginning / end of input            |
    | `Ctrl+K` / `Ctrl+U`  | Kill to end / beginning of line     |
    | `Ctrl+W`             | Kill previous word                  |
    | `Alt+B` / `Alt+F`    | Move backward / forward by word     |
    | `Alt+D`              | Kill next word                      |

    ## Command palette

    Type `/` (when the search bar is empty) to enter command mode.
    The dropdown filters as you type. `↑↓` selects, `Enter` runs,
    `Esc` cancels.

    ## Creating records

    Type a title in the search bar that doesn't match an existing
    record. A `+ Create "title"` row appears at the bottom of the
    list — `Enter` creates the record and opens it in `$EDITOR`.

    ## Copying text

    Hold `Shift` while clicking and dragging to use your terminal's
    native text selection.

    Press `Esc` to dismiss this help.
    """
  end

  # ---- preview link / footer helpers -------------------------------------

  # Forward link targets for a record. The worktree's parser
  # already merges frontmatter `links:` with body wikilinks into
  # `record.links`, deduped, in order, so we just read it.
  # Pull `[[target]]` refs from a markdown body via the same parser
  # real records go through. Used for synthetic records like
  # `/tools` and `/mcp` whose body is generated in code — nothing
  # loads them through the file parser, so we invoke its extractor
  # directly.
  defp extract_wikilinks(body) do
    Egghead.Record.Parser.extract_wikilinks(body)
    |> Enum.map(& &1.target)
    |> Enum.uniq()
  end

  defp forward_targets_for(nil), do: []

  defp forward_targets_for(%{links: links}) when is_list(links), do: links

  defp forward_targets_for(_), do: []

  defp backlinks_for(nil), do: []

  defp backlinks_for(id) do
    try do
      RecordStore.find_backlinks(id) || []
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  # Build the metadata footer rows from forward + backlink
  # targets. The footer is a list of styled rows in the same
  # `[[span]]` shape the markdown renderer produces, but built
  # by hand so we can:
  #   * label each section ("Links: " / "Backlinks: ")
  #   * wrap link tokens onto multiple rows when a single row
  #     overflows the available width
  #   * keep the rows separate from `preview_rendered` so the
  #     body scrolls independently of the footer
  defp build_footer([], [], _width), do: []

  defp build_footer(forward_targets, backlink_targets, width) do
    forward_rows = link_section_rows("Links: ", forward_targets, width)
    backlink_rows = link_section_rows("Backlinks: ", backlink_targets, width)

    case {forward_rows, backlink_rows} do
      {[], []} -> []
      {rows, []} -> rows
      {[], rows} -> rows
      {f, b} -> f ++ b
    end
  end

  defp link_section_rows(_label, [], _width), do: []

  defp link_section_rows(label, targets, width) do
    label_w = String.length(label)
    indent = String.duplicate(" ", label_w)
    inner_width = max(width - label_w, 1)

    label_ctx = %{fg: Colors.muted(), attrs: 0, link: nil}

    label_span = %{
      text: label,
      fg: label_ctx.fg,
      attrs: 0,
      link: nil
    }

    indent_span = %{
      text: indent,
      fg: label_ctx.fg,
      attrs: 0,
      link: nil
    }

    link_rows = wrap_link_tokens(targets, inner_width)

    case link_rows do
      [] ->
        []

      [first | rest] ->
        first_row = [label_span | first]
        rest_rows = Enum.map(rest, fn row -> [indent_span | row] end)
        [first_row | rest_rows]
    end
  end

  # Greedy fill: each `[[target]]` is one atomic token. If a
  # single token is wider than the available width, we still emit
  # it on its own row (it'll be visually clipped, but at least
  # it's a row by itself instead of corrupting the whole layout).
  # Tokens are space-separated within a row.
  defp wrap_link_tokens(targets, width) do
    tokens = Enum.map(targets, fn t -> "[[#{t}]]" end)

    {rows, current, _used} =
      Enum.reduce(tokens, {[], [], 0}, fn token, {rows, current, used} ->
        token_w = String.length(token)
        sep_w = if current == [], do: 0, else: 1
        needed = sep_w + token_w

        cond do
          current == [] ->
            {rows, [link_span(token)], token_w}

          used + needed > width ->
            {[Enum.reverse(current) | rows], [link_span(token)], token_w}

          true ->
            spans = [link_span(token), space_span() | current]
            {rows, spans, used + needed}
        end
      end)

    final = if current == [], do: rows, else: [Enum.reverse(current) | rows]
    Enum.reverse(final)
  end

  defp link_span(text) do
    target =
      case Regex.run(~r/\A\[\[(.+)\]\]\z/, text) do
        [_, t] -> t
        _ -> text
      end

    %{
      text: text,
      fg: Colors.link(),
      attrs: 0,
      link: {:wikilink, target}
    }
  end

  defp space_span do
    %{text: " ", fg: Colors.white(), attrs: 0, link: nil}
  end

  @doc """
  Width available for rendered markdown text inside the preview
  pane. Mirrors the inner-text math in
  `Egghead.TUI.Records.View.preview_pane/4`: 1 column for the
  scrollbar plus 1 column of leading padding leaves
  `model.width - 2` for actual prose.
  """
  @spec preview_text_width(t()) :: pos_integer()
  def preview_text_width(%__MODULE__{width: w}), do: max(w - 2, 1)

  defp clamp_preview_scroll(%__MODULE__{} = model) do
    max_scroll = max(model.preview_total_lines - content_h(model), 0)
    %{model | preview_scroll: min(model.preview_scroll, max_scroll)}
  end

  @doc """
  Adjust the preview scroll by `delta` lines, clamped against
  the actual visible window size derived from `model.height`.
  """
  @spec scroll_preview(t(), integer()) :: t()
  def scroll_preview(%__MODULE__{} = model, delta) do
    max_scroll = max(model.preview_total_lines - content_h(model), 0)
    new_scroll = model.preview_scroll |> Kernel.+(delta) |> max(0) |> min(max_scroll)
    %{model | preview_scroll: new_scroll}
  end

  @doc "Toggle whether the list shows only `:durable` or all classes."
  @spec toggle_class_filter(t()) :: t()
  def toggle_class_filter(%__MODULE__{} = model) do
    %{model | show_all_classes: not model.show_all_classes}
    |> refilter()
    |> clamp_selection()
    |> hydrate_selection()
  end

  @doc "Toggle the date display format between `:relative` and `:iso`."
  @spec toggle_date_format(t()) :: t()
  def toggle_date_format(%__MODULE__{date_format: :relative} = model),
    do: %{model | date_format: :iso}

  def toggle_date_format(%__MODULE__{date_format: :iso} = model),
    do: %{model | date_format: :relative}

  # ---- phantom create row ------------------------------------------------

  @doc """
  If the trimmed filter would slugify to an id that doesn't yet
  exist, return `{title, slug}`. Otherwise return `nil`. Mirrors
  `Egghead.TUI.App.creation_target/1` on `main`.
  """
  @spec creation_target(t()) :: {String.t(), String.t()} | nil
  def creation_target(%__MODULE__{} = model) do
    title = String.trim(model.filter)

    cond do
      title == "" ->
        nil

      true ->
        slug = Slug.slugify(title)

        cond do
          slug == "" -> nil
          Enum.any?(model.filtered, &(&1.id == slug)) -> nil
          true -> {title, slug}
        end
    end
  end

  @doc "Total list length, counting the phantom create row when present."
  @spec list_total(t()) :: non_neg_integer()
  def list_total(%__MODULE__{} = model) do
    base = length(model.filtered)
    if creation_target(model), do: base + 1, else: base
  end

  @doc "Index of the phantom create row (one past the end of `filtered`), or `nil`."
  @spec phantom_index(t()) :: non_neg_integer() | nil
  def phantom_index(%__MODULE__{} = model) do
    if creation_target(model), do: length(model.filtered), else: nil
  end

  @doc "True if the cursor is currently on the phantom create row."
  @spec phantom_selected?(t()) :: boolean()
  def phantom_selected?(%__MODULE__{} = model) do
    case phantom_index(model) do
      nil -> false
      idx -> idx == model.selection
    end
  end

  @doc """
  Visible content height of the preview body (excluding label
  and metadata footer). Mirrors the chrome math in
  `Egghead.TUI.Records.View.render/1`: `body = h - 6`,
  `list_h = body / 3`, `preview_h = body - list_h`,
  `content_h = preview_h - 1 - footer_h`.
  """
  @spec content_h(t()) :: pos_integer()
  def content_h(%__MODULE__{height: h} = model) do
    body_h = max(h - 6, 1)
    list_h = max(div(body_h, 3), 1)
    preview_h = max(body_h - list_h, 1)
    max(preview_h - 1 - length(model.preview_footer), 1)
  end

  # ---- readline-style filter editing -------------------------------------
  #
  # The search bar maintains a separate `filter_cursor` so the
  # user can move around within the input string instead of being
  # locked to the end. All actions go through `apply_filter_edit`,
  # which delegates the text manipulation to
  # `Egghead.OpenTUI.Readline` (the same module command mode uses)
  # and then re-filters / re-clamps / re-hydrates.

  @doc "Insert `text` at the current cursor position."
  @spec insert_at_cursor(t(), String.t()) :: t()
  def insert_at_cursor(%__MODULE__{} = model, text) when is_binary(text),
    do: apply_filter_edit(model, &Readline.insert(&1, &2, text))

  @doc "Delete the character immediately before the cursor (backspace)."
  @spec delete_before_cursor(t()) :: t()
  def delete_before_cursor(%__MODULE__{} = model),
    do: apply_filter_edit(model, &Readline.delete_before/2)

  @doc "Kill from cursor to end of line."
  @spec kill_to_eol(t()) :: t()
  def kill_to_eol(%__MODULE__{} = model),
    do: apply_filter_edit(model, &Readline.kill_to_eol/2)

  @doc "Kill from beginning of line to cursor."
  @spec kill_to_bol(t()) :: t()
  def kill_to_bol(%__MODULE__{} = model),
    do: apply_filter_edit(model, &Readline.kill_to_bol/2)

  @doc "Kill the word immediately before the cursor (Ctrl+W)."
  @spec kill_word(t()) :: t()
  def kill_word(%__MODULE__{} = model),
    do: apply_filter_edit(model, &Readline.kill_word/2)

  @doc "Move the cursor to the beginning of the input."
  @spec move_cursor_to_start(t()) :: t()
  def move_cursor_to_start(%__MODULE__{} = model),
    do: apply_filter_cursor_edit(model, &Readline.move_to_start/2)

  @doc "Move the cursor to the end of the input."
  @spec move_cursor_to_end(t()) :: t()
  def move_cursor_to_end(%__MODULE__{} = model),
    do: apply_filter_cursor_edit(model, &Readline.move_to_end/2)

  @doc "Move the cursor one character to the left."
  @spec move_cursor_left(t()) :: t()
  def move_cursor_left(%__MODULE__{} = model),
    do: apply_filter_cursor_edit(model, &Readline.move_left/2)

  @doc "Move the cursor one character to the right."
  @spec move_cursor_right(t()) :: t()
  def move_cursor_right(%__MODULE__{} = model),
    do: apply_filter_cursor_edit(model, &Readline.move_right/2)

  @doc "Move the cursor backward one word (Alt+B / Option+B)."
  @spec move_cursor_word_left(t()) :: t()
  def move_cursor_word_left(%__MODULE__{} = model),
    do: apply_filter_cursor_edit(model, &Readline.move_word_left/2)

  @doc "Move the cursor forward one word (Alt+F / Option+F)."
  @spec move_cursor_word_right(t()) :: t()
  def move_cursor_word_right(%__MODULE__{} = model),
    do: apply_filter_cursor_edit(model, &Readline.move_word_right/2)

  @doc "Kill the word immediately after the cursor (Alt+D / Option+D)."
  @spec kill_word_forward(t()) :: t()
  def kill_word_forward(%__MODULE__{} = model),
    do: apply_filter_edit(model, &Readline.kill_word_forward/2)

  # Apply a Readline edit that may change the buffer (and the
  # cursor). Re-runs filtering / selection clamp / preview
  # hydration so the rest of the model stays consistent with the
  # new query.
  defp apply_filter_edit(model, fun) do
    {new_filter, new_cursor} = fun.(model.filter, model.filter_cursor)

    %{model | filter: new_filter, filter_cursor: new_cursor}
    |> refilter()
    |> clamp_selection()
    |> hydrate_selection()
  end

  # Apply a Readline edit that only moves the cursor — no
  # re-filter needed because the buffer didn't change.
  defp apply_filter_cursor_edit(model, fun) do
    {new_filter, new_cursor} = fun.(model.filter, model.filter_cursor)
    %{model | filter: new_filter, filter_cursor: new_cursor}
  end

  # ---- helpers ------------------------------------------------------------

  defp sort_key(%{updated: nil}), do: ""
  defp sort_key(%{updated: u}) when is_binary(u), do: u
  defp sort_key(_), do: ""
end
