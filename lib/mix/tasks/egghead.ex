defmodule Mix.Tasks.Egghead do
  @moduledoc "Bridge to `Egghead.CLI.main/1`. The only Mix task."
  use Mix.Task
  @shortdoc "Run the egghead CLI"
  @requirements []
  @impl true
  def run(args), do: Egghead.CLI.main(args)
end
