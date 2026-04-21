defmodule Egghead.Theme do
  @moduledoc """
  TUI theme catalogue — built-in themes plus user-authored
  overrides, applied to the framework-level
  `Egghead.OpenTUI.Theme`.

  ## Built-ins

  Eight themes ship with Egghead. Full list: `builtins/0`.

  Default on first launch is `terminal-dark`: both backgrounds
  transparent, neutral off-white fg. It inherits whatever the
  host terminal is already styled with, so the TUI drops into any
  setup cleanly.

  ## User themes

  Drop JSON files into `~/.config/egghead/themes/*.json` to add
  custom themes. Schema:

      {
        "name": "my-theme",
        "display_name": "My Theme",
        "mode": "dark",
        "use_terminal_bg": false,
        "palette": {
          "bg": "#1e1e2e",
          "fg": "#cdd6f4",
          "accent": "#89b4fa"
        }
      }

  Missing palette slots inherit from the built-in default for the
  same `mode` (`terminal-dark` for dark, `scholastic` for light).
  Hex strings are `#rrggbb` or `#rrggbbaa` — anything else is
  rejected at parse time.

  `use_terminal_bg: true` forces `bg` and `bg_alt` to transparent
  regardless of what the palette maps them to, letting the
  terminal's own background show through.

  ## Runtime

  `set/1` validates, installs the palette into
  `Egghead.OpenTUI.Theme`, flushes the markdown render cache
  (cached rows bake in fg binaries), and broadcasts
  `{:theme_changed, name}` on `Egghead.PubSub` so live views
  can repaint.
  """

  alias Egghead.OpenTUI.Theme, as: FwTheme
  alias Egghead.TUI.MarkdownCache

  require Logger

  @enforce_keys [:name, :display_name, :mode, :palette]
  defstruct [:name, :display_name, :mode, :palette, use_terminal_bg: false]

  @type mode :: :dark | :light
  @type slot :: FwTheme.slot()

  @type t :: %__MODULE__{
          name: String.t(),
          display_name: String.t(),
          mode: mode(),
          use_terminal_bg: boolean(),
          palette: %{slot() => binary() | :transparent}
        }

  @pubsub Egghead.PubSub
  @topic "theme"

  # ---- Public API ---------------------------------------------------------

  @doc "Built-in catalogue in display order."
  @spec builtins() :: [t()]
  def builtins, do: Egghead.Theme.Builtins.all()

  @doc """
  Load user themes from `~/.config/egghead/themes/*.json`. Invalid
  files are skipped with a warning; the rest load.
  """
  @spec load_user_themes() :: [t()]
  def load_user_themes do
    dir = user_themes_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.flat_map(fn file ->
          path = Path.join(dir, file)

          case load_user_theme(path) do
            {:ok, theme} ->
              [theme]

            {:error, reason} ->
              Logger.warning("skipping theme file #{path}: #{inspect(reason)}")
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Combined catalogue: built-ins then user themes. User name collisions override built-ins."
  @spec list() :: [t()]
  def list do
    users = load_user_themes()
    user_names = MapSet.new(users, & &1.name)
    filtered_builtins = Enum.reject(builtins(), &MapSet.member?(user_names, &1.name))
    filtered_builtins ++ users
  end

  @doc "Look up a theme by name."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, :not_found}
  def fetch(name) when is_binary(name) do
    case Enum.find(list(), &(&1.name == name)) do
      nil -> {:error, :not_found}
      theme -> {:ok, theme}
    end
  end

  @doc """
  Install the named theme. Returns `:ok` on success or
  `{:error, :not_found}` if the name is unknown. Broadcasts
  `{:theme_changed, name}` on `Egghead.PubSub` topic `"theme"`.

  This only paints — it doesn't persist. The picker uses it
  every Up/Down arrow for live preview without moving the
  committed-theme marker or rewriting config. Call
  `commit/1` to make the change durable.
  """
  @spec set(String.t()) :: :ok | {:error, :not_found}
  def set(name) when is_binary(name) do
    with {:ok, theme} <- fetch(name) do
      FwTheme.set(resolve_palette(theme))
      MarkdownCache.reset()
      safe_broadcast(name)
      :ok
    end
  end

  @doc """
  Persist the named theme to config and install it. Unlike
  `set/1` this also writes to `~/.config/egghead/config.yml`
  and updates the in-memory config snapshot so
  `committed_name/0` reflects the change on the next read.
  """
  @spec commit(String.t()) :: :ok | {:error, term()}
  def commit(name) when is_binary(name) do
    with :ok <- set(name) do
      try do
        Egghead.Config.set("theme", name)
      catch
        _, _ -> :ok
      end

      put_committed_in_env(name)
      :ok
    end
  end

  @doc """
  The theme that has been persisted to config — the one whose
  row carries the committed marker in the picker. Distinct
  from the currently-painted palette, which can be a live
  preview while the user is arrowing through the picker.
  """
  @spec committed_name() :: String.t()
  def committed_name do
    case Application.get_env(:egghead, :config) do
      %{theme: name} when is_binary(name) and name != "" -> name
      _ -> default_name()
    end
  end

  @doc "The default theme used on first launch or when the configured theme is unknown."
  @spec default_name() :: String.t()
  def default_name, do: "terminal-dark"

  @doc "Topic string for PubSub subscribers that want theme change notifications."
  def topic, do: @topic

  # ---- Internals ----------------------------------------------------------

  defp resolve_palette(%__MODULE__{use_terminal_bg: true, palette: palette}) do
    palette
    |> Map.put(:bg, :transparent)
    |> Map.put(:bg_alt, :transparent)
  end

  defp resolve_palette(%__MODULE__{palette: palette}), do: palette

  defp put_committed_in_env(name) do
    config =
      case Application.get_env(:egghead, :config) do
        %Egghead.Config{} = c -> %{c | theme: name}
        other when is_map(other) -> Map.put(other, :theme, name)
        _ -> %Egghead.Config{theme: name}
      end

    Application.put_env(:egghead, :config, config)
  end

  defp user_themes_dir do
    Path.join(Egghead.Config.config_dir(), "themes")
  end

  defp load_user_theme(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw),
         {:ok, theme} <- parse_user_theme(json) do
      {:ok, theme}
    end
  end

  defp parse_user_theme(%{"name" => name, "palette" => palette} = json)
       when is_binary(name) and is_map(palette) do
    with mode when mode in [:dark, :light] <- parse_mode(json["mode"]),
         {:ok, resolved_palette} <- parse_palette(palette, mode) do
      {:ok,
       %__MODULE__{
         name: name,
         display_name: json["display_name"] || name,
         mode: mode,
         use_terminal_bg: json["use_terminal_bg"] == true,
         palette: resolved_palette
       }}
    else
      :invalid_mode -> {:error, {:bad_mode, json["mode"]}}
      {:error, _} = err -> err
    end
  end

  defp parse_user_theme(_), do: {:error, :missing_name_or_palette}

  defp parse_mode("dark"), do: :dark
  defp parse_mode("light"), do: :light
  defp parse_mode(_), do: :invalid_mode

  defp parse_palette(palette, mode) do
    base_palette = base_for_mode(mode)

    Enum.reduce_while(palette, {:ok, base_palette}, fn {key, hex}, {:ok, acc} ->
      with {:ok, slot} <- slot_from_string(key),
           {:ok, rgba} <- parse_hex(hex) do
        {:cont, {:ok, Map.put(acc, slot, rgba)}}
      else
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end

  defp base_for_mode(:dark) do
    case Enum.find(builtins(), &(&1.name == "terminal-dark")) do
      nil -> %{}
      theme -> theme.palette
    end
  end

  defp base_for_mode(:light) do
    case Enum.find(builtins(), &(&1.name == "scholastic")) do
      nil -> %{}
      theme -> theme.palette
    end
  end

  defp slot_from_string(key) when is_binary(key) do
    # Only accept known slot names — never create atoms from user
    # input.
    slots = FwTheme.slots()
    target = String.to_atom(key)

    if target in slots do
      {:ok, target}
    else
      {:error, :unknown_slot}
    end
  rescue
    ArgumentError -> {:error, :unknown_slot}
  end

  defp slot_from_string(_), do: {:error, :unknown_slot}

  defp parse_hex("#" <> rest) when byte_size(rest) == 6 do
    with {r, ""} <- Integer.parse(String.slice(rest, 0, 2), 16),
         {g, ""} <- Integer.parse(String.slice(rest, 2, 2), 16),
         {b, ""} <- Integer.parse(String.slice(rest, 4, 2), 16) do
      {:ok, rgba(r / 255, g / 255, b / 255, 1.0)}
    else
      _ -> {:error, :bad_hex}
    end
  end

  defp parse_hex("#" <> rest) when byte_size(rest) == 8 do
    with {r, ""} <- Integer.parse(String.slice(rest, 0, 2), 16),
         {g, ""} <- Integer.parse(String.slice(rest, 2, 2), 16),
         {b, ""} <- Integer.parse(String.slice(rest, 4, 2), 16),
         {a, ""} <- Integer.parse(String.slice(rest, 6, 2), 16) do
      {:ok, rgba(r / 255, g / 255, b / 255, a / 255)}
    else
      _ -> {:error, :bad_hex}
    end
  end

  defp parse_hex(_), do: {:error, :bad_hex}

  defp rgba(r, g, b, a) do
    <<r::float-32-little, g::float-32-little, b::float-32-little, a::float-32-little>>
  end

  defp safe_broadcast(name) do
    try do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:theme_changed, name})
    catch
      _, _ -> :ok
    end
  end
end
