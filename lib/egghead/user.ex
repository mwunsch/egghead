defmodule Egghead.User do
  @moduledoc """
  Represents the current Egghead user.

  The user is the human operating this Egghead instance. Their identity
  is used for record authorship, chat messages, and distinguishing human
  input from agent output.

  Resolution order:
  1. Explicit configuration (future: ~/.egghead/user.yml)
  2. `EGGHEAD_USER` environment variable
  3. System `USER` environment variable

  In a multi-user future, this becomes per-session identity.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t()
        }

  defstruct [:id, :name]

  @doc """
  Returns the current user.
  """
  @spec current() :: t()
  def current do
    name = System.get_env("EGGHEAD_USER") || System.get_env("USER") || "user"

    %__MODULE__{
      id: name,
      name: name
    }
  end
end
