defmodule Egghead.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude provider.

  Supports both standard and streaming responses via the Messages API.
  Requires the `ANTHROPIC_API_KEY` environment variable.
  """

  @behaviour Egghead.LLM.Provider

  require Logger

  @api_url "https://api.anthropic.com/v1/messages"
  @models_url "https://api.anthropic.com/v1/models"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 4096

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      do_chat(messages, opts, api_key)
    end
  end

  @doc """
  Streaming chat. Calls `on_chunk` with each text delta as it arrives.
  Returns the same `{:ok, response}` as `chat/2` when complete.
  """
  @impl true
  @spec chat_stream(list(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat_stream(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      do_chat_stream(messages, opts, api_key)
    end
  end

  @doc """
  Fetches model metadata from the Anthropic Models API.
  """
  @impl true
  @spec get_model_info(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_model_info(model_id, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      case Req.get("#{@models_url}/#{model_id}",
             headers: headers(api_key),
             receive_timeout: 10_000
           ) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
        {:error, reason} -> {:error, {:request_error, reason}}
      end
    end
  end

  @doc """
  Lists available models from the Anthropic Models API.
  """
  @impl true
  @spec list_models(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_models(opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      case Req.get("#{@models_url}?limit=100",
             headers: headers(api_key),
             receive_timeout: 10_000
           ) do
        {:ok, %{status: 200, body: %{"data" => models}}} ->
          parsed =
            models
            |> Enum.map(fn m ->
              %{
                id: m["id"],
                context_window: m["max_input_tokens"],
                max_tokens: m["max_tokens"]
              }
            end)

          {:ok, parsed}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_error, reason}}
      end
    end
  end

  # --- Standard (non-streaming) ---

  defp do_chat(messages, opts, api_key) do
    body = build_body(messages, opts)

    case Req.post(@api_url,
           json: body,
           headers: headers(api_key, "application/json"),
           receive_timeout: 300_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok,
         %{
           content: resp_body["content"] || [],
           stop_reason: resp_body["stop_reason"],
           usage: parse_usage(resp_body)
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  # --- Streaming ---

  defp do_chat_stream(messages, opts, api_key) do
    on_chunk = Keyword.get(opts, :on_chunk, fn _ -> :ok end)
    body = build_body(messages, opts) |> Map.put(:stream, true)

    # Use Req with into: for streaming
    acc = %{
      content: [],
      current_block: nil,
      stop_reason: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      on_chunk: on_chunk
    }

    # `into:` runs for every chunk regardless of status code. For 200s
    # we parse SSE; for non-200s (4xx / 5xx) Anthropic sends a plain
    # JSON error body, not SSE — if we fed it to the SSE parser we'd
    # silently drop it, and the outer case would see an empty body.
    # Branch on status inside the callback so the error body survives
    # for diagnostic reporting (matches OpenAI/Google behaviour).
    case Req.post(@api_url,
           json: body,
           headers: headers(api_key, "application/json"),
           receive_timeout: 300_000,
           into: fn {:data, data}, {req, resp} ->
             resp =
               if resp.status == 200 do
                 acc = process_sse_chunk(data, resp.private[:acc] || acc)
                 put_in(resp.private[:acc], acc)
               else
                 prev = resp.private[:error_body] || ""
                 put_in(resp.private[:error_body], prev <> data)
               end

             {:cont, {req, resp}}
           end
         ) do
      {:ok, %{status: 200} = resp} ->
        final_acc = resp.private[:acc] || acc

        {:ok,
         %{
           content: Enum.reverse(final_acc.content),
           stop_reason: final_acc.stop_reason,
           usage: [
             input_tokens: final_acc.usage.input_tokens,
             output_tokens: final_acc.usage.output_tokens
           ]
         }}

      {:ok, %{status: status} = resp} ->
        raw = resp.private[:error_body] || ""
        body = decode_error_body(raw)

        Logger.warning(
          "Anthropic API #{status}: #{inspect(body, limit: 10, printable_limit: 400)}"
        )

        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  # Try to decode as JSON to match what non-streaming responses look
  # like (Req auto-decodes JSON bodies). If it isn't JSON, return the
  # raw string — still more useful than the empty string we had before.
  defp decode_error_body(""), do: ""

  defp decode_error_body(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _} -> raw
    end
  end

  defp process_sse_chunk(data, acc) do
    data
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, acc ->
      case String.trim_leading(line, "data: ") do
        "[DONE]" ->
          acc

        "" ->
          acc

        json_str ->
          case Jason.decode(json_str) do
            {:ok, event} -> handle_sse_event(event, acc)
            {:error, _} -> acc
          end
      end
    end)
  end

  defp handle_sse_event(%{"type" => "content_block_start", "content_block" => block}, acc) do
    %{acc | current_block: block}
  end

  defp handle_sse_event(%{"type" => "content_block_delta", "delta" => delta}, acc) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        acc.on_chunk.({:text, text})

        # Accumulate into current block
        current =
          Map.update(
            acc.current_block || %{"type" => "text", "text" => ""},
            "text",
            text,
            &(&1 <> text)
          )

        %{acc | current_block: current}

      %{"type" => "input_json_delta"} ->
        # Tool input streaming — accumulate raw JSON
        json_chunk = delta["partial_json"] || ""

        current =
          Map.update(
            acc.current_block || %{"type" => "tool_use"},
            "_input_json",
            json_chunk,
            &(&1 <> json_chunk)
          )

        %{acc | current_block: current}

      _ ->
        acc
    end
  end

  defp handle_sse_event(%{"type" => "content_block_stop"}, acc) do
    block =
      case acc.current_block do
        %{"type" => "tool_use", "_input_json" => json} = b ->
          case Jason.decode(json) do
            {:ok, input} -> b |> Map.put("input", input) |> Map.delete("_input_json")
            _ -> b
          end

        b ->
          b
      end

    if block do
      acc.on_chunk.({:block_done, block})
      %{acc | content: [block | acc.content], current_block: nil}
    else
      acc
    end
  end

  defp handle_sse_event(%{"type" => "message_delta", "delta" => delta, "usage" => usage}, acc) do
    %{
      acc
      | stop_reason: delta["stop_reason"] || acc.stop_reason,
        usage: %{
          acc.usage
          | output_tokens: acc.usage.output_tokens + (usage["output_tokens"] || 0)
        }
    }
  end

  defp handle_sse_event(%{"type" => "message_start", "message" => msg}, acc) do
    input_tokens = get_in(msg, ["usage", "input_tokens"]) || 0
    %{acc | usage: %{acc.usage | input_tokens: input_tokens}}
  end

  defp handle_sse_event(_, acc), do: acc

  # --- Shared helpers ---

  defp build_body(messages, opts) do
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)
    system = Keyword.get(opts, :system)
    thinking = Keyword.get(opts, :thinking)
    tools = Keyword.get(opts, :tools)

    %{
      model: model,
      max_tokens: max_tokens,
      messages: format_messages(messages)
    }
    |> maybe_put(:temperature, temperature)
    |> maybe_put(:system, system)
    |> maybe_put(:tools, tools)
    |> maybe_put_thinking(thinking)
  end

  defp headers(api_key, content_type \\ nil) do
    h = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    if content_type, do: [{"content-type", content_type} | h], else: h
  end

  defp parse_usage(%{"usage" => %{"input_tokens" => inp, "output_tokens" => out}}) do
    [input_tokens: inp, output_tokens: out]
  end

  defp parse_usage(_), do: []

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} -> %{role: role, content: content}
      %{"role" => role, "content" => content} -> %{role: role, content: content}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_thinking(map, nil), do: map

  defp maybe_put_thinking(map, "enabled"),
    do: Map.put(map, :thinking, %{type: "enabled", budget_tokens: 10_000})

  defp maybe_put_thinking(map, "adaptive"), do: Map.put(map, :thinking, %{type: "auto"})
  defp maybe_put_thinking(map, _), do: map
end
