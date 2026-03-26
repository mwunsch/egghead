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

  defp error(id, code, message) do
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
