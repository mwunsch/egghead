defmodule Egghead.TUI.Chat.Mentions do
  @moduledoc """
  Cursor-aware mention detection for the chat input buffer.

  Two sigils are recognised:

    * `@id` — addresses an agent (e.g. `@agents/scout`). Triggers
      when the cursor sits inside a token immediately following an
      `@` that is itself preceded by whitespace or start-of-line.
    * `[[id]]` — references a record. Triggers when the cursor sits
      inside an open `[[…` that has not yet been closed by `]]`.

  `detect/1` is pure: given an `Egghead.OpenTUI.EditBuffer`, it
  walks backward from the cursor over the current row's cells and
  returns a `%Context{}` if a sigil is in scope, otherwise `nil`.
  Candidate population is done in the Update layer (it requires
  calls to `Egghead.list_agents/0` and `Egghead.search/2`) and
  injected into `:candidates`.

  `accept/2` rewrites the buffer: it deletes the typed prefix and
  inserts the first candidate's id (plus the closing `]]` for
  records). The cursor lands immediately after the inserted text.
  """

  alias Egghead.OpenTUI.EditBuffer

  defmodule Token do
    @moduledoc """
    An accepted mention rendered as an atomic cell in the
    `EditBuffer`. Like a paste chip, one Backspace removes the
    whole token and `to_text/1` expands `:full_text`.
    """
    @type t :: %__MODULE__{
            kind: :agent | :record,
            id: String.t(),
            display: String.t(),
            full_text: String.t()
          }
    defstruct [:kind, :id, :display, :full_text]
  end

  defmodule Context do
    @moduledoc false
    @type kind :: :agent | :record
    @type t :: %__MODULE__{
            kind: kind(),
            prefix: String.t(),
            start_col: non_neg_integer(),
            end_col: non_neg_integer(),
            candidates: [map()],
            selected: non_neg_integer()
          }
    defstruct [:kind, :prefix, :start_col, :end_col, candidates: [], selected: 0]
  end

  @id_extra ["/", "-", "_", "."]

  @doc """
  Scan the buffer for an active mention sigil. Returns a
  `%Context{}` (with empty `:candidates`) when one is in scope,
  or `nil`.
  """
  @spec detect(EditBuffer.t()) :: Context.t() | nil
  def detect(%EditBuffer{} = buffer) do
    {row, col} = EditBuffer.cursor(buffer)
    cells = EditBuffer.line_cells(buffer, row)
    walk_back(cells, col - 1, [], col)
  end

  # Walked all the way to start of line without finding a sigil.
  defp walk_back(_cells, idx, _acc, _end_col) when idx < 0, do: nil

  defp walk_back(cells, idx, acc, end_col) do
    case Enum.at(cells, idx) do
      nil ->
        nil

      cell when not is_binary(cell) ->
        # A non-rune cell (like a paste chip) terminates the scan.
        nil

      "@" ->
        if boundary_ok?(cells, idx - 1) do
          %Context{
            kind: :agent,
            prefix: Enum.join(acc),
            start_col: idx + 1,
            end_col: end_col
          }
        else
          nil
        end

      "[" ->
        # Guard `idx - 1 >= 0` explicitly: `Enum.at/2` with a
        # negative index wraps to the end of the list, so without
        # this a single `[` at the start of a row would erroneously
        # match itself as the "preceding" bracket.
        if idx >= 1 and Enum.at(cells, idx - 1) == "[" do
          %Context{
            kind: :record,
            prefix: Enum.join(acc),
            start_col: idx + 1,
            end_col: end_col
          }
        else
          nil
        end

      "]" ->
        # An already-closed `]]` cuts off the scan.
        nil

      ch ->
        if id_char?(ch),
          do: walk_back(cells, idx - 1, [ch | acc], end_col),
          else: nil
    end
  end

  # The character preceding `@` must be whitespace or non-existent.
  # This keeps email addresses from triggering mention mode.
  defp boundary_ok?(_cells, idx) when idx < 0, do: true

  defp boundary_ok?(cells, idx) do
    case Enum.at(cells, idx) do
      nil -> true
      cell when is_binary(cell) -> cell in [" ", "\t"]
      _ -> false
    end
  end

  defp id_char?(c) when c in @id_extra, do: true

  defp id_char?(<<b>>)
       when (b >= ?a and b <= ?z) or (b >= ?A and b <= ?Z) or (b >= ?0 and b <= ?9),
       do: true

  defp id_char?(_), do: false

  @doc """
  Filter and rank a list of agent maps by basename prefix.
  Case-insensitive. Preserves the input order (caller is
  responsible for sorting by recency / activation), then
  returns at most `:limit` results (default 8).
  """
  @spec rank_agents([map()], String.t(), keyword()) :: [map()]
  def rank_agents(agents, prefix, opts \\ []) when is_list(agents) and is_binary(prefix) do
    limit = Keyword.get(opts, :limit, 8)
    needle = String.downcase(prefix)

    agents
    |> Enum.filter(fn a ->
      a |> agent_basename() |> String.downcase() |> String.starts_with?(needle)
    end)
    |> Enum.take(limit)
  end

  defp agent_basename(%{id: id}), do: id |> String.split("/") |> List.last()
  defp agent_basename(%{"id" => id}), do: id |> String.split("/") |> List.last()

  @doc """
  Filter and rank a list of record maps by full-id prefix.
  Case-insensitive. Preserves the input order (caller is
  responsible for sorting by recency), then returns at most
  `:limit` results (default 8).
  """
  @spec rank_records([map()], String.t(), keyword()) :: [map()]
  def rank_records(records, prefix, opts \\ []) when is_list(records) and is_binary(prefix) do
    limit = Keyword.get(opts, :limit, 8)
    needle = String.downcase(prefix)

    records
    |> Enum.filter(fn r ->
      r |> record_id() |> String.downcase() |> String.starts_with?(needle)
    end)
    |> Enum.take(limit)
  end

  defp record_id(%{id: id}), do: id
  defp record_id(%{"id" => id}), do: id

  @doc """
  The ghost-text suffix to display after the cursor for the
  currently-selected candidate, or `""` if the prefix doesn't
  strictly extend that candidate's id.
  """
  @spec ghost_suffix(Context.t()) :: String.t()
  def ghost_suffix(%Context{candidates: []}), do: ""

  def ghost_suffix(%Context{kind: kind, prefix: prefix} = ctx) do
    full =
      case kind do
        :agent -> agent_basename(selected_candidate(ctx))
        :record -> record_id(selected_candidate(ctx))
      end

    if String.starts_with?(String.downcase(full), String.downcase(prefix)) do
      String.slice(full, String.length(prefix)..-1//1)
    else
      ""
    end
  end

  @doc """
  Move the dropdown selection up one row, wrapping at the top.
  """
  @spec move_up(Context.t()) :: Context.t()
  def move_up(%Context{candidates: []} = ctx), do: ctx

  def move_up(%Context{candidates: cs, selected: s} = ctx) do
    %{ctx | selected: rem(s - 1 + length(cs), length(cs))}
  end

  @doc """
  Move the dropdown selection down one row, wrapping at the bottom.
  """
  @spec move_down(Context.t()) :: Context.t()
  def move_down(%Context{candidates: []} = ctx), do: ctx

  def move_down(%Context{candidates: cs, selected: s} = ctx) do
    %{ctx | selected: rem(s + 1, length(cs))}
  end

  defp selected_candidate(%Context{candidates: cs, selected: s}) do
    Enum.at(cs, min(s, length(cs) - 1))
  end

  @doc """
  Apply the selected candidate to the buffer: delete the typed
  prefix *and* the sigil (`@` or `[[`), then insert an atomic
  `%Token{}` cell so the mention renders as a single styled
  chip in the input box. Returns the original buffer unchanged
  when the context has no candidates.
  """
  @spec accept(EditBuffer.t(), Context.t()) :: EditBuffer.t()
  def accept(buffer, %Context{candidates: []}), do: buffer

  def accept(buffer, %Context{kind: :agent, prefix: prefix} = ctx) do
    chosen = selected_candidate(ctx)
    id = agent_id(chosen)

    token = %Token{
      kind: :agent,
      id: id,
      display: "@#{id}",
      full_text: "@#{id}"
    }

    # Delete prefix + the `@` sigil (1 extra char).
    buffer
    |> delete_n_before(String.length(prefix) + 1)
    |> EditBuffer.insert_cell(token)
  end

  def accept(buffer, %Context{kind: :record, prefix: prefix} = ctx) do
    chosen = selected_candidate(ctx)
    id = record_id(chosen)

    token = %Token{
      kind: :record,
      id: id,
      display: "[[#{id}]]",
      full_text: "[[#{id}]]"
    }

    # Delete prefix + the `[[` sigil (2 extra chars).
    buffer
    |> delete_n_before(String.length(prefix) + 2)
    |> EditBuffer.insert_cell(token)
  end

  defp agent_id(%{id: id}), do: id
  defp agent_id(%{"id" => id}), do: id

  defp delete_n_before(buffer, 0), do: buffer

  defp delete_n_before(buffer, n) when n > 0,
    do: delete_n_before(EditBuffer.delete_before(buffer), n - 1)
end
