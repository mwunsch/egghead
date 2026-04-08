defmodule Egghead.TUI.Records.Model do
  @moduledoc """
  State for the records-list screen.

  Phase 5b adds three filter/display knobs to the Phase 5a
  baseline:

    * `show_all_classes` — when false (default), the list shows
      only `:durable` records. When true, all classes are shown.
      Toggled by `Ctrl+F`.
    * `date_format` — `:relative` (default) or `:iso`. Toggled
      by `Ctrl+T`. Pure display concern, doesn't affect filter.
    * `preview_scroll` — line offset into the selected record's
      body. Adjusted by Page Up/Down and Ctrl+J/K/N/P. Reset to
      0 whenever the selection changes.
  """

  alias Egghead.RecordStore

  @type date_format :: :relative | :iso

  @type t :: %__MODULE__{
          filter: String.t(),
          selection: non_neg_integer(),
          all: [Egghead.Record.t()],
          filtered: [Egghead.Record.t()],
          selected_id: String.t() | nil,
          selected_body: String.t() | nil,
          show_all_classes: boolean(),
          date_format: date_format(),
          preview_scroll: non_neg_integer(),
          preview_total_lines: non_neg_integer()
        }

  defstruct filter: "",
            selection: 0,
            all: [],
            filtered: [],
            selected_id: nil,
            selected_body: nil,
            show_all_classes: false,
            date_format: :relative,
            preview_scroll: 0,
            preview_total_lines: 0

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
  Recompute `:filtered` from `:all`, the current `:filter`, and
  `:show_all_classes`. Also clamps `:selection` since the result
  may be shorter than before.
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

  @doc "Clamp the selection cursor to the bounds of the filtered list."
  @spec clamp_selection(t()) :: t()
  def clamp_selection(%__MODULE__{} = model) do
    n = length(model.filtered)
    new_sel = if n == 0, do: 0, else: min(model.selection, n - 1)
    %{model | selection: new_sel}
  end

  @doc """
  Hydrate the body of the currently selected record. Cheap if
  the selection hasn't changed since last hydration (id check).
  Resets `:preview_scroll` to 0 whenever the selected record
  changes, and caches `:preview_total_lines` for clamp logic.
  """
  @spec hydrate_selection(t()) :: t()
  def hydrate_selection(%__MODULE__{} = model) do
    case Enum.at(model.filtered, model.selection) do
      nil ->
        %{
          model
          | selected_body: nil,
            selected_id: nil,
            preview_scroll: 0,
            preview_total_lines: 0
        }

      record ->
        if record.id == model.selected_id do
          model
        else
          {body, total_lines} =
            case RecordStore.get_record(record.id) do
              {:ok, full} ->
                b = full.body || ""
                {b, line_count(b)}

              _ ->
                {"(failed to load)", 1}
            end

          %{
            model
            | selected_body: body,
              selected_id: record.id,
              preview_scroll: 0,
              preview_total_lines: total_lines
          }
        end
    end
  end

  @doc """
  Adjust the preview scroll by `delta` lines, clamped to
  `[0, max(total - 1, 0)]`. The view is responsible for picking
  the actual visible window size.
  """
  @spec scroll_preview(t(), integer()) :: t()
  def scroll_preview(%__MODULE__{} = model, delta) do
    max_scroll = max(model.preview_total_lines - 1, 0)
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

  # ---- helpers ------------------------------------------------------------

  defp sort_key(%{updated: nil}), do: ""
  defp sort_key(%{updated: u}) when is_binary(u), do: u
  defp sort_key(_), do: ""

  defp line_count(""), do: 1
  defp line_count(body) when is_binary(body) do
    body |> String.split("\n") |> length()
  end
end
