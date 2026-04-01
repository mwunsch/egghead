defmodule Egghead.LLM.Google do
  @moduledoc """
  Google Gemini provider.

  Calls the Gemini API via the `generateContent` endpoint. Normalizes
  responses to the same format as the Anthropic provider so the Agent
  loop works identically.
  """

  @behaviour Egghead.LLM.Provider

  @api_url "https://generativelanguage.googleapis.com/v1beta"
  @default_model "gemini-2.0-flash"
  @default_max_tokens 4096

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key)
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      body =
        %{
          contents: format_messages(messages),
          generationConfig: %{
            maxOutputTokens: max_tokens
          }
        }
        |> maybe_put_system(system)
        |> maybe_put_temperature(temperature)
        |> maybe_put_tools(tools)

      url = "#{@api_url}/models/#{model}:generateContent?key=#{api_key}"

      case Req.post(url,
             json: body,
             headers: [{"content-type", "application/json"}],
             receive_timeout: 300_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          parse_response(resp)

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_error, reason}}
      end
    end
  end

  @impl true
  def chat_stream(messages, opts) do
    # For now, fall back to non-streaming
    chat(messages, opts)
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
            |> Enum.filter(&String.contains?(&1["name"] || "", "gemini"))
            |> Enum.map(fn m ->
              # Model names come as "models/gemini-2.0-flash" — strip prefix
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

    stop_reason =
      case candidate["finishReason"] do
        "STOP" -> "end_turn"
        "MAX_TOKENS" -> "max_tokens"
        "TOOL_USE" -> "tool_use"
        _ -> if(Enum.any?(blocks, &(&1["type"] == "tool_use")), do: "tool_use", else: "end_turn")
      end

    usage =
      case resp["usageMetadata"] do
        %{"promptTokenCount" => inp, "candidatesTokenCount" => out} ->
          [input_tokens: inp, output_tokens: out]

        _ ->
          []
      end

    {:ok, %{content: blocks, stop_reason: stop_reason, usage: usage}}
  end

  # --- Message formatting (to Gemini format) ---

  defp format_messages(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: "user", content: content} when is_list(content) ->
        # Tool results
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
