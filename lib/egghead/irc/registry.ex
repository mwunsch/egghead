defmodule Egghead.IRC.Registry do
  @moduledoc """
  Registry of live IRC connections, keyed by nickname.

  One entry per registered (NICK + USER complete) connection. Used by
  the connection handler to detect nick collisions on `NICK` and by
  future code paths (DM lookup, `egghead irc status`) to find a peer
  by nick.

  Started as a child of `Egghead.IRC.Supervisor`. Pre-registration
  connections are not in the registry — they have no nick yet.
  """

  @doc "Returns the child spec for the connection registry."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Register the calling process under `nick`. Returns `:ok` if the nick
  is free, `{:error, :nickname_in_use}` if another live connection holds it.
  """
  @spec register(String.t()) :: :ok | {:error, :nickname_in_use}
  def register(nick) when is_binary(nick) do
    case Registry.register(__MODULE__, key(nick), nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :nickname_in_use}
    end
  end

  @doc "Release the calling process's claim on `nick` (if it holds it)."
  @spec unregister(String.t()) :: :ok
  def unregister(nick) when is_binary(nick) do
    Registry.unregister(__MODULE__, key(nick))
    :ok
  end

  @doc """
  Re-register the calling process from `old_nick` to `new_nick` atomically
  enough for our needs (Registry doesn't expose a true atomic rename, but
  collisions on `new_nick` are rejected before we drop the old one).
  """
  @spec rename(String.t(), String.t()) :: :ok | {:error, :nickname_in_use}
  def rename(old_nick, new_nick) do
    case register(new_nick) do
      :ok ->
        unregister(old_nick)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc "Look up the pid holding `nick`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(nick) when is_binary(nick) do
    case Registry.lookup(__MODULE__, key(nick)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "All currently-registered nicks, sorted alphabetically (case-insensitive)."
  @spec all_nicks() :: [String.t()]
  def all_nicks do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort_by(&String.downcase/1)
  end

  # IRC nicks are case-insensitive on the wire — `Mark` and `mark` collide.
  # Store the canonical (lowercase) form as the key; the connection
  # remembers the display-cased version separately.
  defp key(nick), do: String.downcase(nick)
end
