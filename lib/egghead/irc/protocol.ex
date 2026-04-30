defmodule Egghead.IRC.Protocol do
  @moduledoc """
  IRC wire protocol parser and encoder (RFC 1459 / 2812 + IRCv3 message tags).

  Pure functions — no I/O, no state. The connection layer feeds raw bytes
  to `chunk/2` (which buffers across reads, splits on CRLF, and parses each
  complete line into a `%Message{}`); it formats outbound `%Message{}`s with
  `encode/1`.

  ## Wire grammar

      [@tag[=value][;tag[=value]]... ] [:prefix ] command [ params... ] [ :trailing ] CRLF

  - **tags** — IRCv3 message tags. `key=value` pairs separated by `;`. Stored
    on the message as a `%{key => value}` map (we don't escape values yet —
    the only producer is us, and we only emit ASCII tag values for now).
  - **prefix** — `nick[!user][@host]` for client→server is rare; server→client
    almost always present. Stored verbatim as a string.
  - **command** — alphabetic verb (`PRIVMSG`, `JOIN`) or 3-digit numeric (`001`).
    Upcased on parse so handlers can match on canonical form.
  - **params** — up to 14 space-delimited tokens, then a trailing param
    introduced by ` :` that may contain spaces. We don't enforce the 14-arg
    cap on parse (clients sometimes violate it harmlessly).

  Lines are CRLF-terminated, max 512 bytes including CRLF (RFC 2812 §2.3).
  IRCv3 tags add up to 8191 bytes of tag prefix beyond that. We don't enforce
  the cap on input — modern clients can exceed it — and `encode/1` doesn't
  truncate either; the caller decides.
  """

  defmodule Message do
    @moduledoc """
    Parsed IRC message.

    - `tags` — IRCv3 tag map (`%{}` if none).
    - `prefix` — source string (`"nick!user@host"` or server name) or `nil`.
    - `command` — uppercased verb (`"PRIVMSG"`) or 3-digit numeric (`"001"`).
    - `params` — middle params only (space-delimited tokens, no spaces inside).
    - `trailing` — the trailing param (introduced on the wire by ` :`), or
      `nil` if absent. May contain spaces. The encoder always emits `:`
      before this even when it's a single token, which is the convention
      every common IRC server follows for descriptive last params.

    On parse, if a line ends with a `:`-introduced trailing param, it lands
    here — not in `params`. So `params ++ [trailing]` reconstructs the
    full argument list when callers don't care about the wire distinction.
    """

    @type t :: %__MODULE__{
            tags: %{String.t() => String.t() | true},
            prefix: String.t() | nil,
            command: String.t(),
            params: [String.t()],
            trailing: String.t() | nil
          }

    defstruct tags: %{}, prefix: nil, command: "", params: [], trailing: nil

    @doc """
    All arguments (middle + trailing) as a flat list. Convenience for
    handlers that don't care which slot the trailing param landed in.
    """
    def args(%__MODULE__{params: p, trailing: nil}), do: p
    def args(%__MODULE__{params: p, trailing: t}), do: p ++ [t]
  end

  @crlf "\r\n"

  @doc """
  Feed a chunk of bytes from the socket. Returns
  `{messages, leftover_buffer}` — `messages` are complete lines parsed
  into `%Message{}` (in order received), `leftover_buffer` is any partial
  trailing line that should be prepended to the next chunk.

      iex> {msgs, rest} = Egghead.IRC.Protocol.chunk("", "NICK foo\\r\\nUSER bar 0 * :Bar\\r\\n")
      iex> Enum.map(msgs, & &1.command)
      ["NICK", "USER"]
      iex> rest
      ""

      iex> {msgs, rest} = Egghead.IRC.Protocol.chunk("", "NICK foo\\r\\nPART")
      iex> length(msgs)
      1
      iex> rest
      "PART"
  """
  @spec chunk(binary(), binary()) :: {[Message.t()], binary()}
  def chunk(buffer, bytes) when is_binary(buffer) and is_binary(bytes) do
    combined = buffer <> bytes
    do_split(combined, [])
  end

  defp do_split(buffer, acc) do
    case :binary.split(buffer, @crlf) do
      [^buffer] ->
        # No CRLF found — buffer holds an incomplete line.
        {Enum.reverse(acc), buffer}

      ["", rest] ->
        # Empty line (just CRLF) — skip.
        do_split(rest, acc)

      [line, rest] ->
        case parse(line) do
          {:ok, msg} -> do_split(rest, [msg | acc])
          # Drop unparseable lines silently for now. Worth a Logger.debug
          # once we have a feel for what real clients send that we miss.
          {:error, _} -> do_split(rest, acc)
        end
    end
  end

  @doc """
  Parse one CRLF-stripped line into a `%Message{}`.

      iex> {:ok, m} = Egghead.IRC.Protocol.parse("PRIVMSG #room :hello world")
      iex> {m.command, m.params, m.trailing}
      {"PRIVMSG", ["#room"], "hello world"}

      iex> {:ok, m} = Egghead.IRC.Protocol.parse(":nick!u@h JOIN #room")
      iex> {m.prefix, m.command, m.params}
      {"nick!u@h", "JOIN", ["#room"]}

      iex> {:ok, m} = Egghead.IRC.Protocol.parse("@time=2026 PING :server")
      iex> {Map.get(m.tags, "time"), m.command, m.trailing}
      {"2026", "PING", "server"}
  """
  @spec parse(binary()) :: {:ok, Message.t()} | {:error, :empty | :no_command}
  def parse(line) when is_binary(line) do
    line = String.trim_trailing(line, "\r")

    case line do
      "" -> {:error, :empty}
      _ -> parse_tags(line, %Message{})
    end
  end

  defp parse_tags("@" <> rest, msg) do
    case :binary.split(rest, " ") do
      [tag_str, after_tags] ->
        parse_prefix(after_tags, %{msg | tags: parse_tag_string(tag_str)})

      [_only_tags] ->
        {:error, :no_command}
    end
  end

  defp parse_tags(line, msg), do: parse_prefix(line, msg)

  defp parse_tag_string(str) do
    str
    |> String.split(";", trim: true)
    |> Enum.reduce(%{}, fn pair, acc ->
      case :binary.split(pair, "=") do
        [k, v] -> Map.put(acc, k, v)
        [k] -> Map.put(acc, k, true)
      end
    end)
  end

  defp parse_prefix(":" <> rest, msg) do
    case :binary.split(rest, " ") do
      [prefix, after_prefix] -> parse_command(after_prefix, %{msg | prefix: prefix})
      [_only_prefix] -> {:error, :no_command}
    end
  end

  defp parse_prefix(line, msg), do: parse_command(line, msg)

  defp parse_command(line, msg) do
    case :binary.split(String.trim_leading(line, " "), " ") do
      [cmd] when cmd != "" ->
        {:ok, %{msg | command: String.upcase(cmd)}}

      [cmd, params] when cmd != "" ->
        {middle, trailing} = parse_params(params)
        {:ok, %{msg | command: String.upcase(cmd), params: middle, trailing: trailing}}

      _ ->
        {:error, :no_command}
    end
  end

  # Walks the parameter portion. Tokens are space-separated until we
  # hit a token that begins with `:`, which marks the trailing param —
  # everything from there to end-of-line is one parameter (spaces and all).
  defp parse_params(str) do
    do_parse_params(str, [])
  end

  defp do_parse_params("", acc), do: {Enum.reverse(acc), nil}

  defp do_parse_params(":" <> trailing, acc), do: {Enum.reverse(acc), trailing}

  defp do_parse_params(str, acc) do
    case :binary.split(str, " ") do
      [token] -> {Enum.reverse([token | acc]), nil}
      [token, rest] -> do_parse_params(String.trim_leading(rest, " "), [token | acc])
    end
  end

  @doc """
  Encode a `%Message{}` (or a keyword list of fields) into a CRLF-terminated
  wire line.

  Pass `trailing:` for the `:`-prefixed last parameter (always emitted with
  the leading `:`). `params:` is for middle params (no spaces, no leading `:`).

      iex> Egghead.IRC.Protocol.encode(prefix: "irc.local", command: "001", params: ["nick"], trailing: "Welcome")
      ":irc.local 001 nick :Welcome\\r\\n"

      iex> Egghead.IRC.Protocol.encode(command: "PING", trailing: "server.local")
      "PING :server.local\\r\\n"

      iex> Egghead.IRC.Protocol.encode(command: "JOIN", params: ["#room"])
      "JOIN #room\\r\\n"
  """
  @spec encode(Message.t() | keyword()) :: binary()
  def encode(%Message{} = m) do
    encode(
      prefix: m.prefix,
      command: m.command,
      params: m.params,
      trailing: m.trailing,
      tags: m.tags
    )
  end

  def encode(fields) when is_list(fields) do
    tags = Keyword.get(fields, :tags, %{})
    prefix = Keyword.get(fields, :prefix)
    command = Keyword.fetch!(fields, :command)
    params = Keyword.get(fields, :params, [])
    trailing = Keyword.get(fields, :trailing)

    [
      encode_tags(tags),
      encode_prefix(prefix),
      command,
      encode_params(params),
      encode_trailing(trailing),
      @crlf
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_tags(map) when map_size(map) == 0, do: ""

  defp encode_tags(map) do
    pairs =
      map
      |> Enum.map_join(";", fn
        {k, true} -> k
        {k, v} -> "#{k}=#{v}"
      end)

    ["@", pairs, " "]
  end

  defp encode_prefix(nil), do: ""
  defp encode_prefix(p), do: [":", p, " "]

  defp encode_params([]), do: ""
  defp encode_params(params), do: Enum.map(params, &[" ", &1])

  defp encode_trailing(nil), do: ""
  defp encode_trailing(t), do: [" :", t]
end
