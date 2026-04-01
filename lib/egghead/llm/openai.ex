defmodule Egghead.LLM.OpenAI do
  @moduledoc """
  OpenAI Chat Completions provider.

  Also serves as the universal adapter for any OpenAI-compatible endpoint
  (Ollama, LMStudio, Groq, OpenRouter, vLLM, etc.) via configurable `base_url`.
  """

  @behaviour Egghead.LLM.Provider

  @default_url "https://api.openai.com/v1"
  @default_model "gpt-4o"
  @default_max_tokens 4096

  @impl true
  def chat(messages, opts \\ []) do
    do_request(messages, opts, false)
  end

  @impl true
  def chat_stream(messages, opts \\ []) do
    do_request(messages, opts, true)
  end

  @impl true
  def get_model_info(model_id, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_url)
    api_key = Keyword.get(opts, :api_key)

    case Req.get("#{base_url}/models/#{model_id}", headers: auth_headers(api_key)) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           "id" => body["id"],
           "max_input_tokens" => body["context_window"] || body["max_input_tokens"],
           "max_tokens" => body["max_output_tokens"] || body["max_tokens"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  @impl true
  def list_models(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_url)
    api_key = Keyword.get(opts, :api_key)

    case Req.get("#{base_url}/models", headers: auth_headers(api_key), receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        parsed =
          models
          |> Enum.map(fn m ->
            %{
              id: m["id"],
              context_window: m["context_window"],
              max_tokens: m["max_output_tokens"] || m["max_tokens"]
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

  # --- Request handling ---

  defp do_request(messages, opts, _stream) do
    base_url = Keyword.get(opts, :base_url, @default_url)
    api_key = Keyword.get(opts, :api_key)
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)
    system = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools)

    # OpenAI uses system message in the messages array
    messages =
      if system do
        [%{role: "system", content: system} | format_messages(messages)]
      else
        format_messages(messages)
      end

    body =
      %{
        model: model,
        messages: messages,
        max_tokens: max_tokens
      }
      |> maybe_put(:temperature, temperature)
      |> maybe_put_tools(tools)

    case Req.post("#{base_url}/chat/completions",
           json: body,
           headers: auth_headers(api_key),
           receive_timeout: 300_000
         ) do
      {:ok, %{status: 200, body: resp}} ->
        choice = List.first(resp["choices"] || []) || %{}
        message = choice["message"] || %{}

        content = openai_to_anthropic_content(message)
        stop_reason = map_finish_reason(choice["finish_reason"])
        usage = parse_usage(resp)

        {:ok, %{content: content, stop_reason: stop_reason, usage: usage}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  # --- Format conversion (OpenAI response → Anthropic-compatible) ---
  # We normalize all provider responses to the same shape the Agent expects.

  defp openai_to_anthropic_content(message) do
    blocks = []

    # Text content
    blocks =
      case message["content"] do
        nil -> blocks
        "" -> blocks
        text -> blocks ++ [%{"type" => "text", "text" => text}]
      end

    # Tool calls
    blocks =
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

    blocks
  end

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
        # Tool results — convert from Anthropic format to OpenAI format
        tool_results =
          Enum.map(content, fn
            %{type: "tool_result", tool_use_id: id, content: text} ->
              %{role: "tool", tool_call_id: id, content: to_string(text)}

            %{"type" => "tool_result", "tool_use_id" => id, "content" => text} ->
              %{role: "tool", tool_call_id: id, content: to_string(text)}

            other ->
              other
          end)

        # If all items are tool results, return them as separate messages
        if Enum.all?(tool_results, &is_map(&1)) and
             Enum.all?(tool_results, &Map.has_key?(&1, :tool_call_id)) do
          tool_results
        else
          [%{role: "user", content: content}]
        end

      %{role: "assistant", content: content} when is_list(content) ->
        # Convert Anthropic-style content blocks to OpenAI format
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
        msg = if text != "", do: Map.put(msg, :content, text), else: Map.put(msg, :content, nil)
        msg = if tool_calls != [], do: Map.put(msg, :tool_calls, tool_calls), else: msg
        [msg]

      %{role: role, content: content} ->
        [%{role: role, content: content}]

      %{"role" => role, "content" => content} ->
        [%{role: role, content: content}]
    end)
    |> List.flatten()
  end

  # --- Helpers ---

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
