defmodule Egghead.Agent.Tools do
  @moduledoc """
  Tool definitions and execution for Egghead agents.

  Tools are gated by capabilities at two points:

  1. **Offering time** — tools are sent to the LLM only if the agent holds
     at least one verb the tool might invoke (`offers_on`).
  2. **Dispatch time** — before running, the tool's input is resolved into
     one or more concrete `%Request{}`s and every one must pass
     `Capability.check/3`.

  Record-store tools route by target class: a call touching a `class: agent`
  record produces requests against the `agent` resource, never `records`.
  The two resource families are disjoint at dispatch.
  """

  require Logger

  alias Egghead.Capability
  alias Egghead.Capability.Denial
  alias Egghead.Capability.Grant
  alias Egghead.Capability.Request

  @doc """
  Returns tool definitions for the given grants, in Anthropic tool format.

  Merges two sources:

  - **Local tools** — offered if the agent holds any of the tool's
    `offers_on` verbs. Call-time `Capability.check/3` handles scope.
  - **MCP tools** — offered only for servers whose `requires:` is a
    subset of the agent's grants. Tool names are prefixed as
    `mcp__<server>__<tool>`. The subset check at offering time is
    the authorization; dispatch re-checks as belt-and-suspenders.
  """
  @spec definitions_for([Grant.t()]) :: [map()]
  def definitions_for(grants) do
    local_defs(grants) ++ mcp_defs(grants)
  end

  defp local_defs(grants) do
    held = Capability.verbs_held(grants)

    all_tools()
    |> Enum.filter(fn tool ->
      Enum.any?(tool.offers_on, fn {r, v} -> "#{r}.#{v}" in held end)
    end)
    |> Enum.map(&tool_definition/1)
  end

  defp mcp_defs(grants) do
    Application.get_env(:egghead, :mcp_servers, [])
    |> Enum.filter(fn server -> Capability.subset?(server.requires, grants) end)
    |> Enum.flat_map(&mcp_server_defs/1)
  end

  defp mcp_server_defs(%{name: server_name}) do
    Egghead.MCP.Client.tools_for(server_name)
    |> Enum.map(fn tool ->
      %{
        name: mcp_tool_name(server_name, tool["name"]),
        description: tool["description"] || "",
        input_schema: tool["inputSchema"] || %{type: "object", properties: %{}}
      }
    end)
  end

  @doc "Prefix convention for MCP tool names sent to the LLM."
  def mcp_tool_name(server, tool), do: "mcp__#{server}__#{tool}"

  @doc """
  Parse an MCP-prefixed tool name. Returns `{:ok, server, tool}` or
  `:not_mcp` for local tool names.
  """
  def parse_mcp_tool_name("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, server, tool}
      _ -> :not_mcp
    end
  end

  def parse_mcp_tool_name(_), do: :not_mcp

  @doc """
  Executes a tool call, gated by the agent's capabilities.

  `agent_context` must include `:capabilities` (a list of `%Grant{}`) and
  `:agent_id`. Returns `{:ok, text}`, `{:error, reason}`, or
  `{:denied, %Denial{}}`.
  """
  @spec execute(String.t(), map(), map()) ::
          {:ok, String.t()} | {:error, String.t()} | {:denied, Denial.t()}
  def execute(tool_name, input, agent_context \\ %{}) do
    room_id = agent_context[:room_id]
    grants = Map.get(agent_context, :capabilities, [])

    case parse_mcp_tool_name(tool_name) do
      {:ok, server, tool} ->
        execute_mcp(server, tool, tool_name, input, grants, agent_context, room_id)

      :not_mcp ->
        case resolve_requests(tool_name, input, agent_context) do
          {:error, :unknown_tool} ->
            {:error, "Unknown tool: #{tool_name}"}

          {:error, reason} ->
            {:error, reason}

          {:ok, requests} ->
            case check_all(grants, requests, agent_context, tool_name) do
              :ok -> run_tool(tool_name, input, agent_context, room_id)
              {:denied, denial} -> handle_denial(denial)
            end
        end
    end
  end

  # MCP dispatch: re-verify the server's requires subset against the
  # agent's current grants, then forward to MCP.Client. The subset
  # re-check catches the narrow window where grants changed between
  # offering and call.
  defp execute_mcp(server, tool, tool_name, input, grants, agent_context, _room_id) do
    case Egghead.MCP.Client.config_for(server) do
      nil ->
        {:error, "mcp server #{inspect(server)} not configured"}

      %{requires: required} ->
        if Capability.subset?(required, grants) do
          case Egghead.MCP.Client.call_tool(server, tool, input) do
            {:ok, text} -> {:ok, text}
            {:error, reason} -> {:error, reason}
          end
        else
          denial = %Denial{
            code: :capability_absent,
            request: %Request{resource: :mcp, verb: String.to_atom(server), tool: tool_name},
            held: grants,
            agent_id: Map.get(agent_context, :agent_id),
            tool: tool_name,
            message: "agent lacks required capabilities for mcp server #{inspect(server)}",
            suggested_grant: nil
          }

          handle_denial(denial)
        end
    end
  end

  defp check_all(grants, requests, ctx, tool_name) do
    Enum.reduce_while(requests, :ok, fn req, _ ->
      req = %{req | tool: tool_name}

      case Capability.check(grants, req, ctx) do
        :ok -> {:cont, :ok}
        {:denied, denial} -> {:halt, {:denied, denial}}
      end
    end)
  end

  defp handle_denial(%Denial{} = denial) do
    Logger.warning(
      "Capability denied: #{denial.message}",
      Denial.to_log_metadata(denial)
    )

    {:denied, denial}
  end

  defp run_tool(tool_name, input, agent_context, room_id) do
    Egghead.Chat.ToolCache.get_or_execute(room_id, tool_name, input, fn ->
      case do_execute(tool_name, input, agent_context) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end)
  rescue
    e -> {:error, "Tool error: #{Exception.message(e)}"}
  end

  @doc """
  Resolves a tool call into the list of capability requests it would make.
  Returns `{:ok, [%Request{}]}` or `{:error, reason}`.

  Tools that touch the record store branch on target class here, producing
  requests against `:records` or `:agent` accordingly.
  """
  @spec resolve_requests(String.t(), map(), map()) ::
          {:ok, [Request.t()]} | {:error, term()}
  def resolve_requests(tool_name, input, _ctx) do
    case Enum.find(all_tools(), &(&1.name == tool_name)) do
      nil -> {:error, :unknown_tool}
      tool -> tool.resolve.(input)
    end
  end

  # --- Tool registry ---

  defp all_tools do
    [
      %{
        name: "search_records",
        offers_on: [{:records, :read}],
        resolve: &req_records_read/1,
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
        offers_on: [{:records, :read}],
        resolve: &req_records_read/1,
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
        offers_on: [{:records, :read}],
        resolve: &req_records_read/1,
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
        offers_on: [{:records, :read}],
        resolve: &req_records_read/1,
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
        offers_on: [{:records, :read}],
        resolve: &req_records_read/1,
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
        offers_on: [{:records, :read}],
        resolve: &req_records_read/1,
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
        offers_on: [{:records, :read}],
        resolve: &req_records_read/1,
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
        offers_on: [{:records, :create}, {:agent, :create}],
        resolve: &req_create_record/1,
        description:
          "Create a new record in the store. Returns the created record's id. Any keys beyond the structural fields (id, title, tags, links, class, body) are preserved as frontmatter metadata — e.g. `model`, `provider`, `capabilities` for agent records, or skill-spec keys like `name`, `description`, `allowed-tools`, `compatibility` for skill records. If `capabilities` is set for an agent record, the caller must hold `agent.grant` and the proposed capabilities must be a subset of the caller's own.",
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
              enum: ["durable", "inbox", "deliberation", "agent", "skill", "transcript"],
              description: "Record class (default: durable)"
            },
            body: %{type: "string", description: "Record body (Markdown)"}
          },
          additionalProperties: true,
          required: ["title", "body"]
        }
      },
      %{
        name: "web_fetch",
        offers_on: [{:net, :get}, {:net, :post}, {:net, :put}, {:net, :delete}],
        resolve: &Egghead.Tool.WebFetch.request_for/1,
        description:
          "Fetch a URL over HTTP. Default method is GET; pass `method` for POST/PUT/DELETE. HTML responses are stripped to readable text with links preserved by default (pass `raw: true` for raw HTML). Scoped by `net.*{hosts: [...]}` capability — the URL's host must be in the allow-list.",
        input_schema: %{
          type: "object",
          properties: %{
            url: %{type: "string", description: "Full URL to fetch"},
            method: %{
              type: "string",
              enum: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"],
              description: "HTTP method (default: GET)"
            },
            body: %{type: "string", description: "Request body (for POST/PUT/PATCH)"},
            headers: %{
              type: "array",
              items: %{type: "array", items: %{type: "string"}},
              description: "Header pairs as [name, value] arrays"
            },
            raw: %{
              type: "boolean",
              description: "Preserve raw HTML/body instead of stripping to text"
            },
            timeout: %{
              type: "integer",
              description: "Timeout in milliseconds (default 30000)"
            }
          },
          required: ["url"]
        }
      },
      %{
        name: "shell_exec",
        offers_on: [{:shell, :exec}],
        resolve: &Egghead.Tool.ShellExec.request_for/1,
        description:
          "Run a shell command. The `cmd` and `args` are passed directly to spawn_executable — no shell interpretation, no injection surface. Gated by `shell.exec{cmds: [...], patterns: [...]}` capability. Command output is captured (stdout + stderr combined) and truncated at 30k tokens if oversized.",
        input_schema: %{
          type: "object",
          properties: %{
            cmd: %{type: "string", description: "Command to run (argv[0])"},
            args: %{
              type: "array",
              items: %{type: "string"},
              description: "Command arguments (no shell interpretation)"
            },
            cwd: %{type: "string", description: "Working directory"},
            timeout: %{
              type: "integer",
              description: "Timeout in milliseconds (default 30000)"
            }
          },
          required: ["cmd"]
        }
      },
      %{
        name: "fs_read",
        offers_on: [{:fs, :read}],
        resolve: &Egghead.Tool.FS.request_for_read/1,
        description:
          "Read a file outside the record store. Gated by `fs.read{paths: [...]}` capability. Non-UTF-8 files are refused; large files are truncated.",
        input_schema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Absolute or ~-prefixed file path"},
            max_bytes: %{type: "integer", description: "Override default byte cap"}
          },
          required: ["path"]
        }
      },
      %{
        name: "fs_write",
        offers_on: [{:fs, :write}],
        resolve: &Egghead.Tool.FS.request_for_write/1,
        description:
          "Write (or overwrite) a file outside the record store. Atomic via temp + rename. Gated by `fs.write{paths: [...]}` capability.",
        input_schema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Absolute or ~-prefixed file path"},
            content: %{type: "string", description: "File content (UTF-8 text)"}
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "fs_grep",
        offers_on: [{:fs, :read}],
        resolve: &Egghead.Tool.FS.request_for_grep/1,
        description:
          "Search file contents for a regex pattern. Uses ripgrep if available, Elixir fallback otherwise. Gated by `fs.read{paths: [...]}` capability on the search root.",
        input_schema: %{
          type: "object",
          properties: %{
            pattern: %{type: "string", description: "Regex pattern"},
            path: %{type: "string", description: "File or directory to search"},
            max_results: %{type: "integer", description: "Max matches to return (default 200)"}
          },
          required: ["pattern", "path"]
        }
      },
      %{
        name: "delete_record",
        offers_on: [{:records, :delete}, {:agent, :delete}],
        resolve: &req_delete_record/1,
        description:
          "Move a record to the trash. Reversible — trashed records live in .trash/ under the records directory and can be restored by moving the file back. For agent records this is the 'fire' operation: the agent's process stops when its record disappears from the index. Requires `records.delete` for content records or `agent.delete` for agent records.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Record id to trash"}
          },
          required: ["id"]
        }
      },
      %{
        name: "update_record",
        offers_on: [{:records, :update}, {:agent, :update}, {:agent, :grant}],
        resolve: &req_update_record/1,
        description:
          "Update an existing record by merging new values. Only fields you provide change. Any keys beyond the structural fields become frontmatter metadata — for agent records typical keys are `model`, `provider`, `capabilities`, `thinking`, `max_tokens`, `temperature`, `context_threshold`; for skill records the spec keys like `name`, `description`, `allowed-tools`. Modifying an agent's `capabilities` requires the `agent.grant` capability and is subject to attenuation — grants cannot exceed your own, and you cannot grant capabilities to yourself.",
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
            body: %{type: "string", description: "New body (Markdown)"}
          },
          additionalProperties: true,
          required: ["id"]
        }
      }
    ]
  end

  # --- Request resolvers ---

  defp req_records_read(_input) do
    {:ok, [%Request{resource: :records, verb: :read, scope: %{}}]}
  end

  defp req_create_record(input) do
    class = input["class"] || "durable"

    cond do
      class == "agent" ->
        base = %Request{resource: :agent, verb: :create, scope: %{id: input["id"]}}

        if authority_input?(input) do
          case compute_agent_authority(input) do
            {:ok, %{grants: grants}} ->
              grant_req = %Request{
                resource: :agent,
                verb: :grant,
                scope: %{id: input["id"], granted: grants}
              }

              {:ok, [base, grant_req]}

            {:error, msg} ->
              {:error, msg}
          end
        else
          {:ok, [base]}
        end

      true ->
        {:ok,
         [%Request{resource: :records, verb: :create, scope: %{class: class, id: input["id"]}}]}
    end
  end

  defp req_update_record(%{"id" => id} = input) do
    target_class = lookup_class(id)

    cond do
      target_class == "agent" and authority_input?(input) ->
        case compute_agent_authority(input) do
          {:ok, %{grants: grants}} ->
            other_fields? =
              input |> Map.drop(["id", "capabilities", "access"]) |> map_size() > 0

            requests = [
              %Request{
                resource: :agent,
                verb: :grant,
                scope: %{id: id, granted: grants}
              }
            ]

            requests =
              if other_fields? do
                requests ++ [%Request{resource: :agent, verb: :update, scope: %{id: id}}]
              else
                requests
              end

            {:ok, requests}

          {:error, msg} ->
            {:error, msg}
        end

      target_class == "agent" ->
        {:ok, [%Request{resource: :agent, verb: :update, scope: %{id: id}}]}

      true ->
        {:ok,
         [
           %Request{
             resource: :records,
             verb: :update,
             scope: %{class: target_class, id: id}
           }
         ]}
    end
  end

  defp req_update_record(_), do: {:error, "update_record requires an id"}

  # True if the input carries authority-altering frontmatter for an
  # agent record — either an explicit `capabilities:` list or the
  # `access:` shortcut. Triggers the `agent.grant` attenuation path
  # and dissolves any existing `access:` on write.
  defp authority_input?(input) do
    Map.has_key?(input, "capabilities") or Map.has_key?(input, "access")
  end

  # Expand input's `access:` + `capabilities:` into both grant form (for
  # the `agent.grant` attenuation check) and yaml form (for the record
  # write). Strict validation on both inputs — malformed values
  # short-circuit before any capability check.
  defp compute_agent_authority(input) do
    access_value = input["access"]
    caps_value = input["capabilities"]

    with :ok <- validate_access_input(access_value),
         :ok <- Capability.Validate.validate(caps_value) do
      access_entries = Egghead.Record.Agent.expand_access(access_value)
      explicit = List.wrap(caps_value || [])
      grants = Capability.parse(access_entries ++ explicit)
      yaml_list = Enum.map(grants, &Capability.grant_to_yaml/1)
      {:ok, %{grants: grants, yaml_list: yaml_list}}
    else
      {:error, issues} when is_list(issues) ->
        {:error, Capability.Validate.format_errors(issues)}

      {:error, msg} when is_binary(msg) ->
        {:error, msg}
    end
  end

  defp validate_access_input(nil), do: :ok

  defp validate_access_input(value) do
    if Egghead.Record.Agent.valid_access?(value) do
      :ok
    else
      {:error, "access: must be \"r\", \"w\", or \"rw\" — got #{inspect(value)}"}
    end
  end

  # Rewrite attrs before a record write so agent `capabilities:` is
  # always expressed explicitly on disk, with any `access:` shortcut
  # dissolved. This matches what the attenuation check authorized —
  # the post-write on-disk state is exactly the granted set.
  #
  # `mode` is `:create` (delete the key before render_markdown sees it)
  # or `:update` (use the `:remove` sentinel so merge_record_attrs
  # deletes the key from the existing record's meta).
  defp dissolve_agent_access_attrs(attrs, target_class, mode) do
    if target_class == "agent" and authority_input?(attrs) do
      case compute_agent_authority(attrs) do
        {:ok, %{yaml_list: yaml_list}} ->
          attrs = Map.put(attrs, "capabilities", yaml_list)

          case mode do
            :create -> Map.delete(attrs, "access")
            :update -> Map.put(attrs, "access", :remove)
          end

        {:error, _} ->
          # Resolve-time validation should have caught this. Pass attrs
          # through unchanged; the underlying store will surface any
          # residual issue.
          attrs
      end
    else
      attrs
    end
  end

  defp req_delete_record(%{"id" => id}) do
    case lookup_class(id) do
      "agent" ->
        {:ok, [%Request{resource: :agent, verb: :delete, scope: %{id: id}}]}

      class ->
        {:ok, [%Request{resource: :records, verb: :delete, scope: %{class: class, id: id}}]}
    end
  end

  defp req_delete_record(_), do: {:error, "delete_record requires an id"}

  defp lookup_class(nil), do: nil

  defp lookup_class(id) do
    case Egghead.get_record(id) do
      {:ok, record} -> to_string(record.class)
      {:error, :not_found} -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp tool_definition(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }
  end

  # --- Tool execution (side effects) ---

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

  defp do_execute("create_record", input, ctx) do
    attrs =
      input
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.put_new("author", ctx[:agent_id])
      |> dissolve_agent_access_attrs(input["class"], :create)

    case Egghead.create_record(attrs) do
      {:ok, record} -> {:ok, "Created record: #{record.id}"}
      {:error, :already_exists} -> {:error, "Record already exists: #{attrs["id"]}"}
      {:error, reason} -> {:error, "Failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("web_fetch", input, _ctx) do
    Egghead.Tool.WebFetch.run(input)
  end

  defp do_execute("shell_exec", input, ctx) do
    on_output = Map.get(ctx, :on_tool_output)
    Egghead.Tool.ShellExec.run(input, on_output: on_output)
  end

  defp do_execute("fs_read", input, _ctx) do
    Egghead.Tool.FS.read(input)
  end

  defp do_execute("fs_write", input, _ctx) do
    Egghead.Tool.FS.write(input)
  end

  defp do_execute("fs_grep", input, _ctx) do
    Egghead.Tool.FS.grep(input)
  end

  defp do_execute("update_record", %{"id" => id} = input, ctx) do
    attrs =
      input
      |> Map.delete("id")
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> dissolve_agent_access_attrs(lookup_class(id), :update)

    # If a browser has this doc open and we're changing the body,
    # stream the edit through the CRDT so the user sees live typing.
    agent_id = ctx[:agent_id]

    if agent_id && Map.has_key?(attrs, "body") && Egghead.Doc.Server.alive?(id) do
      Egghead.Doc.Server.agent_edit(id, agent_id, attrs["body"])
      {:ok, "Updating record: #{id} (live edit in progress)"}
    else
      case Egghead.update_record(id, attrs) do
        {:ok, record} -> {:ok, "Updated record: #{record.id}"}
        {:error, :not_found} -> {:error, "Record not found: #{id}"}
        {:error, reason} -> {:error, "Failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_execute("delete_record", %{"id" => id}, _ctx) do
    case Egghead.trash_record(id) do
      {:ok, trash_path} -> {:ok, "Moved #{id} to trash: #{trash_path}"}
      {:error, :not_found} -> {:error, "Record not found: #{id}"}
      {:error, reason} -> {:error, "Failed to trash record: #{inspect(reason)}"}
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
    refs = Egghead.Record.references(record)

    extra_meta_lines =
      (record.meta || %{})
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "#{k}: #{format_meta_value(v)}" end)

    meta =
      [
        "id: #{record.id}",
        if(record.title, do: "title: #{record.title}"),
        if(record.author, do: "author: #{record.author}"),
        "class: #{record.class}",
        if(record.tags != [], do: "tags: #{Enum.join(record.tags, ", ")}"),
        if(refs != [], do: "links: #{Enum.join(refs, ", ")}")
      ]
      |> Enum.concat(extra_meta_lines)
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

  # Render a meta value for inclusion in the record preview. Scalars
  # print as-is; lists use a compact inline form; maps JSON-encode.
  defp format_meta_value(v) when is_binary(v), do: v
  defp format_meta_value(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)

  defp format_meta_value(v) when is_list(v) do
    if Enum.all?(v, &scalar_meta?/1) do
      "[" <> Enum.map_join(v, ", ", &to_string/1) <> "]"
    else
      Jason.encode!(v)
    end
  end

  defp format_meta_value(v) when is_map(v), do: Jason.encode!(v)
  defp format_meta_value(v), do: inspect(v)

  defp scalar_meta?(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_atom(v), do: true
  defp scalar_meta?(_), do: false
end
