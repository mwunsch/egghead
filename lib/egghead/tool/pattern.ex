defmodule Egghead.Tool.Pattern do
  @moduledoc """
  Shell command pattern matching — the scope vocabulary for
  `shell.exec` capabilities.

  Mirrors Claude Code / OpenCode conventions:

  - `cmds:` is a literal argv[0] allowlist. `cmds: [rg, jq]`
    permits `rg` and `jq` with any arguments.
  - `patterns:` is a list of glob-style patterns matched against the
    full invocation string:
    - `"npm test"` — exact literal match
    - `"git log *"` — `*` is a one-arg wildcard
    - `"git:*"` — Claude-Code shorthand: argv[0] == git, rest is `*`
    - `"*"` — explicit "everything" (auditable wildcard)

  Matching is allow-list — no NOT patterns. Unknown commands deny.
  """

  @doc """
  Checks an argv list against a scope map. Returns `:ok` on match,
  `{:scope_violation, reason}` otherwise.

  ## Scope shape

      %{
        cmds: ["rg", "jq"],        # argv[0] literal allowlist
        patterns: ["npm test", "git log *", "git:*"]
      }

  Either key may be absent; both empty means deny.
  """
  @spec check(argv :: [String.t()], scope :: map()) ::
          :ok | {:scope_violation, String.t()}
  def check([], _scope), do: {:scope_violation, "empty invocation"}

  def check([cmd | _] = argv, scope) do
    cmds = Map.get(scope, :cmds, []) |> Enum.map(&to_string/1)
    patterns = Map.get(scope, :patterns, []) |> Enum.map(&to_string/1)

    cond do
      cmds == [] and patterns == [] ->
        {:scope_violation, "shell.exec with no cmds or patterns — nothing allowed"}

      cmd in cmds ->
        :ok

      pattern_allows?(argv, patterns) ->
        :ok

      true ->
        {:scope_violation, "#{format_argv(argv)} not permitted by shell.exec grant"}
    end
  end

  @doc """
  Formats argv as the command the user would see. Args with
  shell-significant characters get single-quoted.
  """
  @spec format_argv([String.t()]) :: String.t()
  def format_argv(argv) do
    Enum.map_join(argv, " ", &maybe_quote/1)
  end

  defp maybe_quote(arg) do
    if String.match?(arg, ~r/[\s"'$&|;<>*?()]/) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end

  defp pattern_allows?([cmd | _] = argv, patterns) do
    invocation = Enum.join(argv, " ")
    Enum.any?(patterns, &match_one?(cmd, invocation, &1))
  end

  # `*` matches everything (explicit wildcard).
  defp match_one?(_cmd, _invocation, "*"), do: true

  # `prefix:*` — Claude Code shorthand for "argv[0] == prefix, any args".
  defp match_one?(cmd, invocation, pattern) do
    case String.split(pattern, ":", parts: 2) do
      [^cmd, "*"] -> true
      _ -> Regex.match?(pattern_to_regex(pattern), invocation)
    end
  end

  # Glob → regex. `*` is multi-char, `?` is single-char.
  # Special handling: a trailing ` *` means "any args (or none)" —
  # covers both "git log" and "git log --oneline".
  defp pattern_to_regex(pattern) do
    # Normalize trailing ` *` to match "no args" as well as "any args".
    normalized =
      if String.ends_with?(pattern, " *") do
        String.replace_suffix(pattern, " *", "( .*)?")
      else
        pattern
        |> Regex.escape()
        |> String.replace("\\*", ".*")
        |> String.replace("\\?", ".")
      end

    final =
      case String.ends_with?(pattern, " *") do
        true ->
          prefix = String.replace_suffix(pattern, " *", "")
          Regex.escape(prefix) <> "( .*)?"

        false ->
          normalized
      end

    Regex.compile!("^" <> final <> "$")
  end
end
