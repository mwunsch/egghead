defmodule Egghead.TUI.Chat.RosterMembershipTest do
  @moduledoc """
  Regression: the TUI chat sidebar must mirror the *room's* roster, not
  the global agent registry. Idle agents not invited into the current
  room should NOT render in the chat-roster panel — otherwise the UI
  contradicts what `idle: true` claims (the agent is on the bench, not
  in the room).
  """

  use ExUnit.Case

  alias Egghead.Agent
  alias Egghead.Chat.Room
  alias Egghead.Record
  alias Egghead.TUI.Chat.Model

  setup_all do
    case Phoenix.PubSub.Supervisor.start_link(name: Egghead.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp start_agent_record(id, meta) do
    record = %Record{
      id: id,
      title: id |> String.split("/") |> List.last() |> String.capitalize(),
      class: :agent,
      tags: [],
      meta: Map.merge(%{"capabilities" => ["records.read"]}, meta),
      body: "Test agent.",
      source_path: nil
    }

    {:ok, pid} = Agent.start_link(record)
    on_exit_stop(pid)
    id
  end

  defp on_exit_stop(pid) do
    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        _, _ -> :ok
      end
    end)
  end

  describe "Model.hydrate_agents/1 with a room" do
    test "excludes agents that are not joined to the room (idle case)" do
      tag = :erlang.unique_integer([:positive])
      noisy = start_agent_record("test-noisy-#{tag}", %{})
      idle = start_agent_record("test-idle-#{tag}", %{"idle" => true})

      room_id = "roster-test-#{tag}"
      {:ok, _pid} = Room.start_link(id: room_id)
      on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

      Room.join(room_id, noisy)

      ids =
        room_id
        |> Model.hydrate_agents()
        |> Enum.map(& &1.id)

      assert noisy in ids,
             "the joined agent should appear in the sidebar; got #{inspect(ids)}"

      refute idle in ids,
             "an idle agent NOT joined to the room must not render in " <>
               "the sidebar — that would lie about room membership; " <>
               "got #{inspect(ids)}"
    end

    test "an explicitly invited idle agent DOES render in the sidebar" do
      tag = :erlang.unique_integer([:positive])
      idle = start_agent_record("test-idle-invited-#{tag}", %{"idle" => true})

      room_id = "roster-invite-test-#{tag}"
      {:ok, _pid} = Room.start_link(id: room_id)
      on_exit(fn -> if Room.exists?(room_id), do: Room.stop(room_id) end)

      Room.join(room_id, idle)

      ids =
        room_id
        |> Model.hydrate_agents()
        |> Enum.map(& &1.id)

      assert idle in ids,
             "an idle agent that was invited via /invite must render; " <>
               "the sidebar mirrors actual membership in either direction"
    end
  end
end
