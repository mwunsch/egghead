defmodule Egghead.Theme.Roles do
  @moduledoc """
  App-specific colour roles for the TUI chrome.

  These are chat/records-view concepts (a tinted sidebar, a
  user-message background) that don't belong in the
  framework-layer semantic palette. Each role resolves to one of
  the active theme's semantic slots via `Egghead.OpenTUI.Colors`.
  """

  alias Egghead.OpenTUI.Colors

  @doc "Background for the chat sidebar."
  def sidebar_bg, do: Colors.bg_alt()

  @doc "Background for user-authored messages in a chat transcript."
  def user_msg_bg, do: Colors.bg_alt()
end
