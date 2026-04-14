defmodule Egghead.RecordSupervisor do
  @moduledoc """
  Supervisor for the record store layer: Index + RecordStore.

  Independent of the LLM/agent layer. If the LLM Registry crashes,
  the record store keeps running.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    records_dir = Keyword.fetch!(opts, :records_dir)
    skills_dir = Keyword.get(opts, :skills_dir)
    db_path = Keyword.fetch!(opts, :db_path)

    children = [
      {Egghead.Index, db_path: db_path},
      {Egghead.RecordStore, records_dir: records_dir, skills_dir: skills_dir}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
