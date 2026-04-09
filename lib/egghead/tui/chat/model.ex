defmodule Egghead.TUI.Chat.Model do
  @moduledoc """
  Chat-screen model. Phase 6a is a placeholder; real fields land
  in Phase 6c (transcript, streams, input, presence, scroll, …).

  The model owns its `width` and `height`. The runtime's
  `{:resize, w, h}` synthetic message keeps them in sync.
  """

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          opts: keyword()
        }

  defstruct width: 80, height: 24, opts: []

  @spec init(keyword()) :: t()
  def init(opts) when is_list(opts), do: %__MODULE__{opts: opts}
  def init(_other), do: %__MODULE__{}
end
