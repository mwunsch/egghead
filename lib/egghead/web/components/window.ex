defmodule Egghead.Web.Components.Window do
  @moduledoc """
  BeOS-flavored desktop window. Renders a tab (yellow gradient,
  partial-width, top-left), a 1px border around the body slot, and a
  bottom-right resize grip. Drag, resize, focus, and persistence are
  driven by the `Window` JS hook. Position and size live in
  `localStorage` — the server never sees pixel coordinates.

  Three roles, encoded by `:role`:

    * `:anchor`    — cannot be closed (no close box)
    * `:panel`     — closable; toolbar reopens it
    * `:ephemeral` — closable; auto-closes on outside click (handled
                     by the hook, not this component)
  """
  use Egghead.Web, :html

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :role, :atom, values: [:anchor, :panel, :ephemeral], default: :panel
  attr :default_x, :integer, default: 100
  attr :default_y, :integer, default: 80
  attr :default_w, :integer, default: 480
  attr :default_h, :integer, default: 480
  attr :default_z, :integer, default: 1
  attr :open, :boolean, default: true
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :footer

  def window(assigns) do
    ~H"""
    <section
      id={"win-" <> @id}
      class={["window", "window-#{@role}", @class]}
      phx-hook="Window"
      data-window-id={@id}
      data-window-role={@role}
      data-default-x={@default_x}
      data-default-y={@default_y}
      data-default-w={@default_w}
      data-default-h={@default_h}
      data-default-z={@default_z}
      data-default-open={to_string(@open)}
      hidden={!@open}
    >
      <header class="window-tab" data-window-drag>
        <button
          :if={@role != :anchor}
          type="button"
          class="window-close"
          data-window-close
          aria-label="Close window"
        >
          ×
        </button>
        <span class="window-title" title={@title}>{@title}</span>
        <span :if={@subtitle} class="window-subtitle" title={@subtitle}>
          {@subtitle}
        </span>
      </header>
      <div class="window-body">
        <div class="window-content">{render_slot(@inner_block)}</div>
        <footer class="window-footer">
          <div class="window-footer-status">{render_slot(@footer)}</div>
          <div class="window-grip" data-window-resize aria-hidden="true"></div>
        </footer>
      </div>
    </section>
    """
  end
end
