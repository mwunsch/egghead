defmodule Mix.Tasks.Tui.Records do
  @moduledoc """
  Developer entry point for the records-list screen with an
  override for `:records_dir`. The canonical user-facing entry
  is `mix egghead.tui`; this task exists so the screen can be
  driven against an arbitrary records dir without modifying app
  config:

      EGGHEAD_RECORDS_DIR=/path/to/records mix tui.records

  Press Esc or Ctrl+C to exit. Refuses to run from IEx because
  IEx owns stdin.
  """

  use Mix.Task

  @shortdoc "Run the OpenTUI records-list screen"

  @impl true
  def run(_args) do
    if iex_started?() do
      Mix.shell().error("""
      mix tui.records cannot run from IEx — IEx owns stdin and the group
      leader, which conflicts with raw-mode terminal input. Run from a
      plain shell:

          mix tui.records
      """)

      System.halt(1)
    end

    if records_dir = System.get_env("EGGHEAD_RECORDS_DIR") do
      Application.put_env(:egghead, :records_dir, records_dir)
    end

    Mix.Task.run("app.start")

    case Egghead.OpenTUI.Runtime.run(Egghead.TUI.Records, []) do
      :ok -> :ok
      _ -> System.halt(1)
    end
  end

  defp iex_started? do
    Code.ensure_loaded?(IEx) and apply(IEx, :started?, [])
  end
end
