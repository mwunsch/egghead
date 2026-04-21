defmodule Egghead.LLM.OpenAI do
  @moduledoc """
  OpenAI Chat Completions provider.

  Also serves as the universal adapter for any OpenAI-compatible endpoint
  (Ollama, LMStudio, Groq, OpenRouter, vLLM, etc.) via configurable `base_url`.

  ## GPT-5 / reasoning-model quirks

  Reasoning models (`o1*`, `o3*`, `o4*`, `o5*`) and the entire GPT-5 family
  reject the legacy `max_tokens` parameter with HTTP 400 `unsupported_parameter`
  and require `max_completion_tokens` instead. They also reject any
  `temperature` other than the default of `1`. We detect these models by
  prefix and adjust the request shape accordingly — but only when the
  endpoint is api.openai.com (OpenAI-compatible servers like Ollama still
  expect legacy `max_tokens`).

  ## Context windows

  OpenAI's `/v1/models` response contains only `{id, created, object,
  owned_by}` — no token limits. Same for xAI, DeepSeek, Mistral over
  their OpenAI-compat endpoints. `Egghead.LLM.ModelMeta.lookup/1` holds
  the cross-provider prefix table and is consulted here whenever the
  endpoint response is missing the fields.
  """

  @behaviour Egghead.LLM.Provider

  require Logger

  @default_url "https://api.openai.com/v1"
  @default_model "gpt-4o"
  @default_max_tokens 4096

  # Stop buffering if a 4xx/5xx body is gigantic — enough to diagnose,
  # bounded enough to survive a pathological response.
  @max_error_body 100_000

  @impl true
  def chat(messages, opts \\ []) do
    do_blocking(messages, opts)
  end

  @impl true
  def chat_stream(messages, opts \\ []) do
    case Keyword.get(opts, :on_chunk) do
      nil -> do_blocking(messages, opts)
      _cb -> do_stream(messages, opts)
    end
  end

  @impl true
  def get_model_info(model_id, opts \\ []) do
    base_url = base_url(opts)

    if openai_official?(base_url) do
      {ctx, max_out} = Egghead.LLM.ModelMeta.lookup(model_id)

      {:ok,
       %{
         "id" => model_id,
         "max_input_tokens" => ctx,
         "max_tokens" => max_out
       }}
    else
      api_key = Keyword.get(opts, :api_key)

      case Req.get("#{base_url}/models/#{model_id}", headers: auth_headers(api_key)) do
        {:ok, %{status: 200, body: body}} ->
          {:ok,
           %{
             "id" => body["id"] || model_id,
             "max_input_tokens" =>
               body["context_window"] || body["max_input_tokens"] ||
                 body["context_length"],
             "max_tokens" => body["max_output_tokens"] || body["max_tokens"]
           }}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_error, reason}}
      end
    end
  end

  @impl true
  def list_models(opts \\ []) do
    base_url = base_url(opts)
    api_key = Keyword.get(opts, :api_key)

    case Req.get("#{base_url}/models", headers: auth_headers(api_key), receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        parsed =
          models
          |> maybe_filter_chat_models(base_url)
          |> Enum.map(&parse_model(&1, base_url))
          |> Enum.sort_by(& &1.id)

        {:ok, parsed}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  # --- Request construction ---

  @doc false
  def build_body(messages, opts) do
    base_url = base_url(opts)
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools)

    messages =
      if system do
        [%{role: "system", content: system} | format_messages(messages)]
      else
        format_messages(messages)
      end

    # Newer OpenAI-proper models require `max_completion_tokens` and
    # only accept the default `temperature` of 1. OpenAI-compat servers
    # (Ollama, LMStudio, etc.) generally don't know `max_completion_tokens`,
    # so we only apply the swap for api.openai.com.
    reasoning? = openai_official?(base_url) and reasoning_or_gpt5?(model)
    token_key = if reasoning?, do: :max_completion_tokens, else: :max_tokens
    temperature = if reasoning?, do: nil, else: temperature

    %{model: model, messages: messages}
    |> Map.put(token_key, max_tokens)
    |> maybe_put(:temperature, temperature)
    |> maybe_put_tools(tools)
  end

  defp do_blocking(messages, opts) do
    base_url = base_url(opts)
    api_key = Keyword.get(opts, :api_key)
    body = build_body(messages, opts)

    # `retry: :transient` makes Req retry POSTs on transient transport
    # errors (:closed, :timeout, econnrefused, 5xx). Safe here because
    # we're not emitting to on_chunk — no duplicate user output on retry.
    case Req.post("#{base_url}/chat/completions",
           json: body,
           headers: auth_headers(api_key),
           receive_timeout: 300_000,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: resp}} ->
        choice = List.first(resp["choices"] || []) || %{}
        message = choice["message"] || %{}

        content = openai_to_anthropic_content(message)
        stop_reason = map_finish_reason(choice["finish_reason"])
        usage = parse_usage(resp)

        {:ok, %{content: content, stop_reason: stop_reason, usage: usage}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("OpenAI API #{status}: #{inspect(body, limit: 10, printable_limit: 400)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        normalize_transport_error("OpenAI", reason)
    end
  end

  defp do_stream(messages, opts) do
    base_url = base_url(opts)
    api_key = Keyword.get(opts, :api_key)
    on_chunk = Keyword.get(opts, :on_chunk, fn _ -> :ok end)

    body =
      build_body(messages, opts)
      |> Map.put(:stream, true)
      |> Map.put(:stream_options, %{include_usage: true})

    init_acc = %{
      text: "",
      tool_calls: %{},
      finish_reason: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      on_chunk: on_chunk,
      # TCP chunks arrive at arbitrary boundaries — a single SSE event
      # may span multiple Req callbacks. Buffer whatever trailing
      # incomplete line we saw so the next callback can finish it.
      buffer: ""
    }

    # Mirror Anthropic's branch-on-status pattern: on non-200 responses
    # the body is a plain JSON error, not SSE — buffer it verbatim so
    # we can surface it for diagnostics instead of silently dropping it.
    case Req.post("#{base_url}/chat/completions",
           json: body,
           headers: auth_headers(api_key),
           receive_timeout: 300_000,
           into: fn {:data, data}, {req, resp} ->
             resp =
               if resp.status == 200 do
                 updated = process_sse(data, resp.private[:acc] || init_acc)
                 put_in(resp.private[:acc], updated)
               else
                 put_in(
                   resp.private[:error_body],
                   append_error_body(resp.private[:error_body], data)
                 )
               end

             {:cont, {req, resp}}
           end
         ) do
      {:ok, %{status: 200} = resp} ->
        final = resp.private[:acc] || init_acc
        content = finalize_content(final)
        stop_reason = map_finish_reason(final.finish_reason)

        {:ok,
         %{
           content: content,
           stop_reason: stop_reason,
           usage: [
             input_tokens: final.usage.input_tokens,
             output_tokens: final.usage.output_tokens
           ]
         }}

      {:ok, %{status: status} = resp} ->
        raw = resp.private[:error_body] || ""
        body = decode_error_body(raw)
        Logger.warning("OpenAI API #{status}: #{inspect(body, limit: 10, printable_limit: 400)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        normalize_transport_error("OpenAI", reason)
    end
  end

  # Turn Req's transport-error structs into a tagged tuple with a human
  # reason string so the chat surface shows "connection closed" rather
  # than a raw struct dump. Bump to Logger so repeated drops are visible.
  defp normalize_transport_error(provider, %Req.TransportError{reason: r} = err) do
    Logger.warning("#{provider} transport error: #{inspect(r)}")
    {:error, {:transport_error, transport_reason(r), err}}
  end

  defp normalize_transport_error(provider, reason) do
    Logger.warning("#{provider} request error: #{inspect(reason, limit: 5)}")
    {:error, {:request_error, reason}}
  end

  defp transport_reason(:closed), do: "connection closed by server (transient — retry)"
  defp transport_reason(:timeout), do: "request timed out"
  defp transport_reason(:econnrefused), do: "connection refused"
  defp transport_reason(:nxdomain), do: "DNS lookup failed"
  defp transport_reason(other), do: "transport error: #{inspect(other)}"

  # --- SSE parsing ---

  @doc false
  def process_sse(data, acc) do
    combined = (acc[:buffer] || "") <> data
    {complete_lines, remainder} = split_sse_buffer(combined)

    acc = Map.put(acc, :buffer, remainder)

    Enum.reduce(complete_lines, acc, fn line, acc ->
      case String.trim_leading(line, "data: ") do
        "[DONE]" ->
          acc

        "" ->
          acc

        json ->
          case Jason.decode(json) do
            {:ok, event} -> apply_stream_event(event, acc)
            {:error, _} -> acc
          end
      end
    end)
  end

  # Return {complete_lines, trailing_incomplete} so partial JSON lines
  # don't get fed to the parser (they'd fail to decode and vanish).
  defp split_sse_buffer(data) do
    parts = String.split(data, "\n")
    {remainder, complete} = List.pop_at(parts, -1)
    {complete, remainder || ""}
  end

  defp apply_stream_event(event, acc) do
    acc =
      case event["usage"] do
        %{"prompt_tokens" => inp, "completion_tokens" => out} ->
          %{acc | usage: %{input_tokens: inp, output_tokens: out}}

        _ ->
          acc
      end

    choice = List.first(event["choices"] || []) || %{}
    delta = choice["delta"] || %{}
    finish = choice["finish_reason"]

    acc =
      case delta["content"] do
        nil ->
          acc

        "" ->
          acc

        chunk when is_binary(chunk) ->
          acc.on_chunk.({:text, chunk})
          %{acc | text: acc.text <> chunk}
      end

    acc =
      case delta["tool_calls"] do
        nil -> acc
        list when is_list(list) -> Enum.reduce(list, acc, &merge_tool_call_delta/2)
      end

    if finish, do: %{acc | finish_reason: finish}, else: acc
  end

  defp merge_tool_call_delta(delta, acc) do
    idx = delta["index"] || 0
    current = Map.get(acc.tool_calls, idx, %{"id" => nil, "name" => nil, "args" => ""})

    current = maybe_put_string(current, "id", delta["id"])

    current =
      case delta["function"] do
        nil ->
          current

        fn_delta ->
          current
          |> maybe_put_string("name", fn_delta["name"])
          |> Map.update!("args", &(&1 <> (fn_delta["arguments"] || "")))
      end

    %{acc | tool_calls: Map.put(acc.tool_calls, idx, current)}
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, key, val), do: Map.put(map, key, val)

  @doc false
  def finalize_content(acc) do
    text_block =
      case acc.text do
        "" -> []
        t -> [%{"type" => "text", "text" => t}]
      end

    tool_blocks =
      acc.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, tc} ->
        %{
          "type" => "tool_use",
          "id" => tc["id"],
          "name" => tc["name"],
          "input" =>
            case Jason.decode(tc["args"] || "") do
              {:ok, parsed} when is_map(parsed) -> parsed
              _ -> %{}
            end
        }
      end)

    text_block ++ tool_blocks
  end

  defp append_error_body(nil, data), do: append_error_body("", data)

  defp append_error_body(buf, _data) when byte_size(buf) >= @max_error_body, do: buf

  defp append_error_body(buf, data) do
    remaining = @max_error_body - byte_size(buf)

    if byte_size(data) <= remaining do
      buf <> data
    else
      buf <> binary_part(data, 0, remaining)
    end
  end

  defp decode_error_body(""), do: ""

  defp decode_error_body(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _} -> raw
    end
  end

  # --- Model listing ---

  defp parse_model(m, _base_url) do
    id = m["id"]
    {meta_ctx, meta_max} = Egghead.LLM.ModelMeta.lookup(id)

    ctx =
      m["context_window"] || m["context_length"] || m["max_input_tokens"] || meta_ctx

    max_out =
      m["max_output_tokens"] || m["max_tokens"] || meta_max

    %{id: id, context_window: ctx, max_tokens: max_out}
  end

  defp maybe_filter_chat_models(models, base_url) do
    if openai_official?(base_url),
      do: Enum.filter(models, &chat_model?(&1["id"])),
      else: models
  end

  @model_excludes ~w(
    embedding whisper tts dall-e moderation realtime audio transcribe
    image-generation image-1 -search -instruct codex computer-use
  )

  @doc false
  def chat_model?(nil), do: false

  def chat_model?(id) when is_binary(id) do
    cond do
      Enum.any?(@model_excludes, &String.contains?(id, &1)) -> false
      String.starts_with?(id, "gpt-") -> true
      String.starts_with?(id, "chatgpt-") -> true
      String.starts_with?(id, "o1") -> true
      String.starts_with?(id, "o3") -> true
      String.starts_with?(id, "o4") -> true
      String.starts_with?(id, "o5") -> true
      true -> false
    end
  end

  # --- Format conversion (OpenAI response → Anthropic-compatible) ---
  # The Agent loop expects content blocks in Anthropic's shape regardless
  # of which provider returned them.

  defp openai_to_anthropic_content(message) do
    blocks = []

    blocks =
      case message["content"] do
        nil -> blocks
        "" -> blocks
        text -> blocks ++ [%{"type" => "text", "text" => text}]
      end

    case message["tool_calls"] do
      nil ->
        blocks

      tool_calls ->
        tool_blocks =
          Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "id" => tc["id"],
              "name" => tc["function"]["name"],
              "input" => parse_tool_args(tc["function"]["arguments"])
            }
          end)

        blocks ++ tool_blocks
    end
  end

  # Best-effort stringification of mixed list content from a
  # rehydrated or malformed history entry. Preserves any
  # recognizable text; otherwise falls back to inspect so we
  # never forward a list whose shape we can't guarantee.
  defp flatten_list_content(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      %{type: "text", text: t} when is_binary(t) -> t
      %{"type" => "tool_result", "content" => t} when is_binary(t) -> t
      %{type: :tool_result, content: t} when is_binary(t) -> t
      %{type: "tool_result", content: t} when is_binary(t) -> t
      t when is_binary(t) -> t
      other -> inspect(other)
    end)
  end

  defp flatten_list_content(other), do: to_string(other)

  defp parse_tool_args(nil), do: %{}

  defp parse_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_tool_args(args) when is_map(args), do: args

  defp map_finish_reason("stop"), do: "end_turn"
  defp map_finish_reason("tool_calls"), do: "tool_use"
  defp map_finish_reason("length"), do: "max_tokens"
  defp map_finish_reason(other), do: other

  # --- Tool format conversion (Anthropic format → OpenAI format) ---

  defp maybe_put_tools(body, nil), do: body

  defp maybe_put_tools(body, tools) do
    openai_tools =
      Enum.map(tools, fn tool ->
        %{
          type: "function",
          function: %{
            name: tool.name || tool[:name],
            description: tool.description || tool[:description],
            parameters: tool.input_schema || tool[:input_schema]
          }
        }
      end)

    Map.put(body, :tools, openai_tools)
  end

  # --- Message formatting ---

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: "user", content: content} when is_list(content) ->
        tool_results =
          Enum.map(content, fn
            %{type: "tool_result", tool_use_id: id, content: text} ->
              %{role: "tool", tool_call_id: id, content: to_string(text)}

            %{"type" => "tool_result", "tool_use_id" => id, "content" => text} ->
              %{role: "tool", tool_call_id: id, content: to_string(text)}

            other ->
              other
          end)

        if Enum.all?(tool_results, &is_map(&1)) and
             Enum.all?(tool_results, &Map.has_key?(&1, :tool_call_id)) do
          tool_results
        else
          # Mixed / unrecognized list content — flatten to a string
          # so OpenAI never sees a rogue list it can't parse. Pick
          # the text payload out of whatever we recognize; worst
          # case, inspect the whole thing so the API gets some
          # kind of string instead of null/malformed content.
          [%{role: "user", content: flatten_list_content(content)}]
        end

      %{role: "assistant", content: content} when is_list(content) ->
        text =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", & &1["text"])

        tool_calls =
          content
          |> Enum.filter(&(&1["type"] == "tool_use"))
          |> Enum.map(fn tc ->
            %{
              id: tc["id"],
              type: "function",
              function: %{
                name: tc["name"],
                arguments: Jason.encode!(tc["input"] || %{})
              }
            }
          end)

        msg = %{role: "assistant"}
        msg = if tool_calls != [], do: Map.put(msg, :tool_calls, tool_calls), else: msg

        # OpenAI requires `content` to be a string; `null` is
        # legal only on assistant messages that carry
        # `tool_calls`. If the assistant turn filters down to
        # neither text nor tool_use (thinking blocks, unknown
        # types, nil-content rehydration), fall back to "" so
        # the request doesn't 400 with "expected a string, got
        # null".
        content_field =
          cond do
            text != "" -> text
            tool_calls != [] -> nil
            true -> ""
          end

        msg = Map.put(msg, :content, content_field)
        [msg]

      %{role: role, content: content} ->
        [%{role: role, content: content || ""}]

      %{"role" => role, "content" => content} ->
        [%{role: role, content: content || ""}]
    end)
    |> List.flatten()
  end

  # --- Helpers ---

  defp base_url(opts), do: Keyword.get(opts, :base_url) || @default_url

  defp openai_official?(nil), do: true

  defp openai_official?(url) when is_binary(url) do
    String.starts_with?(url, "https://api.openai.com")
  end

  defp reasoning_or_gpt5?(model) when is_binary(model) do
    String.starts_with?(model, "o1") or
      String.starts_with?(model, "o3") or
      String.starts_with?(model, "o4") or
      String.starts_with?(model, "o5") or
      String.starts_with?(model, "gpt-5")
  end

  defp reasoning_or_gpt5?(_), do: false

  defp auth_headers(nil), do: [{"content-type", "application/json"}]

  defp auth_headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  defp parse_usage(%{"usage" => %{"prompt_tokens" => inp, "completion_tokens" => out}}) do
    [input_tokens: inp, output_tokens: out]
  end

  defp parse_usage(_), do: []

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
