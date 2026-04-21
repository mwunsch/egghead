defmodule Egghead.TUI.Completion.Provider do
  @moduledoc """
  Behaviour for completion providers.

  Each provider is a compile-time module that knows how to
  detect its trigger in an edit buffer, rank candidates for the
  current prefix, commit a selection back into the buffer, and
  render labels for the dropdown.

  Providers are stateless — all state lives in the
  `%Egghead.TUI.Completion{}` struct they return from `detect/2`.
  """

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Completion

  @doc """
  Examine the buffer + model. Returns a populated completion
  struct when this provider's trigger applies, `nil` otherwise.

  Implementations typically:
    1. walk back from the cursor looking for a sigil,
    2. extract the prefix between the sigil and the cursor,
    3. rank candidates against that prefix + model state,
    4. fill `%Completion{provider: __MODULE__, ...}`.
  """
  @callback detect(EditBuffer.t(), model :: term()) :: Completion.t() | nil

  @doc """
  Commit `candidate` into `buffer`. Return `{:edit, new_buffer}`
  to continue editing in the input, or `{:submit, action}` to
  ask the host to dispatch `action`.
  """
  @callback accept(EditBuffer.t(), Completion.t(), Completion.candidate()) ::
              Completion.accept_action()

  @doc "Primary label rendered in the dropdown row."
  @callback label(Completion.candidate()) :: String.t()

  @doc "Short title for the dropdown (e.g. \"agent\", \"room\"). Used by the renderer."
  @callback title() :: String.t()

  @doc "Optional secondary hint rendered dim at the end of a row."
  @callback hint(Completion.candidate()) :: String.t() | nil

  @doc """
  Optional ghost-text extension for the currently-focused
  candidate. Defaults to `""`.
  """
  @callback ghost_suffix(Completion.t()) :: String.t()

  @optional_callbacks [hint: 1, ghost_suffix: 1]
end
