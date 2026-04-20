defmodule Egghead.LLM.Google do
  @moduledoc """
  Google Gemini provider.

  Normalizes blocking and streaming responses to the Anthropic-shaped
  content blocks the Agent loop expects — so Gemini agents are
  transparent to the rest of the system.
  """

  @behaviour Egghead.LLM.Provider

  require Logger

  @api_url "https://generativelanguage.googleapis.com/v1beta"
  @default_model "gemini-2.0-flash"
  @default_max_tokens 4096

  # Stop buffering if a 4xx/5xx body is gigantic — enough to diagnose,
  # bounded enough to survive a pathological response.
  @max_error_body 100_000

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      do_blocking(messages, opts, api_key)
    end
  end

  @impl true
  def chat_stream(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key)

    cond do
      is_nil(api_key) ->
        {:error, :missing_api_key}

      is_nil(Keyword.get(opts, :on_chunk)) ->
        do_blocking(messages, opts, api_key)

      true ->
        do_stream(messages, opts, api_key)
    end
  end

  @impl true
  def get_model_info(model_id, opts \\ []) do
    api_key = Keyword.get(opts, :api_key)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      url = "#{@api_url}/models/#{model_id}?key=#{api_key}"

      case Req.get(url, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} ->
          {:ok,
           %{
             "id" => body["name"],
             "max_input_tokens" => body["inputTokenLimit"],
             "max_tokens" => body["outputTokenLimit"]
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
    api_key = Keyword.get(opts, :api_key)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      url = "#{@api_url}/models?key=#{api_key}"

      case Req.get(url, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: %{"models" => models}}} ->
          parsed =
            models
            |> Enum.filter(&gemini_chat_model?/1)
            |> Enum.map(fn m ->
              id = String.replace(m["name"] || "", "models/", "")

              %{
                id: id,
                context_window: m["inputTokenLimit"],
                max_tokens: m["outputTokenLimit"]
              }
            end)
            |> Enum.sort_by(& &1.id)

          {:ok, parsed}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_error, reason}}
      end
    end
  end

  @model_excludes ~w(
    embedding aqa imagen image-generation tts native-audio-dialog
  )

  @doc false
  def gemini_chat_model?(%{"name" => name}) when is_binary(name) do
    id = String.replace(name, "models/", "")

    cond do
      Enum.any?(@model_excludes, &String.contains?(id, &1)) -> false
      String.starts_with?(id, "gemini") -> true
      true -> false
    end
  end

  def gemini_chat_model?(_), do: false

  # --- Request construction ---

  @doc false
  def build_body(messages, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools)

    %{
      contents: format_messages(messages),
      generationConfig: %{
        maxOutputTokens: max_tokens
      }
    }
    |> maybe_put_system(system)
    |> maybe_put_temperature(temperature)
    |> maybe_put_tools(tools)
  end

  defp do_blocking(messages, opts, api_key) do
    model = Keyword.get(opts, :model, @default_model)
    body = build_body(messages, opts)

    url = "#{@api_url}/models/#{model}:generateContent?key=#{api_key}"

    case Req.post(url,
           json: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 300_000,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: resp}} ->
        parse_response(resp)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Gemini API #{status}: #{inspect(body, limit: 10, printable_limit: 400)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        normalize_transport_error("Gemini", reason)
    end
  end

  # --- Streaming ---

  defp do_stream(messages, opts, api_key) do
    model = Keyword.get(opts, :model, @default_model)
    on_chunk = Keyword.get(opts, :on_chunk, fn _ -> :ok end)
    body = build_body(messages, opts)

    url = "#{@api_url}/models/#{model}:streamGenerateContent?alt=sse&key=#{api_key}"

    init_acc = %{
      text: "",
      tool_calls: [],
      finish_reason: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      on_chunk: on_chunk,
      # TCP chunks arrive at arbitrary boundaries — a single SSE event
      # may span multiple Req callbacks. Buffer any trailing incomplete
      # line so the next callback can finish it.
      buffer: ""
    }

    # Branch on status inside the callback so non-200 JSON error bodies
    # don't get fed to the SSE parser — same trap Anthropic warns about.
    case Req.post(url,
           json: body,
           headers: [{"content-type", "application/json"}],
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
        content = finalize_stream_content(final)

        {:ok,
         %{
           content: content,
           stop_reason: final.finish_reason || infer_stop_reason(content),
           usage: [
             input_tokens: final.usage.input_tokens,
             output_tokens: final.usage.output_tokens
           ]
         }}

      {:ok, %{status: status} = resp} ->
        raw = resp.private[:error_body] || ""
        body = decode_error_body(raw)
        Logger.warning("Gemini API #{status}: #{inspect(body, limit: 10, printable_limit: 400)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        normalize_transport_error("Gemini", reason)
    end
  end

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

  @doc false
  def process_sse(data, acc) do
    combined = (acc[:buffer] || "") <> data
    {complete_lines, remainder} = split_sse_buffer(combined)

    acc = Map.put(acc, :buffer, remainder)

    Enum.reduce(complete_lines, acc, fn line, acc ->
      case String.trim_leading(line, "data: ") do
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

  defp split_sse_buffer(data) do
    parts = String.split(data, "\n")
    {remainder, complete} = List.pop_at(parts, -1)
    {complete, remainder || ""}
  end

  defp apply_stream_event(event, acc) do
    acc = merge_usage(event, acc)

    candidate = List.first(event["candidates"] || []) || %{}
    parts = get_in(candidate, ["content", "parts"]) || []

    acc =
      Enum.reduce(parts, acc, fn
        %{"text" => text}, acc when is_binary(text) and text != "" ->
          acc.on_chunk.({:text, text})
          %{acc | text: acc.text <> text}

        %{"functionCall" => %{"name" => name, "args" => args}}, acc ->
          tc = %{
            "type" => "tool_use",
            "id" => "call_#{:erlang.unique_integer([:positive])}",
            "name" => name,
            "input" => args || %{}
          }

          %{acc | tool_calls: acc.tool_calls ++ [tc]}

        _, acc ->
          acc
      end)

    case candidate["finishReason"] do
      nil -> acc
      reason -> %{acc | finish_reason: map_finish_reason(reason)}
    end
  end

  defp merge_usage(%{"usageMetadata" => usage}, acc) do
    inp = usage["promptTokenCount"] || acc.usage.input_tokens
    out = usage["candidatesTokenCount"] || acc.usage.output_tokens
    %{acc | usage: %{input_tokens: inp, output_tokens: out}}
  end

  defp merge_usage(_, acc), do: acc

  @doc false
  def finalize_stream_content(acc) do
    text_block =
      case acc.text do
        "" -> []
        t -> [%{"type" => "text", "text" => t}]
      end

    text_block ++ acc.tool_calls
  end

  defp infer_stop_reason(content) do
    if Enum.any?(content, &(&1["type"] == "tool_use")),
      do: "tool_use",
      else: "end_turn"
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

  # --- Response parsing (Gemini → Anthropic-compatible format) ---

  defp parse_response(resp) do
    candidates = resp["candidates"] || []
    candidate = List.first(candidates) || %{}
    content = candidate["content"] || %{}
    parts = content["parts"] || []

    blocks =
      Enum.flat_map(parts, fn
        %{"text" => text} ->
          [%{"type" => "text", "text" => text}]

        %{"functionCall" => %{"name" => name, "args" => args}} ->
          [
            %{
              "type" => "tool_use",
              "id" => "call_#{:erlang.unique_integer([:positive])}",
              "name" => name,
              "input" => args || %{}
            }
          ]

        _ ->
          []
      end)

    stop_reason = map_finish_reason(candidate["finishReason"]) || infer_stop_reason(blocks)

    usage =
      case resp["usageMetadata"] do
        %{"promptTokenCount" => inp, "candidatesTokenCount" => out} ->
          [input_tokens: inp, output_tokens: out]

        _ ->
          []
      end

    {:ok, %{content: blocks, stop_reason: stop_reason, usage: usage}}
  end

  defp map_finish_reason("STOP"), do: "end_turn"
  defp map_finish_reason("MAX_TOKENS"), do: "max_tokens"
  defp map_finish_reason("TOOL_USE"), do: "tool_use"
  defp map_finish_reason(nil), do: nil
  defp map_finish_reason(other), do: other

  # --- Message formatting (to Gemini format) ---

  defp format_messages(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: "user", content: content} when is_list(content) ->
        parts =
          Enum.map(content, fn
            %{type: "tool_result", tool_use_id: _id, content: text} ->
              %{
                "functionResponse" => %{
                  "name" => "tool",
                  "response" => %{"result" => to_string(text)}
                }
              }

            %{"type" => "tool_result", "content" => text} ->
              %{
                "functionResponse" => %{
                  "name" => "tool",
                  "response" => %{"result" => to_string(text)}
                }
              }

            other ->
              %{"text" => inspect(other)}
          end)

        [%{role: "user", parts: parts}]

      %{role: "assistant", content: content} when is_list(content) ->
        parts =
          Enum.map(content, fn
            %{"type" => "text", "text" => text} ->
              %{"text" => text}

            %{"type" => "tool_use", "name" => name, "input" => args} ->
              %{"functionCall" => %{"name" => name, "args" => args}}

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        [%{role: "model", parts: parts}]

      %{role: role, content: content} when is_binary(content) ->
        gemini_role = if role in ["assistant", "model"], do: "model", else: "user"
        [%{role: gemini_role, parts: [%{"text" => content}]}]

      %{"role" => role, "content" => content} when is_binary(content) ->
        gemini_role = if role in ["assistant", "model"], do: "model", else: "user"
        [%{role: gemini_role, parts: [%{"text" => content}]}]

      _ ->
        []
    end)
  end

  # --- Helpers ---

  defp maybe_put_system(body, nil), do: body

  defp maybe_put_system(body, system) do
    Map.put(body, :systemInstruction, %{parts: [%{text: system}]})
  end

  defp maybe_put_temperature(body, nil), do: body

  defp maybe_put_temperature(body, temp) do
    update_in(body, [:generationConfig], &Map.put(&1, :temperature, temp))
  end

  defp maybe_put_tools(body, nil), do: body

  defp maybe_put_tools(body, tools) do
    declarations =
      Enum.map(tools, fn tool ->
        %{
          name: tool.name || tool[:name],
          description: tool.description || tool[:description],
          parameters: convert_schema(tool.input_schema || tool[:input_schema])
        }
      end)

    Map.put(body, :tools, [%{functionDeclarations: declarations}])
  end

  defp convert_schema(schema) when is_map(schema), do: schema
  defp convert_schema(_), do: %{type: "object", properties: %{}}
end
