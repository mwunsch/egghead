defmodule Egghead.TUI.Records.Model do
  @moduledoc """
  State for the records-list screen.

  Phase 5a holds only the fields the Phase 4 imperative
  implementation needed: filter string, selection cursor, the
  full record set, the filtered subset, the hydrated body for
  the current selection, and cached terminal dimensions. Later
  sub-phases extend this struct with `show_all_classes`,
  `date_format`, `link_index`, `nav_history`, `command_mode`,
  etc. as features land.
  """

  alias Egghead.RecordStore

  @type t :: %__MODULE__{
          filter: String.t(),
          selection: non_neg_integer(),
          all: [Egghead.Record.t()],
          filtered: [Egghead.Record.t()],
          selected_id: String.t() | nil,
          selected_body: String.t() | nil
        }

  defstruct filter: "",
            selection: 0,
            all: [],
            filtered: [],
            selected_id: nil,
            selected_body: nil

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

  @doc "Recompute `:filtered` from `:all` and the current `:filter`."
  @spec refilter(t()) :: t()
  def refilter(%__MODULE__{} = model) do
    needle = String.downcase(model.filter)

    filtered =
      if needle == "" do
        model.all
      else
        Enum.filter(model.all, fn r ->
          String.contains?(String.downcase(r.id || ""), needle) or
            String.contains?(String.downcase(r.title || ""), needle)
        end)
      end

    %{model | filtered: filtered}
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
  """
  @spec hydrate_selection(t()) :: t()
  def hydrate_selection(%__MODULE__{} = model) do
    case Enum.at(model.filtered, model.selection) do
      nil ->
        %{model | selected_body: nil, selected_id: nil}

      record ->
        if record.id == model.selected_id do
          model
        else
          case RecordStore.get_record(record.id) do
            {:ok, full} ->
              %{model | selected_body: full.body || "", selected_id: record.id}

            _ ->
              %{model | selected_body: "(failed to load)", selected_id: record.id}
          end
        end
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp sort_key(%{updated: nil}), do: ""
  defp sort_key(%{updated: u}) when is_binary(u), do: u
  defp sort_key(_), do: ""
end
