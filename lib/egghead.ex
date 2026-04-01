defmodule Egghead do
  @moduledoc """
  Egghead — a consultable record store with agent perspectives.

  This module provides the public API for interacting with the Record Store.
  Delegates to `Egghead.RecordStore` for all operations.
  """

  alias Egghead.Record
  alias Egghead.RecordStore

  @doc """
  Creates a new record in the store.

  ## Attributes

    * `:id` — record identifier (auto-generated if omitted)
    * `:title` — record title
    * `:author` — who created it
    * `:tags` — list of tag strings
    * `:links` — list of linked record ids
    * `:class` — `:durable`, `:inbox`, or `:deliberation` (default: `:durable`)
    * `:body` — the record body text
  """
  @spec create_record(map()) :: {:ok, Record.t()} | {:error, term()}
  defdelegate create_record(attrs), to: RecordStore

  @doc """
  Updates an existing record.
  """
  @spec update_record(String.t(), map()) :: {:ok, Record.t()} | {:error, term()}
  defdelegate update_record(id, attrs), to: RecordStore

  @doc """
  Gets a record by id, hydrated with full body and AST from disk.
  """
  @spec get_record(String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  defdelegate get_record(id), to: RecordStore

  @doc """
  Lists all records (lightweight, no body/ast).
  """
  @spec list_records() :: [Record.t()]
  defdelegate list_records(), to: RecordStore

  @doc """
  Finds records tagged with the given tag.
  """
  @spec search_by_tag(String.t()) :: [Record.t()]
  defdelegate search_by_tag(tag), to: RecordStore

  @doc """
  Finds records of the given class.
  """
  @spec search_by_class(Record.class()) :: [Record.t()]
  defdelegate search_by_class(class), to: RecordStore

  @doc """
  Traverses the link graph from a record, up to `depth` levels.
  """
  @spec find_links(String.t(), non_neg_integer()) :: [Record.t()]
  def find_links(id, depth \\ 1), do: RecordStore.find_links(RecordStore, id, depth)

  @doc """
  Finds records that link TO the given id (reverse graph / backlinks).
  """
  @spec find_backlinks(String.t()) :: [Record.t()]
  defdelegate find_backlinks(id), to: RecordStore

  @doc """
  Full-text search across record titles and bodies.
  """
  @spec search(String.t(), keyword()) :: [Record.t()]
  def search(query, opts \\ []), do: RecordStore.search(RecordStore, query, opts)

  @doc """
  Returns recently modified or created records.
  """
  @spec recent(keyword()) :: [Record.t()]
  def recent(opts \\ []), do: RecordStore.recent(RecordStore, opts)

  # --- Agent API ---

  @doc """
  Sends a prompt to a named agent. Returns `{:ok, %Egghead.Agent.Response{}}`.

  The response includes the text, token usage, tool calls made, records
  created/updated, model info, and timing.

  ## Options

    * `:on_chunk` — callback for streaming: `fn {:text, chunk} -> IO.write(chunk) end`
    * `:max_tokens`, `:temperature` — LLM parameters
  """
  @spec prompt(String.t(), String.t(), keyword()) ::
          {:ok, Egghead.Agent.Response.t()} | {:error, term()}
  defdelegate prompt(agent_id, message, opts \\ []), to: Egghead.Agent

  @doc """
  Lists all running agents with their capabilities and usage.
  """
  @spec list_agents() :: [map()]
  defdelegate list_agents(), to: Egghead.Agent

  @doc """
  Clears an agent's conversation history.
  """
  @spec clear_history(String.t()) :: :ok | {:error, :agent_not_found}
  defdelegate clear_history(agent_id), to: Egghead.Agent

  @doc """
  Handoff: summarize conversation to a deliberation record and optionally
  continue with a new prompt. Returns `{:ok, deliberation_id}`.
  """
  @spec handoff(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  defdelegate handoff(agent_id, next_prompt \\ nil), to: Egghead.Agent

  @doc """
  Save: ask the agent to extract key insights from the conversation
  and create durable records. Does not clear the session.
  """
  @spec save_insights(String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate save_insights(agent_id), to: Egghead.Agent, as: :save

  @doc """
  Returns an agent's token usage and context info.
  """
  @spec agent_usage(String.t()) :: {:ok, map()} | {:error, :agent_not_found}
  defdelegate agent_usage(agent_id), to: Egghead.Agent, as: :usage

  # --- Provider API ---

  @doc """
  Lists configured LLM providers.
  """
  @spec list_providers() :: [map()]
  defdelegate list_providers(), to: Egghead.LLM.Registry

  @doc """
  Lists available models across all configured providers.
  """
  @spec list_models() :: [map()]
  defdelegate list_models(), to: Egghead.LLM.Registry

  # --- Chat API ---

  @doc """
  Creates a chat room and returns the room id.
  """
  @spec create_room(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_room(opts \\ []) do
    id =
      Keyword.get(
        opts,
        :id,
        "chat-#{Date.to_iso8601(Date.utc_today())}-#{:erlang.unique_integer([:positive])}"
      )

    round_budget = Keyword.get(opts, :round_budget, 5)
    is_default = Keyword.get(opts, :default, false)

    case Egghead.Chat.Room.start_link(id: id, round_budget: round_budget) do
      {:ok, _pid} ->
        Enum.each(list_agents(), fn agent ->
          Egghead.Chat.Room.join(id, agent.id)

          Egghead.Chat.Coordinator.register_agent(agent.id, %{
            name: agent.name,
            capabilities: agent.capabilities
          })
        end)

        Egghead.Chat.Coordinator.watch_room(id)

        if is_default do
          :persistent_term.put(:egghead_default_room, id)
        end

        {:ok, id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the default room id.
  """
  @spec default_room() :: String.t() | nil
  def default_room do
    try do
      :persistent_term.get(:egghead_default_room)
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Sends a message to a chat room. The coordinator decides which agents respond.
  Defaults to the default room if no room_id given.
  """
  @spec chat(String.t(), String.t()) :: :ok
  def chat(room_id \\ default_room(), message) do
    sender = System.get_env("USER") || "human"
    Egghead.Chat.Room.send_message(room_id, sender, message)
  end

  @doc """
  Watch a chat room — prints messages to stdout as they arrive.
  With no argument, watches the default room.
  """
  @spec watch(String.t()) :: pid()
  def watch(room_id \\ default_room()) do
    Egghead.Chat.Watcher.start(room_id)
  end

  @doc """
  Gets the chat room transcript.
  """
  @spec chat_transcript(String.t()) :: [map()]
  def chat_transcript(room_id \\ default_room()) do
    Egghead.Chat.Room.get_transcript(room_id)
  end

  @doc """
  Grants more turns in a chat room (like /continue).
  """
  @spec chat_continue(String.t()) :: :ok
  def chat_continue(room_id \\ default_room()) do
    Egghead.Chat.Room.continue(room_id)
  end
end
