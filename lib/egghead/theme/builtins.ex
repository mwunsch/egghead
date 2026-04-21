defmodule Egghead.Theme.Builtins do
  @moduledoc """
  Built-in theme catalogue.

  Palettes are authored in hex and converted to 16-byte RGBA
  binaries at compile time. Call `all/0` to get the display-
  ordered list.
  """

  alias Egghead.Theme

  @doc "All built-in themes in display order."
  @spec all() :: [Theme.t()]
  def all do
    [
      terminal_dark(),
      terminal_light(),
      scholastic(),
      dos(),
      hot_dog_stand(),
      catppuccin_mocha(),
      solarized_light(),
      gruvbox_dark()
    ]
  end

  # ---- terminal-dark -------------------------------------------------------
  # Default. Transparent backgrounds → terminal's own bg bleeds through.
  # A neutral off-white fg and a warm accent set keep the TUI legible on
  # any dark scheme.

  defp terminal_dark do
    %Theme{
      name: "terminal-dark",
      display_name: "Terminal Default (Dark)",
      mode: :dark,
      use_terminal_bg: true,
      palette: %{
        bg: :transparent,
        bg_alt: :transparent,
        fg: hex("#dcdcdc"),
        fg_dim: hex("#9a9a9a"),
        fg_muted: hex("#6e6e6e"),
        selection_bg: hex("#3a4660"),
        accent: hex("#7aa2f7"),
        border: hex("#3b3b44"),
        error: hex("#e06c75"),
        warning: hex("#e5c07b"),
        success: hex("#98c379"),
        info: hex("#56b6c2"),
        syntax_heading: hex("#e5c07b"),
        syntax_link: hex("#61afef"),
        syntax_code: hex("#c0caf5"),
        syntax_keyword: hex("#c678dd"),
        syntax_string: hex("#98c379")
      }
    }
  end

  # ---- terminal-light ------------------------------------------------------

  defp terminal_light do
    %Theme{
      name: "terminal-light",
      display_name: "Terminal Default (Light)",
      mode: :light,
      use_terminal_bg: true,
      palette: %{
        bg: :transparent,
        bg_alt: :transparent,
        fg: hex("#1f1f1f"),
        fg_dim: hex("#555555"),
        fg_muted: hex("#7a7a7a"),
        selection_bg: hex("#c7d2e8"),
        accent: hex("#2a5bd7"),
        border: hex("#b5b5b5"),
        error: hex("#b12a3b"),
        warning: hex("#a36d00"),
        success: hex("#2d7a2d"),
        info: hex("#1e6f9f"),
        syntax_heading: hex("#7a4a00"),
        syntax_link: hex("#1f4fc2"),
        syntax_code: hex("#3b3b3b"),
        syntax_keyword: hex("#6f2daa"),
        syntax_string: hex("#2d7a2d")
      }
    }
  end

  # ---- scholastic ----------------------------------------------------------
  # Warm cream paper and deep ink. Matches the site's Utopian
  # Scholastic CSS.

  defp scholastic do
    %Theme{
      name: "scholastic",
      display_name: "Scholastic",
      mode: :light,
      use_terminal_bg: false,
      palette: %{
        bg: hex("#f4f1ea"),
        bg_alt: hex("#ece6d8"),
        fg: hex("#111111"),
        fg_dim: hex("#444444"),
        fg_muted: hex("#6b5e47"),
        selection_bg: hex("#dfd3b8"),
        accent: hex("#8b2e1a"),
        border: hex("#bcae92"),
        error: hex("#8b1e1e"),
        warning: hex("#8a6d1a"),
        success: hex("#2f5d3a"),
        info: hex("#2a4d6e"),
        syntax_heading: hex("#5a2a0c"),
        syntax_link: hex("#2a4d6e"),
        syntax_code: hex("#3b3630"),
        syntax_keyword: hex("#6b2350"),
        syntax_string: hex("#2f5d3a")
      }
    }
  end

  # ---- dos -----------------------------------------------------------------
  # Norton Commander / WordPerfect 5.1 / BIOS setup — dark IBM
  # blue primary, teal secondary surfaces, grey text tiers,
  # yellow for focused highlights. No neons; the 16-color EGA
  # palette dimmed into something cohesive.

  defp dos do
    %Theme{
      name: "dos",
      display_name: "DOS BIOS",
      mode: :dark,
      use_terminal_bg: false,
      palette: %{
        bg: hex("#0a1f5c"),
        bg_alt: hex("#0d6b6b"),
        fg: hex("#e5e5e5"),
        fg_dim: hex("#bcbcbc"),
        fg_muted: hex("#8a8a8a"),
        selection_bg: hex("#0d6b6b"),
        accent: hex("#ffd400"),
        border: hex("#8a8a8a"),
        error: hex("#d96b6b"),
        warning: hex("#ffd400"),
        success: hex("#7ac97a"),
        info: hex("#7dd3d3"),
        syntax_heading: hex("#ffd400"),
        syntax_link: hex("#7dd3d3"),
        syntax_code: hex("#d0d0d0"),
        syntax_keyword: hex("#e8a8e8"),
        syntax_string: hex("#9dd49d")
      }
    }
  end

  # ---- hot-dog-stand -------------------------------------------------------
  # Windows 3.1, 1991. Yellow on red. Black accents. Eye-searing
  # and completely uncompromising.

  # Windows 3.1, 1991. Yellow on red everywhere — the bg_alt rail
  # stays red (slightly darkened) so yellow fg never ends up on
  # yellow surface and vanishes. Black is reserved for highlights
  # and selection so the palette still reads as Hot Dog Stand.
  defp hot_dog_stand do
    %Theme{
      name: "hot-dog-stand",
      display_name: "Hot Dog Stand",
      mode: :light,
      use_terminal_bg: false,
      palette: %{
        bg: hex("#ff0000"),
        bg_alt: hex("#cc0000"),
        fg: hex("#ffff00"),
        fg_dim: hex("#ffcc00"),
        fg_muted: hex("#ff9999"),
        selection_bg: hex("#000000"),
        accent: hex("#ffff00"),
        border: hex("#000000"),
        error: hex("#000000"),
        warning: hex("#ffff00"),
        success: hex("#ffff00"),
        info: hex("#ffff00"),
        syntax_heading: hex("#000000"),
        syntax_link: hex("#000000"),
        syntax_code: hex("#000000"),
        syntax_keyword: hex("#000000"),
        syntax_string: hex("#000000")
      }
    }
  end

  # ---- catppuccin-mocha ----------------------------------------------------

  defp catppuccin_mocha do
    %Theme{
      name: "catppuccin-mocha",
      display_name: "Catppuccin Mocha",
      mode: :dark,
      use_terminal_bg: false,
      palette: %{
        bg: hex("#1e1e2e"),
        bg_alt: hex("#181825"),
        fg: hex("#cdd6f4"),
        fg_dim: hex("#a6adc8"),
        fg_muted: hex("#6c7086"),
        selection_bg: hex("#45475a"),
        accent: hex("#89b4fa"),
        border: hex("#313244"),
        error: hex("#f38ba8"),
        warning: hex("#f9e2af"),
        success: hex("#a6e3a1"),
        info: hex("#94e2d5"),
        syntax_heading: hex("#f9e2af"),
        syntax_link: hex("#89b4fa"),
        syntax_code: hex("#cba6f7"),
        syntax_keyword: hex("#cba6f7"),
        syntax_string: hex("#a6e3a1")
      }
    }
  end

  # ---- solarized-light -----------------------------------------------------

  defp solarized_light do
    %Theme{
      name: "solarized-light",
      display_name: "Solarized Light",
      mode: :light,
      use_terminal_bg: false,
      palette: %{
        bg: hex("#fdf6e3"),
        bg_alt: hex("#eee8d5"),
        fg: hex("#586e75"),
        fg_dim: hex("#657b83"),
        fg_muted: hex("#93a1a1"),
        selection_bg: hex("#eee8d5"),
        accent: hex("#268bd2"),
        border: hex("#93a1a1"),
        error: hex("#dc322f"),
        warning: hex("#b58900"),
        success: hex("#859900"),
        info: hex("#2aa198"),
        syntax_heading: hex("#cb4b16"),
        syntax_link: hex("#268bd2"),
        syntax_code: hex("#6c71c4"),
        syntax_keyword: hex("#859900"),
        syntax_string: hex("#2aa198")
      }
    }
  end

  # ---- gruvbox-dark --------------------------------------------------------

  defp gruvbox_dark do
    %Theme{
      name: "gruvbox-dark",
      display_name: "Gruvbox Dark",
      mode: :dark,
      use_terminal_bg: false,
      palette: %{
        bg: hex("#282828"),
        bg_alt: hex("#3c3836"),
        fg: hex("#ebdbb2"),
        fg_dim: hex("#d5c4a1"),
        fg_muted: hex("#928374"),
        selection_bg: hex("#504945"),
        accent: hex("#fabd2f"),
        border: hex("#665c54"),
        error: hex("#fb4934"),
        warning: hex("#fabd2f"),
        success: hex("#b8bb26"),
        info: hex("#83a598"),
        syntax_heading: hex("#fabd2f"),
        syntax_link: hex("#83a598"),
        syntax_code: hex("#fe8019"),
        syntax_keyword: hex("#d3869b"),
        syntax_string: hex("#b8bb26")
      }
    }
  end

  # ---- hex parsing (compile-time) ------------------------------------------

  defp hex("#" <> rest) when byte_size(rest) == 6 do
    <<r::8, g::8, b::8>> = Base.decode16!(rest, case: :mixed)

    <<r / 255::float-32-little, g / 255::float-32-little, b / 255::float-32-little,
      1.0::float-32-little>>
  end
end
