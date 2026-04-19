defmodule Egghead.Web.DocSocket do
  @moduledoc false
  use Phoenix.Socket

  channel "doc:*", Egghead.Web.DocChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
