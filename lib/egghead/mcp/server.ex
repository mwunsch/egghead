defmodule Egghead.MCP.Server do
  @moduledoc """
  MCP server with stdio transport.

  Reads JSON-RPC messages from stdin, dispatches to `Egghead.MCP.Handler`,
  writes responses to stdout. Each message is a single line of JSON.

  ## Usage

      mix run --no-halt -e "Egghead.MCP.Server.start()"
  """

  alias Egghead.MCP.Handler

  @doc """
  Starts the MCP stdio loop. Blocks indefinitely, reading from stdin.
  Ensures the Egghead application is started first.
  """
  def start do
    {:ok, _} = Application.ensure_all_started(:egghead)
    loop()
  end

  defp loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line |> String.trim() |> handle_line()
        loop()
    end
  end

  defp handle_line(""), do: :ok

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, msg} ->
        case Handler.handle(msg) do
          :noreply -> :ok
          response -> send_response(response)
        end

      {:error, _} ->
        send_response(%{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: -32700, message: "Parse error"}
        })
    end
  end

  defp send_response(msg) do
    IO.write(:stdio, Jason.encode!(msg) <> "\n")
  end
end
