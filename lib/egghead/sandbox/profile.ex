defmodule Egghead.Sandbox.Profile do
  @moduledoc """
  Platform-agnostic description of a sandbox fence.

  Consumed by `Egghead.Sandbox.spawn/3`, which translates it to
  `sandbox-exec` Scheme on macOS or `bwrap` argv on Linux.

  Fields:

  - `roots` — absolute paths the subprocess may read and write. Must be
    non-empty; an empty `roots` is refused at `spawn/3` because it
    would mean "no filesystem access at all", which is never useful for
    the programs we actually run.
  - `net` — `false` blocks all network; `true` allows all network;
    a list of hostnames allows only those (macOS only; Linux treats a
    list the same as `true` in this pass, pending a net-namespace +
    proxy follow-up).
  - `extra_rw` — additional writable paths outside `roots`. Defaults
    to the empty list. Callers that need system tmp access must pass
    it explicitly — the sandbox should not silently grant `/tmp`
    writes, which would be an escape vector for any subprocess.
  """

  @type t :: %__MODULE__{
          roots: [String.t()],
          net: boolean() | [String.t()],
          extra_rw: [String.t()]
        }

  defstruct roots: [], net: false, extra_rw: []

  @doc """
  Builds a profile from a hoisted sandbox root (a single absolute path)
  plus options. This is the common path used by `Tool.ProcExec` and
  friends once the hoisting chain has resolved.
  """
  @spec from_root(String.t(), keyword()) :: t()
  def from_root(root, opts \\ []) when is_binary(root) do
    %__MODULE__{
      roots: [root],
      net: Keyword.get(opts, :net, false),
      extra_rw: Keyword.get(opts, :extra_rw, [])
    }
  end

  @doc """
  Returns `:ok` if the profile is usable, `{:error, reason}` otherwise.
  Called by `Sandbox.spawn/3` before any platform work.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{roots: []}), do: {:error, "sandbox profile has no roots"}

  def validate(%__MODULE__{roots: roots}) do
    case Enum.find(roots, fn r -> not (is_binary(r) and Path.type(r) == :absolute) end) do
      nil -> :ok
      bad -> {:error, "sandbox root must be absolute, got #{inspect(bad)}"}
    end
  end
end
