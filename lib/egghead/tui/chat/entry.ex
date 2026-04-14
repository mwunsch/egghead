defmodule Egghead.TUI.Chat.Entry do
  @moduledoc """
  A committed display entry in the chat transcript.

  Streamed agent text becomes one or more `:agent` entries (one
  per `\\n\\n`-delimited paragraph). User messages become
  `:user` entries. Tool calls — rendered as `/me`-style action
  lines — become `:action`. Coordinator notices like
  `:budget_exhausted` become `:system` lines. Handoff
  acknowledgements get their own `:handoff` kind so the view
  can mark them visually.

  Entries are immutable: once committed, the view never has to
  reach back into the stream to fix them up. The in-progress
  buffer lives in `Egghead.TUI.Chat.Stream`.
  """

  @type kind :: :user | :agent | :system | :action | :handoff | :denial

  @type t :: %__MODULE__{
          kind: kind(),
          sender_id: String.t() | nil,
          sender_name: String.t() | nil,
          text: String.t(),
          timestamp: DateTime.t() | nil,
          metadata: map()
        }

  defstruct kind: :system,
            sender_id: nil,
            sender_name: nil,
            text: "",
            timestamp: nil,
            metadata: %{}

  @spec user(String.t(), String.t()) :: t()
  def user(name, text) do
    %__MODULE__{
      kind: :user,
      sender_name: name,
      text: text,
      timestamp: DateTime.utc_now()
    }
  end

  @spec agent(String.t(), String.t(), String.t()) :: t()
  def agent(id, name, text) do
    %__MODULE__{
      kind: :agent,
      sender_id: id,
      sender_name: name,
      text: text,
      timestamp: DateTime.utc_now()
    }
  end

  @spec action(String.t(), String.t(), String.t()) :: t()
  def action(id, name, text) do
    %__MODULE__{
      kind: :action,
      sender_id: id,
      sender_name: name,
      text: text,
      timestamp: DateTime.utc_now()
    }
  end

  @spec system(String.t()) :: t()
  def system(text) do
    %__MODULE__{
      kind: :system,
      text: text,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  A capability denial — an agent attempted a tool call outside its
  grants. The full `%Egghead.Capability.Denial{}` lives in metadata
  so views can expand it. `text` is the pre-rendered display string.
  """
  @spec denial(String.t(), String.t(), String.t(), map()) :: t()
  def denial(agent_id, agent_name, text, denial) do
    %__MODULE__{
      kind: :denial,
      sender_id: agent_id,
      sender_name: agent_name,
      text: text,
      timestamp: DateTime.utc_now(),
      metadata: %{denial: denial}
    }
  end
end
