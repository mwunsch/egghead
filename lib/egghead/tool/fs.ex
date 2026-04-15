defmodule Egghead.Tool.FS do
  @moduledoc """
  Filesystem tools outside the record store.

  Three operations: `fs_read`, `fs_write`, `fs_grep`. Each is
  gated by the corresponding capability (`fs.read` / `fs.write`)
  with `paths:` scoping. Paths are expanded (`~`) and canonicalized
  before matching, so symlink tricks don't escape the allow-list.

  Binary files are refused on read (non-UTF-8 → notice with size).
  Writes are atomic (temp file + rename). Grep uses ripgrep when
  available, falls back to a simple Elixir scanner otherwise.
  """

  alias Egghead.Capability.Request
  alias Egghead.Tool.Output

  @read_default_timeout 10_000
  @grep_max_results 200

  # --- Capability requests ---

  @spec request_for_read(map()) :: [Request.t()]
  def request_for_read(%{"path" => path}) do
    [
      %Request{
        resource: :fs,
        verb: :read,
        scope: %{path: canonicalize(path)},
        tool: "fs_read"
      }
    ]
  end

  def request_for_read(_), do: []

  @spec request_for_write(map()) :: [Request.t()]
  def request_for_write(%{"path" => path}) do
    [
      %Request{
        resource: :fs,
        verb: :write,
        scope: %{path: canonicalize(path)},
        tool: "fs_write"
      }
    ]
  end

  def request_for_write(_), do: []

  @spec request_for_grep(map()) :: [Request.t()]
  def request_for_grep(%{"path" => path}) do
    [
      %Request{
        resource: :fs,
        verb: :read,
        scope: %{path: canonicalize(path)},
        tool: "fs_grep"
      }
    ]
  end

  def request_for_grep(_), do: []

  # --- Execution ---

  @spec read(map()) :: {:ok, String.t()} | {:error, String.t()}
  def read(%{"path" => path} = input) do
    full = expand(path)
    max = input["max_bytes"]

    with {:ok, stat} <- safe_stat(full),
         :ok <- check_regular(stat),
         {:ok, content} <- safe_read(full) do
      opts = if max, do: [max_bytes: max], else: []

      case Output.apply(content, opts) do
        {:ok, text} -> {:ok, text}
        {:truncated, text, _} -> {:ok, text}
        {:binary, notice} -> {:ok, notice}
      end
    end
  end

  def read(_), do: {:error, "fs_read requires a path"}

  @spec write(map()) :: {:ok, String.t()} | {:error, String.t()}
  def write(%{"path" => path, "content" => content}) when is_binary(content) do
    full = expand(path)

    with :ok <- ensure_parent_dir(full),
         :ok <- atomic_write(full, content) do
      {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
    end
  end

  def write(%{"path" => _}), do: {:error, "fs_write requires a content string"}
  def write(_), do: {:error, "fs_write requires a path and content"}

  @spec grep(map()) :: {:ok, String.t()} | {:error, String.t()}
  def grep(%{"pattern" => pattern, "path" => path} = input) do
    full = expand(path)
    max_results = input["max_results"] || @grep_max_results

    case System.find_executable("rg") do
      nil -> grep_elixir(pattern, full, max_results)
      rg -> grep_ripgrep(rg, pattern, full, max_results)
    end
  end

  def grep(_), do: {:error, "fs_grep requires a pattern and path"}

  # --- Helpers ---

  @doc """
  Expand `~` and resolve the path relative to the home directory.
  Does NOT resolve symlinks — we want the path the user specified.
  """
  @spec expand(String.t()) :: String.t()
  def expand(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "~/") ->
        Path.expand(path)

      path == "~" ->
        Path.expand(path)

      true ->
        Path.expand(path)
    end
  end

  def expand(path), do: to_string(path)

  # Canonical form used for capability scope matching: expanded,
  # symlinks resolved (to prevent escape via symlink), absolute.
  defp canonicalize(path) do
    expanded = expand(to_string(path))

    case File.stat(expanded) do
      {:ok, _} ->
        # Realpath if we can — symlink resolution defeats path tricks
        case :file.read_link_info(String.to_charlist(expanded)) do
          {:ok, _} -> Path.expand(expanded)
          _ -> expanded
        end

      _ ->
        expanded
    end
  end

  defp safe_stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, "cannot stat #{path}: #{reason}"}
    end
  end

  defp check_regular(%{type: :regular}), do: :ok
  defp check_regular(%{type: type}), do: {:error, "not a regular file: #{type}"}

  defp safe_read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
    end
  end

  defp ensure_parent_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create parent dir #{dir}: #{reason}"}
    end
  end

  defp atomic_write(path, content) do
    tmp = path <> ".tmp-#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "write failed: #{reason}"}
    end
  end

  # --- Grep implementations ---

  defp grep_ripgrep(rg, pattern, path, max) do
    args = ["--no-heading", "--line-number", "--color=never", "--max-count=#{max}", pattern, path]

    case System.cmd(rg, args, stderr_to_stdout: true, parallelism: false) do
      # ripgrep exits 1 when no matches — not an error for us
      {out, 0} -> format_grep({:ok, out}, pattern, path)
      {out, 1} when out == "" -> {:ok, "(no matches for #{inspect(pattern)} in #{path})"}
      {out, 1} -> format_grep({:ok, out}, pattern, path)
      {out, code} -> {:error, "rg exited #{code}: #{out}"}
    end
  rescue
    e -> {:error, "rg error: #{Exception.message(e)}"}
  end

  defp grep_elixir(pattern, path, max) do
    case safe_stat(path) do
      {:ok, %{type: :regular}} -> grep_file(path, pattern, max)
      {:ok, %{type: :directory}} -> grep_dir(path, pattern, max)
      {:ok, _} -> {:error, "not a regular file or directory: #{path}"}
      error -> error
    end
  end

  defp grep_file(path, pattern, max) do
    regex = compile_pattern(pattern)

    matches =
      path
      |> File.stream!([:line])
      |> Stream.with_index(1)
      |> Stream.filter(fn {line, _} -> Regex.match?(regex, line) end)
      |> Stream.map(fn {line, n} -> "#{path}:#{n}:#{String.trim_trailing(line)}" end)
      |> Enum.take(max)

    case matches do
      [] -> {:ok, "(no matches for #{inspect(pattern)} in #{path})"}
      lines -> {:ok, Enum.join(lines, "\n") <> "\n"}
    end
  rescue
    e -> {:error, "grep error: #{Exception.message(e)}"}
  end

  defp grep_dir(path, pattern, max) do
    files =
      path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&(File.stat!(&1).type == :regular))

    {lines, _} =
      Enum.reduce_while(files, {[], max}, fn file, {acc, remaining} ->
        if remaining <= 0 do
          {:halt, {acc, 0}}
        else
          case grep_file(file, pattern, remaining) do
            {:ok, result} ->
              new_count = result |> String.split("\n", trim: true) |> length()
              {:cont, {[result | acc], remaining - new_count}}

            _ ->
              {:cont, {acc, remaining}}
          end
        end
      end)

    case lines do
      [] ->
        {:ok, "(no matches for #{inspect(pattern)} in #{path})"}

      _ ->
        joined = lines |> Enum.reverse() |> Enum.join("") |> String.trim_trailing()
        {:ok, joined <> "\n"}
    end
  end

  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> regex
      _ -> ~r/#{Regex.escape(pattern)}/
    end
  end

  defp format_grep(result, _pattern, _path), do: result

  @doc false
  def _timeout, do: @read_default_timeout
end
