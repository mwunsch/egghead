defmodule Egghead.Tool.FSTest do
  use ExUnit.Case, async: true

  alias Egghead.Tool.FS

  defp tmp_file(prefix, content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{:erlang.unique_integer([:positive])}.txt"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "request_for_read/1" do
    test "builds an fs.read request with path in scope" do
      [req] = FS.request_for_read(%{"path" => "/tmp/foo.md"})
      assert req.resource == :fs
      assert req.verb == :read
      assert req.scope.path == "/tmp/foo.md"
    end
  end

  describe "request_for_write/1" do
    test "builds an fs.write request" do
      [req] = FS.request_for_write(%{"path" => "/tmp/foo.md"})
      assert req.resource == :fs
      assert req.verb == :write
    end
  end

  describe "read/1" do
    test "reads a text file" do
      path = tmp_file("fs-read", "hello world\n")
      assert {:ok, "hello world\n"} = FS.read(%{"path" => path})
    end

    test "non-existent file returns error" do
      assert {:error, _} = FS.read(%{"path" => "/tmp/does-not-exist-#{System.unique_integer()}"})
    end

    test "binary file returns a notice, not bytes" do
      path = tmp_file("fs-bin", <<0xFF, 0xFE, 0xFD, 0xFC>>)
      assert {:ok, notice} = FS.read(%{"path" => path})
      assert notice =~ "non-text"
    end
  end

  describe "write/1" do
    test "atomic write creates the file with the content" do
      path =
        Path.join(
          System.tmp_dir!(),
          "fs-write-#{:erlang.unique_integer([:positive])}.txt"
        )

      on_exit(fn -> File.rm(path) end)

      assert {:ok, _} = FS.write(%{"path" => path, "content" => "hello\n"})
      assert File.read!(path) == "hello\n"
    end

    test "creates intermediate directories" do
      base = Path.join(System.tmp_dir!(), "fs-subdir-#{:erlang.unique_integer([:positive])}")
      nested = Path.join([base, "a", "b", "c.txt"])
      on_exit(fn -> File.rm_rf(base) end)

      assert {:ok, _} = FS.write(%{"path" => nested, "content" => "x"})
      assert File.read!(nested) == "x"
    end
  end

  describe "grep/1" do
    test "finds matching lines" do
      path = tmp_file("fs-grep", "first line\nsecond match here\nthird line\n")
      assert {:ok, result} = FS.grep(%{"pattern" => "match", "path" => path})
      assert result =~ "second match here"
    end

    test "no matches returns a helpful notice" do
      path = tmp_file("fs-grep-empty", "no content of interest\n")
      assert {:ok, result} = FS.grep(%{"pattern" => "xyzzy", "path" => path})
      assert result =~ "no matches"
    end
  end
end
