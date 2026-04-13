defmodule Egghead.MCP.Handler do
  @moduledoc """
  Shared MCP protocol handler. Processes JSON-RPC messages and dispatches
  tool calls to the Egghead API. Used by both the stdio and HTTP transports.
  """

  @protocol_version "2025-03-26"

  @doc """
  Handles a decoded JSON-RPC message map. Returns a response map, or `:noreply`
  for notifications that don't require a response.
  """
  @spec handle(map()) :: map() | :noreply
  def handle(%{"method" => "initialize", "id" => id}) do
    result(id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "egghead", version: "0.1.0"}
    })
  end

  def handle(%{"method" => "notifications/initialized"}) do
    :noreply
  end

  def handle(%{"method" => "tools/list", "id" => id}) do
    result(id, %{tools: tool_definitions()})
  end

  def handle(%{"method" => "tools/call", "id" => id, "params" => params}) do
    name = params["name"]
    args = params["arguments"] || %{}

    case call_tool(name, args) do
      {:ok, text} ->
        result(id, %{content: [%{type: "text", text: text}], isError: false})

      {:error, text} ->
        result(id, %{content: [%{type: "text", text: text}], isError: true})
    end
  end

  def handle(%{"method" => "ping", "id" => id}) do
    result(id, %{})
  end

  # Unknown method with id = request expecting response
  def handle(%{"method" => method, "id" => id}) do
    error(id, -32601, "Method not found: #{method}")
  end

  # Notification (no id) — no response
  def handle(%{"method" => _}) do
    :noreply
  end

  def handle(_) do
    :noreply
  end

  # --- JSON-RPC helpers ---

  defp result(id, res) do
    %{jsonrpc: "2.0", id: id, result: res}
  end

  @doc "Build a JSON-RPC error response."
  def error(id, code, message) do
    %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
  end

  # --- Tool definitions ---

  defp tool_definitions do
    [
      %{
        name: "egghead_search",
        description:
          "Full-text search across record titles and bodies. Uses porter stemming so 'error' matches 'errors'. Returns ranked results.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Search query"},
            limit: %{type: "integer", description: "Max results (default 20)"}
          },
          required: ["query"]
        }
      },
      %{
        name: "egghead_get",
        description:
          "Read a record by its id. Returns the full body, metadata, tags, links, and outline.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id"}
          },
          required: ["id"]
        }
      },
      %{
        name: "egghead_list",
        description:
          "List records in the store. Optionally filter by tag. Returns metadata (no body).",
        inputSchema: %{
          type: "object",
          properties: %{
            tag: %{type: "string", description: "Optional tag to filter by"}
          }
        }
      },
      %{
        name: "egghead_create",
        description:
          "Create a new record. Writes a Markdown file to the records directory. Returns the created record.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id (auto-generated if omitted)"},
            title: %{type: "string", description: "Record title"},
            tags: %{
              type: "array",
              items: %{type: "string"},
              description: "Tags for the record"
            },
            links: %{
              type: "array",
              items: %{type: "string"},
              description: "Linked record ids"
            },
            class: %{
              type: "string",
              enum: ["durable", "inbox", "deliberation"],
              description: "Record class (default: durable)"
            },
            body: %{type: "string", description: "Record body content (Markdown)"}
          },
          required: ["title"]
        }
      },
      %{
        name: "egghead_update",
        description:
          "Update an existing record. Merges the given fields into the record. Omitted fields are left unchanged. To replace the body entirely, pass the full new body.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id to update"},
            title: %{type: "string", description: "New title"},
            tags: %{
              type: "array",
              items: %{type: "string"},
              description: "New tags (replaces existing tags)"
            },
            links: %{
              type: "array",
              items: %{type: "string"},
              description: "New linked record ids (replaces existing links)"
            },
            body: %{type: "string", description: "New body content (Markdown)"}
          },
          required: ["id"]
        }
      },
      %{
        name: "egghead_find_links",
        description:
          "Find records that this record links TO. Traverses the link graph up to the specified depth.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id to start from"},
            depth: %{type: "integer", description: "How many levels to traverse (default 1)"}
          },
          required: ["id"]
        }
      },
      %{
        name: "egghead_backlinks",
        description:
          "Find records that link TO this record. The reverse graph — who references this record?",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id to find backlinks for"}
          },
          required: ["id"]
        }
      },
      %{
        name: "egghead_recent",
        description: "List recently updated or created records. Useful for seeing what changed.",
        inputSchema: %{
          type: "object",
          properties: %{
            order_by: %{
              type: "string",
              enum: ["updated", "created"],
              description: "Sort by updated (default) or created"
            },
            limit: %{type: "integer", description: "Max results (default 20)"},
            since: %{
              type: "string",
              description: "ISO 8601 date to filter from (e.g. 2026-03-25)"
            }
          }
        }
      },
      %{
        name: "egghead_consult",
        description:
          "Consult the Egghead agent swarm. Creates an ephemeral room, sends your question to all agents, and returns their aggregated responses. Use this for questions that benefit from multiple perspectives.",
        inputSchema: %{
          type: "object",
          properties: %{
            question: %{type: "string", description: "The question to consult the swarm about"},
            timeout: %{type: "integer", description: "Max wait in seconds (default 120)"}
          },
          required: ["question"]
        }
      },
      %{
        name: "egghead_prompt",
        description:
          "Send a prompt to a named Egghead agent. The agent gathers relevant records, reasons through its disposition (personality/expertise), and responds. Agents with record_append capability may create new records.",
        inputSchema: %{
          type: "object",
          properties: %{
            agent: %{type: "string", description: "Agent id (e.g. agents/scout)"},
            message: %{type: "string", description: "The prompt to send to the agent"}
          },
          required: ["agent", "message"]
        }
      },
      %{
        name: "egghead_agents",
        description:
          "List all running Egghead agents with their capabilities, model, and token usage.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "egghead_handoff",
        description:
          "Summarize the agent's current conversation into a deliberation record and clear history. Optionally provide a new prompt to continue with. Returns the deliberation record id.",
        inputSchema: %{
          type: "object",
          properties: %{
            agent: %{type: "string", description: "Agent id"},
            next_prompt: %{
              type: "string",
              description: "Optional new prompt to start the fresh session with"
            }
          },
          required: ["agent"]
        }
      },
      %{
        name: "egghead_save",
        description:
          "Ask the agent to extract key insights from the current conversation and save them as durable records. Does not clear the conversation.",
        inputSchema: %{
          type: "object",
          properties: %{
            agent: %{type: "string", description: "Agent id"}
          },
          required: ["agent"]
        }
      },
      %{
        name: "egghead_providers",
        description: "List configured LLM providers and their status.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "egghead_models",
        description: "List available models across all configured providers.",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  # --- Tool execution ---

  defp call_tool("egghead_search", %{"query" => query} = args) do
    limit = args["limit"] || 20
    records = Egghead.search(query, limit: limit)
    {:ok, format_record_list(records, "Search results for \"#{query}\"")}
  end

  defp call_tool("egghead_get", %{"id" => id}) do
    case Egghead.get_record(id) do
      {:ok, record} -> {:ok, format_full_record(record)}
      {:error, :not_found} -> {:error, "Record not found: #{id}"}
    end
  end

  defp call_tool("egghead_list", args) do
    records =
      case args["tag"] do
        nil -> Egghead.list_records()
        tag -> Egghead.search_by_tag(tag)
      end

    label = if args["tag"], do: "Records tagged '#{args["tag"]}'", else: "All records"
    {:ok, format_record_list(records, label)}
  end

  defp call_tool("egghead_create", args) do
    attrs =
      args
      |> Map.take(["id", "title", "tags", "links", "class", "body"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Egghead.create_record(attrs) do
      {:ok, record} -> {:ok, "Created record: #{record.id}\n\n#{format_full_record(record)}"}
      {:error, :already_exists} -> {:error, "Record already exists: #{attrs["id"]}"}
      {:error, reason} -> {:error, "Failed to create record: #{inspect(reason)}"}
    end
  end

  defp call_tool("egghead_update", %{"id" => id} = args) do
    attrs =
      args
      |> Map.take(["title", "tags", "links", "body"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Egghead.update_record(id, attrs) do
      {:ok, record} -> {:ok, "Updated record: #{record.id}\n\n#{format_full_record(record)}"}
      {:error, :not_found} -> {:error, "Record not found: #{id}"}
      {:error, reason} -> {:error, "Failed to update record: #{inspect(reason)}"}
    end
  end

  defp call_tool("egghead_find_links", %{"id" => id} = args) do
    depth = args["depth"] || 1
    records = Egghead.find_links(id, depth)
    {:ok, format_record_list(records, "Records linked from #{id} (depth #{depth})")}
  end

  defp call_tool("egghead_backlinks", %{"id" => id}) do
    records = Egghead.find_backlinks(id)
    {:ok, format_record_list(records, "Records linking to #{id}")}
  end

  defp call_tool("egghead_recent", args) do
    opts =
      []
      |> then(fn o ->
        case args["order_by"] do
          "created" -> Keyword.put(o, :order_by, :created)
          _ -> o
        end
      end)
      |> then(fn o ->
        case args["limit"] do
          nil -> o
          n -> Keyword.put(o, :limit, n)
        end
      end)
      |> then(fn o ->
        case args["since"] do
          nil -> o
          s -> Keyword.put(o, :since, s)
        end
      end)

    records = Egghead.recent(opts)
    {:ok, format_record_list(records, "Recent records")}
  end

  defp call_tool("egghead_consult", %{"question" => question} = args) do
    timeout = (args["timeout"] || 120) * 1000

    case Egghead.consult(question, timeout: timeout) do
      {:ok, %{responses: responses, transcript_id: transcript_id}} ->
        formatted =
          responses
          |> Enum.map_join("\n\n---\n\n", fn r ->
            "**#{r.agent}**:\n#{r.text}"
          end)

        footer =
          if transcript_id,
            do: "\n\n---\n_Transcript saved: #{transcript_id}_",
            else: ""

        {:ok, "#{formatted}#{footer}"}

      {:error, reason} ->
        {:error, "Consultation failed: #{inspect(reason)}"}
    end
  end

  defp call_tool("egghead_prompt", %{"agent" => agent_id, "message" => message}) do
    case Egghead.prompt(agent_id, message) do
      {:ok, %{text: text} = resp} ->
        footer = format_response_footer(resp)
        {:ok, "#{text}\n\n---\n#{footer}"}

      {:error, :agent_not_found} ->
        {:error, "Agent not found: #{agent_id}. Use egghead_agents to see running agents."}

      {:error, :missing_api_key} ->
        {:error, "ANTHROPIC_API_KEY environment variable is not set."}

      {:error, reason} ->
        {:error, "Agent error: #{inspect(reason)}"}
    end
  end

  defp call_tool("egghead_agents", _args) do
    agents = Egghead.list_agents()

    if agents == [] do
      {:ok, "No agents running. Create a record with class: agent to define one."}
    else
      lines =
        Enum.map(agents, fn a ->
          caps = Enum.join(a.capabilities, ", ")

          ctx_pct =
            if a.context_window,
              do: " | context: #{Float.round(a.session_tokens / a.context_window * 100, 1)}%",
              else: ""

          tokens = "#{a.usage.input_tokens + a.usage.output_tokens} tokens"

          "- #{a.id}: #{a.name} [#{caps}] (#{a.model}, #{tokens}#{ctx_pct}, #{a.history_length} turns)"
        end)

      {:ok, "Running agents (#{length(agents)}):\n#{Enum.join(lines, "\n")}"}
    end
  end

  defp call_tool("egghead_handoff", %{"agent" => agent_id} = args) do
    next_prompt = args["next_prompt"]

    case Egghead.handoff(agent_id, next_prompt) do
      {:ok, delib_id} ->
        {:ok, "Deliberation saved: #{delib_id}\nConversation cleared."}

      {:ok, delib_id, {:ok, response}} ->
        {:ok, "Deliberation saved: #{delib_id}\n\n---\n\n#{response}"}

      {:ok, delib_id, {:error, reason}} ->
        {:ok, "Deliberation saved: #{delib_id}\nBut next prompt failed: #{inspect(reason)}"}

      {:error, :agent_not_found} ->
        {:error, "Agent not found: #{agent_id}"}

      {:error, :no_history} ->
        {:error, "No conversation to summarize."}

      {:error, reason} ->
        {:error, "Handoff failed: #{inspect(reason)}"}
    end
  end

  defp call_tool("egghead_save", %{"agent" => agent_id}) do
    case Egghead.save_insights(agent_id) do
      {:ok, summary} -> {:ok, summary}
      {:error, :agent_not_found} -> {:error, "Agent not found: #{agent_id}"}
      {:error, :no_history} -> {:error, "No conversation to save from."}
      {:error, reason} -> {:error, "Save failed: #{inspect(reason)}"}
    end
  end

  defp call_tool("egghead_providers", _args) do
    providers = Egghead.list_providers()

    if providers == [] do
      {:ok,
       "No providers configured. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY, or create ~/.egghead/providers.yml"}
    else
      lines =
        Enum.map(providers, fn p ->
          auth = if p.has_key, do: "authenticated", else: "no key"
          url = if p.base_url, do: " (#{p.base_url})", else: ""
          "- #{p.name}: #{p.api}#{url} [#{auth}]"
        end)

      {:ok, "Configured providers (#{length(providers)}):\n#{Enum.join(lines, "\n")}"}
    end
  end

  defp call_tool("egghead_models", _args) do
    models = Egghead.list_models()

    if models == [] do
      {:ok, "No models available. Configure a provider first."}
    else
      lines =
        Enum.map(models, fn m ->
          ctx = if m[:context_window], do: " (#{m.context_window} ctx)", else: ""
          "- #{m.full_id}#{ctx}"
        end)

      {:ok, "Available models (#{length(models)}):\n#{Enum.join(lines, "\n")}"}
    end
  end

  defp call_tool(name, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  # --- Formatting ---

  defp format_full_record(record) do
    meta_lines =
      [
        "id: #{record.id}",
        if(record.title, do: "title: #{record.title}"),
        if(record.author, do: "author: #{record.author}"),
        if(record.created, do: "created: #{record.created}"),
        if(record.updated, do: "updated: #{record.updated}"),
        "class: #{record.class}",
        if(record.tags != [], do: "tags: #{Enum.join(record.tags, ", ")}"),
        if(record.links != [], do: "links: #{Enum.join(record.links, ", ")}"),
        if(record.meta != %{}, do: "meta: #{Jason.encode!(record.meta)}")
      ]
      |> Enum.reject(&is_nil/1)

    outline_section =
      if record.outline != [] do
        headings =
          record.outline
          |> Enum.map(fn %{level: l, text: t} -> "#{String.duplicate("  ", l - 1)}- #{t}" end)
          |> Enum.join("\n")

        "\n## Outline\n#{headings}"
      end

    backlinks =
      case Egghead.find_backlinks(record.id) do
        [] -> nil
        recs -> "\n## Backlinks\n#{Enum.map_join(recs, "\n", &"- #{&1.id}: #{&1.title}")}"
      end

    [
      "## Metadata\n#{Enum.join(meta_lines, "\n")}",
      "\n## Body\n#{record.body || "(empty)"}",
      outline_section,
      backlinks
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_response_footer(resp) do
    parts = [
      resp.model,
      "#{resp.usage.input_tokens + resp.usage.output_tokens} tokens",
      if(resp.tool_calls != [], do: "#{length(resp.tool_calls)} tool calls"),
      if(resp.records_created != [], do: "#{length(resp.records_created)} created"),
      if(resp.records_updated != [], do: "#{length(resp.records_updated)} updated"),
      "#{resp.duration_ms}ms"
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" | ")
  end

  defp format_record_list([], label), do: "#{label}: (none)"

  defp format_record_list(records, label) do
    lines =
      records
      |> Enum.map(fn r ->
        tags = if r.tags != [], do: " [#{Enum.join(r.tags, ", ")}]", else: ""
        "- #{r.id}: #{r.title || "(untitled)"}#{tags} (#{r.class})"
      end)

    "#{label} (#{length(records)}):\n#{Enum.join(lines, "\n")}"
  end
end
