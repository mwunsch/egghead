defmodule Egghead.IRC.NickMap do
  @moduledoc """
  Translation between Egghead identifiers (`agents/scout`, `users/mark`)
  and IRC nicknames (`scout`, `mark`).

  IRC nicks are constrained to a narrower character set than our record
  ids — no slashes, no leading digits, ASCII-ish — so the slash-namespaced
  ids we use everywhere else have to be projected onto a flat namespace
  before they hit the wire. Pure functions; collision policy lives here
  rather than in the connection handler so it stays testable.

  ## Validity

  RFC 2812 §2.3.1 nickname grammar (slightly relaxed in modern practice):

      letter = A-Z | a-z
      digit  = 0-9
      special = '-' | '[' | ']' | '\\' | '`' | '_' | '^' | '{' | '|' | '}'
      nickname = ( letter | special ) *( letter | digit | special )

  We accept that grammar and additionally treat `.` as invalid (some
  servers allow it; we don't, because it muddles host/nick parsing in
  prefixes).
  """

  @max_nick_length 30

  @doc """
  Project an Egghead id onto its IRC nick form.

  Strips a single leading namespace segment (`agents/scout` → `scout`,
  `users/mark` → `mark`), replaces invalid characters with `_`, and
  truncates to `@max_nick_length`.

      iex> Egghead.IRC.NickMap.id_to_nick("agents/scout")
      "scout"

      iex> Egghead.IRC.NickMap.id_to_nick("users/mark")
      "mark"

      iex> Egghead.IRC.NickMap.id_to_nick("agents/the.judge")
      "the_judge"
  """
  @spec id_to_nick(String.t()) :: String.t()
  def id_to_nick(id) when is_binary(id) do
    id
    |> String.split("/")
    |> List.last()
    |> sanitize()
    |> String.slice(0, @max_nick_length)
  end

  defp sanitize(""), do: "_"

  defp sanitize(name) do
    name
    |> String.graphemes()
    |> Enum.map(fn ch ->
      if valid_char?(ch), do: ch, else: "_"
    end)
    |> Enum.join()
    |> ensure_valid_first_char()
  end

  defp ensure_valid_first_char(<<first::utf8, _rest::binary>> = name) do
    if valid_first_char?(<<first::utf8>>), do: name, else: "_" <> name
  end

  defp ensure_valid_first_char(""), do: "_"

  defp valid_first_char?(<<ch::utf8>>) when ch in ?A..?Z or ch in ?a..?z, do: true
  defp valid_first_char?(<<ch::utf8>>) when ch in [?[, ?], ?\\, ?`, ?_, ?^, ?{, ?|, ?}], do: true
  defp valid_first_char?(_), do: false

  defp valid_char?(<<ch::utf8>>) when ch in ?A..?Z or ch in ?a..?z, do: true
  defp valid_char?(<<ch::utf8>>) when ch in ?0..?9, do: true
  defp valid_char?(<<ch::utf8>>) when ch in [?-, ?[, ?], ?\\, ?`, ?_, ?^, ?{, ?|, ?}], do: true
  defp valid_char?(_), do: false

  @doc """
  Whether a string is a valid IRC nickname per the relaxed grammar above.

      iex> Egghead.IRC.NickMap.valid_nick?("scout")
      true

      iex> Egghead.IRC.NickMap.valid_nick?("3llen")
      false

      iex> Egghead.IRC.NickMap.valid_nick?("a.b")
      false

      iex> Egghead.IRC.NickMap.valid_nick?("")
      false
  """
  @spec valid_nick?(String.t()) :: boolean()
  def valid_nick?(name) when is_binary(name) do
    case String.length(name) do
      0 -> false
      n when n > @max_nick_length -> false
      _ -> all_chars_valid?(name)
    end
  end

  def valid_nick?(_), do: false

  defp all_chars_valid?(<<first::utf8, rest::binary>>) do
    valid_first_char?(<<first::utf8>>) and
      Enum.all?(String.graphemes(rest), &valid_char?/1)
  end

  @doc """
  Project a room id onto an IRC channel name (prefixes `#`).

      iex> Egghead.IRC.NickMap.room_to_channel("general")
      "#general"
  """
  @spec room_to_channel(String.t()) :: String.t()
  def room_to_channel(room_id), do: "#" <> room_id

  @doc """
  Strip the `#` (or `&`/`+`/`!`) prefix from a channel name to recover
  the room id. Returns `nil` if the input doesn't look like a channel.

      iex> Egghead.IRC.NickMap.channel_to_room("#general")
      "general"

      iex> Egghead.IRC.NickMap.channel_to_room("general")
      nil
  """
  @spec channel_to_room(String.t()) :: String.t() | nil
  def channel_to_room("#" <> rest), do: rest
  def channel_to_room("&" <> rest), do: rest
  def channel_to_room("+" <> rest), do: rest
  def channel_to_room("!" <> rest), do: rest
  def channel_to_room(_), do: nil
end
