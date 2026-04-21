defmodule Egghead.TUI.Completion do
  @moduledoc """
  Inline completion dropdown — the shared machinery behind
  `@`-mentions, `[[`-records, the `/` command palette, and
  argument pickers like `/join <room>`.

  A completion is open *alongside* the input buffer — the user
  keeps typing in the buffer, and the dropdown suggests items
  based on what's under the cursor. Tab or Enter accepts; arrow
  keys move the selection. This is distinct from
  `Egghead.TUI.SelectList`, which is a modal picker that takes
  over input.

  ## Providers

  Each trigger is a module that implements the
  `Egghead.TUI.Completion.Provider` behaviour. A provider owns:

    * **detection** — given the current edit buffer (and model
      state for context, e.g. the list of agents or rooms),
      returns either `nil` (trigger not in scope) or a
      `%Completion{}` struct pre-populated with ranked candidates.
    * **accept** — transforms the buffer when the user commits
      a candidate. Most triggers return `{:edit, buffer}` to
      mutate the input in place; a provider can return
      `{:submit, term}` if selecting the candidate should
      dispatch an action instead.
    * **rendering hints** — label, optional hint string, dropdown
      title.

  ## Host loop

      # After every edit to the buffer:
      completion = Completion.refresh(providers, buffer, model)

      # Arrow nav while open:
      completion = Completion.move_down(completion)

      # Tab or Enter while open:
      {completion, action} = Completion.accept(completion, buffer)

  The host then applies `action` (`{:edit, buffer}` or `{:submit, term}`).
  """

  alias Egghead.OpenTUI.EditBuffer

  @type candidate :: map()

  @type t :: %__MODULE__{
          provider: module(),
          prefix: String.t(),
          start_col: non_neg_integer(),
          end_col: non_neg_integer(),
          candidates: [candidate()],
          selected: non_neg_integer(),
          meta: map()
        }

  defstruct [:provider, :prefix, :start_col, :end_col, candidates: [], selected: 0, meta: %{}]

  @type accept_action ::
          {:edit, EditBuffer.t()}
          | {:submit, term()}
          | :noop

  # ---- Public API ---------------------------------------------------------

  @doc """
  Run each provider's detector in order; the first that matches
  owns the completion. Returns `nil` if no provider applies
  (completion dropdown should be closed).
  """
  @spec refresh([module()], EditBuffer.t(), term()) :: t() | nil
  def refresh(providers, buffer, model) when is_list(providers) do
    # Providers return nil when the trigger isn't in scope at all;
    # a completion with empty candidates means the trigger IS active
    # but the typed prefix has no matches yet. Keep it so the user
    # can keep typing and see candidates re-populate.
    Enum.find_value(providers, fn provider ->
      case provider.detect(buffer, model) do
        nil -> nil
        %__MODULE__{} = completion -> completion
      end
    end)
  end

  @doc "Move the selection cursor forward, wrapping at the bottom."
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{candidates: []} = c), do: c

  def move_down(%__MODULE__{candidates: cs, selected: s} = c) do
    %{c | selected: rem(s + 1, length(cs))}
  end

  @doc "Move the selection cursor backward, wrapping at the top."
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{candidates: []} = c), do: c

  def move_up(%__MODULE__{candidates: cs, selected: s} = c) do
    %{c | selected: rem(s - 1 + length(cs), length(cs))}
  end

  @doc "The currently-focused candidate, or nil."
  @spec focused(t()) :: candidate() | nil
  def focused(%__MODULE__{candidates: cs, selected: s}) do
    Enum.at(cs, min(s, length(cs) - 1))
  end

  @doc """
  Delegate acceptance to the provider. Returns whatever the
  provider returned — typically `{:edit, buffer}` for inline
  completion, `{:submit, term}` for dispatch-on-select, or
  `:noop` if there's nothing to commit.
  """
  @spec accept(t(), EditBuffer.t()) :: accept_action()
  def accept(%__MODULE__{} = completion, buffer) do
    case focused(completion) do
      nil -> :noop
      candidate -> completion.provider.accept(buffer, completion, candidate)
    end
  end

  @doc """
  The ghost-text suffix the provider wants to render after the
  cursor to preview the focused candidate. Returns `""` when
  there's no meaningful extension.
  """
  @spec ghost_suffix(t()) :: String.t()
  def ghost_suffix(%__MODULE__{candidates: []}), do: ""

  def ghost_suffix(%__MODULE__{provider: provider} = completion) do
    if function_exported?(provider, :ghost_suffix, 1),
      do: provider.ghost_suffix(completion),
      else: ""
  end

  # ---- Low-level helpers for providers -----------------------------------

  @doc """
  Delete `n` rune cells before the cursor. Used by providers'
  accept functions to remove the typed prefix (and sigil)
  before inserting a token or completed string.
  """
  @spec delete_n_before(EditBuffer.t(), non_neg_integer()) :: EditBuffer.t()
  def delete_n_before(buffer, 0), do: buffer

  def delete_n_before(buffer, n) when n > 0 do
    delete_n_before(EditBuffer.delete_before(buffer), n - 1)
  end
end
