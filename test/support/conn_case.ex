defmodule Egghead.Web.ConnCase do
  @moduledoc """
  Test case for Phoenix LiveView tests.

  Starts the endpoint once for all tests. Each test tagged with
  `:records` gets a temporary record store — write fixture files
  to `tmp_dir` in `setup`, then call `start_record_store(tmp_dir)`
  to boot the RecordSupervisor with that directory.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint Egghead.Web.Endpoint

      defp start_record_store(tmp_dir) do
        db_path = Path.join(tmp_dir, ".egghead/index.db")
        File.mkdir_p!(Path.dirname(db_path))

        start_supervised!({Egghead.RecordSupervisor, records_dir: tmp_dir, db_path: db_path})

        # Give the initial scan time to index existing files
        Process.sleep(300)
      end
    end
  end

  setup_all do
    # PubSub is started globally in test_helper.exs
    start_supervised!(Egghead.Web.Endpoint)
    :ok
  end

  setup tags do
    if tags[:records] do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "egghead_web_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, conn: Phoenix.ConnTest.build_conn(), tmp_dir: tmp_dir}
    else
      {:ok, conn: Phoenix.ConnTest.build_conn()}
    end
  end
end
