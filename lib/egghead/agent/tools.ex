defmodule Egghead.Agent.Tools do
  @moduledoc """
  Tool definitions and execution for Egghead agents.

  Agents are given tools based on their declared capabilities. The agent
  decides when to call them — we don't force-search on every prompt.

  Tools are defined in Anthropic's tool-use format and executed locally
  against the Egghead API.
  """

  require Logger

  @doc """
  Returns tool definitions for the given capabilities, in Anthropic tool format.
  """
  @spec definitions_for(capabilities :: [String.t()]) :: [map()]
  def definitions_for(capabilities) do
    all_tools()
    |> Enum.filter(fn tool -> tool.capability in capabilities end)
    |> Enum.map(&tool_definition/1)
  end

  @doc """
  Executes a tool call and returns the result as a string.

  The optional `agent_context` map provides the calling agent's id for
  safety checks (e.g. preventing self-modification).
  """
  @spec execute(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(tool_name, input, agent_context \\ %{}) do
    room_id = agent_context[:room_id]

    Egghead.Chat.ToolCache.get_or_execute(room_id, tool_name, input, fn ->
      case do_execute(tool_name, input, agent_context) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end)
  rescue
    e -> {:error, "Tool error: #{Exception.message(e)}"}
  end

  # --- Tool registry ---

  defp all_tools do
    [
      %{
        name: "search_records",
        capability: "search",
        description:
          "Full-text search across record titles and bodies. Uses porter stemming. Returns ranked results with id, title, tags, and class.",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "Search query — use keywords, not full sentences"
            },
            limit: %{type: "integer", description: "Max results (default 10)"}
          },
          required: ["query"]
        }
      },
      %{
        name: "get_record",
        capability: "record_read",
        description:
          "Read a record's metadata and a preview of its body. Returns id, title, tags, links, backlinks, and a body preview. Use get_record_body to read the full content if needed.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id (e.g. architecture/record-store)"}
          },
          required: ["id"]
        }
      },
      %{
        name: "get_record_body",
        capability: "record_read",
        description:
          "Read the full body of a record. Only use this when you need the complete content — check get_record preview first. Be mindful of your context window.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id"}
          },
          required: ["id"]
        }
      },
      %{
        name: "list_records",
        capability: "record_read",
        description:
          "List records in the store. Optionally filter by tag. Returns id, title, tags, and class.",
        input_schema: %{
          type: "object",
          properties: %{
            tag: %{type: "string", description: "Optional tag to filter by"}
          }
        }
      },
      %{
        name: "find_backlinks",
        capability: "record_read",
        description: "Find records that link TO a given record. The reverse graph.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id to find backlinks for"}
          },
          required: ["id"]
        }
      },
      %{
        name: "find_links",
        capability: "record_read",
        description: "Find records that a given record links TO. Forward graph traversal.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id to start from"},
            depth: %{type: "integer", description: "Traversal depth (default 1)"}
          },
          required: ["id"]
        }
      },
      %{
        name: "recent_records",
        capability: "record_read",
        description: "List recently updated or created records.",
        input_schema: %{
          type: "object",
          properties: %{
            order_by: %{
              type: "string",
              enum: ["updated", "created"],
              description: "Sort field (default: updated)"
            },
            limit: %{type: "integer", description: "Max results (default 10)"},
            since: %{type: "string", description: "ISO 8601 date to filter from"}
          }
        }
      },
      %{
        name: "create_record",
        capability: "record_append",
        description:
          "Create a new record in the store. Returns the created record's id. Use this to persist knowledge, insights, and connections you discover.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{
              type: "string",
              description: "Record id (e.g. patterns/error-retry). Use meaningful paths."
            },
            title: %{type: "string", description: "Record title"},
            tags: %{type: "array", items: %{type: "string"}, description: "Tags"},
            links: %{type: "array", items: %{type: "string"}, description: "Linked record ids"},
            class: %{
              type: "string",
              enum: ["durable", "inbox", "deliberation", "agent"],
              description: "Record class (default: durable)"
            },
            body: %{type: "string", description: "Record body (Markdown)"}
          },
          required: ["title", "body"]
        }
      },
      %{
        name: "update_record",
        capability: "record_modify",
        description:
          "Update an existing record by merging new values. Only fields you provide change — everything else is preserved. For agent records, you can set model, provider, capabilities, and any other frontmatter fields.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Id of the record to update"},
            title: %{type: "string", description: "New title"},
            tags: %{type: "array", items: %{type: "string"}, description: "New tags"},
            links: %{
              type: "array",
              items: %{type: "string"},
              description: "New linked record ids"
            },
            class: %{
              type: "string",
              enum: ["durable", "inbox", "deliberation", "agent"],
              description: "Record class"
            },
            body: %{type: "string", description: "New body (Markdown)"},
            model: %{
              type: "string",
              description: "LLM model id (for agent records, e.g. claude-haiku-4-5)"
            },
            provider: %{type: "string", description: "LLM provider (for agent records)"},
            capabilities: %{
              type: "array",
              items: %{type: "string"},
              description: "Agent capabilities list (for agent records)"
            }
          },
          additionalProperties: true,
          required: ["id"]
        }
      }
    ]
  end

  defp tool_definition(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }
  end

  # --- Tool execution ---

  defp do_execute("search_records", %{"query" => query} = input, _ctx) do
    limit = input["limit"] || 10
    records = Egghead.search(query, limit: limit)
    {:ok, format_record_list(records)}
  end

  defp do_execute("get_record", %{"id" => id}, _ctx) do
    case Egghead.get_record(id) do
      {:ok, record} -> {:ok, format_record_preview(record)}
      {:error, :not_found} -> {:error, "Record not found: #{id}"}
    end
  end

  defp do_execute("get_record_body", %{"id" => id}, _ctx) do
    case Egghead.get_record(id) do
      {:ok, record} -> {:ok, record.body || "(empty)"}
      {:error, :not_found} -> {:error, "Record not found: #{id}"}
    end
  end

  defp do_execute("list_records", input, _ctx) do
    records =
      case input["tag"] do
        nil -> Egghead.list_records()
        tag -> Egghead.search_by_tag(tag)
      end

    {:ok, format_record_list(records)}
  end

  defp do_execute("find_backlinks", %{"id" => id}, _ctx) do
    records = Egghead.find_backlinks(id)
    {:ok, format_record_list(records)}
  end

  defp do_execute("find_links", %{"id" => id} = input, _ctx) do
    depth = input["depth"] || 1
    records = Egghead.find_links(id, depth)
    {:ok, format_record_list(records)}
  end

  defp do_execute("recent_records", input, _ctx) do
    opts =
      []
      |> then(fn o ->
        if input["order_by"] == "created", do: [{:order_by, :created} | o], else: o
      end)
      |> then(fn o ->
        if input["limit"], do: [{:limit, input["limit"]} | o], else: [{:limit, 10} | o]
      end)
      |> then(fn o -> if input["since"], do: [{:since, input["since"]} | o], else: o end)

    records = Egghead.recent(opts)
    {:ok, format_record_list(records)}
  end

  defp do_execute("create_record", input, _ctx) do
    attrs =
      input
      |> Map.take(["id", "title", "tags", "links", "class", "body"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Egghead.create_record(attrs) do
      {:ok, record} -> {:ok, "Created record: #{record.id}"}
      {:error, :already_exists} -> {:error, "Record already exists: #{attrs["id"]}"}
      {:error, reason} -> {:error, "Failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("update_record", %{"id" => id} = input, _ctx) do
    attrs =
      input
      |> Map.delete("id")
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Egghead.update_record(id, attrs) do
      {:ok, record} -> {:ok, "Updated record: #{record.id}"}
      {:error, :not_found} -> {:error, "Record not found: #{id}"}
      {:error, reason} -> {:error, "Failed: #{inspect(reason)}"}
    end
  end

  defp do_execute(name, _input, _ctx) do
    {:error, "Unknown tool: #{name}"}
  end

  # --- Formatting ---

  defp format_record_list([]), do: "(no records found)"

  defp format_record_list(records) do
    records
    |> Enum.map(fn r ->
      tags = if r.tags != [], do: " [#{Enum.join(r.tags, ", ")}]", else: ""
      "- #{r.id}: #{r.title || "(untitled)"}#{tags} (#{r.class})"
    end)
    |> Enum.join("\n")
  end

  defp format_record_preview(record) do
    meta =
      [
        "id: #{record.id}",
        if(record.title, do: "title: #{record.title}"),
        if(record.author, do: "author: #{record.author}"),
        "class: #{record.class}",
        if(record.tags != [], do: "tags: #{Enum.join(record.tags, ", ")}"),
        if(record.links != [], do: "links: #{Enum.join(record.links, ", ")}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    backlinks = Egghead.find_backlinks(record.id)

    backlinks_str =
      if backlinks != [] do
        "\nBacklinks: #{Enum.map_join(backlinks, ", ", &"#{&1.id}")}"
      else
        ""
      end

    body = record.body || ""
    body_tokens = div(String.length(body), 4)

    preview =
      if String.length(body) > 500 do
        String.slice(body, 0, 500) <>
          "...\n\n(~#{body_tokens} tokens total — use get_record_body to read full content)"
      else
        body
      end

    "#{meta}#{backlinks_str}\n\n#{preview}"
  end
end
