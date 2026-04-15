defmodule Egghead.Chat.PassActions do
  @moduledoc """
  System-wide pool of flavor text for rendering `/pass` as a `/me`-style
  action line in the chat UI.

  When an agent emits `/pass`, the transcript-of-record still stores the
  raw token `/pass` verbatim (so rehydrate is deterministic and other
  agents reading the transcript see the explicit yield). The UI then
  picks one of these action templates to render in place of the token,
  producing an atmospheric italic line in the room.

  The pool is intentionally agent-agnostic. Per-agent flavor belongs to
  the agent record, not the framework — this module assumes it is given
  only a display name and picks a neutral action appropriate for any
  participant. Pool selection is deterministic-random per pass event so
  the same `/pass` in the same render context produces the same line.
  """

  @actions [
    "shuffles through notes, finds nothing new",
    "checks the map, says nothing",
    "leans back in the chair",
    "taps the desk twice",
    "skims the transcript in silence",
    "looks out the window",
    "nods, deferring",
    "sets down the pen",
    "crosses arms and listens",
    "raises an eyebrow but says nothing",
    "shrugs",
    "consults an index card, reshelves it",
    "makes a mental note",
    "sips coffee",
    "glances at the ceiling",
    "files the thought for later",
    "stays quiet — the room's got it",
    "considers, then passes the ball"
  ]

  @doc """
  Pick a flavor line for a given agent. The `name` is the agent's display
  name (used only by callers that want to prepend it themselves — this
  function returns just the action fragment so callers can format it
  however their UI renders action lines).

  `seed` (optional) makes the pick deterministic; defaults to a uniform
  random choice. Typical caller uses the agent id + a timestamp so the
  same `/pass` event renders the same line across tabs / reconnects.
  """
  @spec pick(String.t() | nil) :: String.t()
  def pick(seed \\ nil) do
    case seed do
      nil -> Enum.random(@actions)
      s when is_binary(s) -> Enum.at(@actions, :erlang.phash2(s, length(@actions)))
    end
  end

  @doc """
  The full action pool, for tests and inspection.
  """
  def all, do: @actions
end
