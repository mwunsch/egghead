import { Socket } from "https://cdn.jsdelivr.net/npm/phoenix@1.8.5/priv/static/phoenix.mjs/+esm";
import { LiveSocket } from "https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.28/priv/static/phoenix_live_view.esm.js/+esm";

const Hooks = {};

// ============================================================
// Windowing system — BeOS-flavored, client-side only.
// Server never sees pixel coordinates. Persistence: localStorage.
// ============================================================

const WM_STORAGE_KEY = "egghead.layout.v1";
const WM_MOBILE_QUERY = "(max-width: 768px)";
const WM_Z_BASE = 100;
const WM_MARGIN = 8;
const WM_MIN_W = 240;
const WM_MIN_H = 140;

const WindowManager = {
  _state: { version: 1, windows: {}, groups: [] },
  _z: WM_Z_BASE,
  _windows: new Map(),
  _mobile: false,
  _initialized: false,

  init() {
    if (this._initialized) return;
    this._initialized = true;

    this._state = this._load();
    let maxZ = WM_Z_BASE;
    for (const id in this._state.windows) {
      const w = this._state.windows[id];
      if (typeof w.z === "number" && w.z > maxZ) maxZ = w.z;
    }
    this._z = maxZ + 1;

    const mq = window.matchMedia(WM_MOBILE_QUERY);
    this._mobile = mq.matches;
    document.body.classList.toggle("desktop-mobile", this._mobile);
    mq.addEventListener("change", (e) => {
      this._mobile = e.matches;
      document.body.classList.toggle("desktop-mobile", this._mobile);
      this._windows.forEach((w) => w.applyMode());
      this._refreshToggleButtons();
    });

    // Document-level click delegation for [data-window-toggle]
    document.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-window-toggle]");
      if (!btn) return;
      const id = btn.dataset.windowToggle;
      const win = this._windows.get(id);
      if (win) win.toggle();
    });
  },

  _load() {
    try {
      const raw = localStorage.getItem(WM_STORAGE_KEY);
      if (!raw) return { version: 1, windows: {}, groups: [] };
      const parsed = JSON.parse(raw);
      if (parsed && parsed.version === 1) return parsed;
    } catch {}
    return { version: 1, windows: {}, groups: [] };
  },

  _save() {
    try {
      localStorage.setItem(WM_STORAGE_KEY, JSON.stringify(this._state));
    } catch {}
  },

  get(id) {
    return this._state.windows[id] || null;
  },

  put(id, patch) {
    const prev = this._state.windows[id] || {};
    this._state.windows[id] = { ...prev, ...patch };
    this._save();
  },

  isMobile() {
    return this._mobile;
  },

  nextZ() {
    return ++this._z;
  },

  register(id, instance) {
    this._windows.set(id, instance);
    this._refreshDeskbarEntries();
  },

  unregister(id) {
    this._windows.delete(id);
  },

  // Pull a geometry into the visible viewport. In desktop mode, the
  // deskbar reserves a strip on the right — windows are clamped to
  // not overlap it.
  //
  // Two modes:
  //   default     — clamp x, y, w, h to viewport
  //   fixedOrigin — keep x, y; only constrain w, h to the space
  //                 between the current origin and the edges. Used
  //                 during a resize-from-corner drag so the window
  //                 doesn't jump leftward when w hits its cap.
  clamp(g, opts = {}) {
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    let reservedRight = 0;
    if (!this._mobile) {
      const deskbar = document.querySelector(".deskbar");
      if (deskbar) {
        const r = deskbar.getBoundingClientRect();
        if (r.width > 0) reservedRight = vw - r.left + WM_MARGIN;
      }
    }
    const usableW = vw - reservedRight;

    if (opts.fixedOrigin) {
      const maxW = usableW - g.x - WM_MARGIN;
      const maxH = vh - g.y - WM_MARGIN;
      const w = Math.max(WM_MIN_W, Math.min(g.w, maxW));
      const h = Math.max(WM_MIN_H, Math.min(g.h, maxH));
      return { ...g, w, h };
    }

    const w = Math.max(WM_MIN_W, Math.min(g.w, usableW - WM_MARGIN * 2));
    const h = Math.max(WM_MIN_H, Math.min(g.h, vh - WM_MARGIN * 2));
    const x = Math.max(WM_MARGIN, Math.min(g.x, usableW - w - WM_MARGIN));
    const y = Math.max(WM_MARGIN, Math.min(g.y, vh - h - WM_MARGIN));
    return { ...g, x, y, w, h };
  },

  notifyOpenChanged(id) {
    this._refreshDeskbarEntries(id);
  },

  notifyFocusChanged() {
    this._refreshDeskbarEntries();
  },

  // Mirror window open + focused state onto deskbar entries.
  _refreshDeskbarEntries(onlyId) {
    document.querySelectorAll("[data-window-entry]").forEach((entry) => {
      const id = entry.dataset.windowEntry;
      if (onlyId && id !== onlyId) return;
      const win = this._windows.get(id);
      const open = win ? win.isOpen() : false;
      const focused = win ? win.isFocused() : false;
      entry.classList.toggle("open", open);
      entry.classList.toggle("focused", open && focused);
    });
  },
};

WindowManager.init();

Hooks.Window = {
  mounted() {
    const id = this.el.dataset.windowId;
    const role = this.el.dataset.windowRole;

    const defaults = {
      x: parseInt(this.el.dataset.defaultX, 10) || 100,
      y: parseInt(this.el.dataset.defaultY, 10) || 80,
      w: parseInt(this.el.dataset.defaultW, 10) || 480,
      h: parseInt(this.el.dataset.defaultH, 10) || 480,
      z: parseInt(this.el.dataset.defaultZ, 10) || WindowManager.nextZ(),
      open: this.el.dataset.defaultOpen !== "false",
    };

    const persisted = WindowManager.get(id) || {};
    const initial = { ...defaults, ...persisted };

    this._id = id;
    this._role = role;
    this._geom = WindowManager.clamp({
      x: initial.x,
      y: initial.y,
      w: initial.w,
      h: initial.h,
      z: initial.z,
    });
    this._open = initial.open !== false;

    WindowManager.register(id, this);
    this.applyMode();
    this.applyGeom();
    this.applyOpen();
    // Reveal once first geometry is in. Until then CSS keeps the window
    // invisible so a remount (e.g. /chat/:room change) can't flash the
    // default position before localStorage is read.
    this.el.dataset.windowReady = "true";

    // The anchor focuses itself on mount if no other window is focused —
    // so first load lands with the Record window in focus.
    if (this._role === "anchor" && !document.querySelector(".window.focused")) {
      this.raise();
    }

    this._onMouseDown = () => this.raise();
    this.el.addEventListener("mousedown", this._onMouseDown, true);

    const tab = this.el.querySelector("[data-window-drag]");
    if (tab) this._wireDrag(tab);

    const grip = this.el.querySelector("[data-window-resize]");
    if (grip) this._wireResize(grip);

    const close = this.el.querySelector("[data-window-close]");
    if (close) {
      close.addEventListener("click", (e) => {
        e.stopPropagation();
        this.close();
      });
    }
  },

  updated() {
    // Re-apply geom/open in case morphdom touched style/hidden attrs.
    this.applyMode();
    this.applyOpen();
  },

  destroyed() {
    if (this._onMouseDown) {
      this.el.removeEventListener("mousedown", this._onMouseDown, true);
    }
    if (this._docMove) document.removeEventListener("mousemove", this._docMove);
    if (this._docUp) document.removeEventListener("mouseup", this._docUp);
    WindowManager.unregister(this._id);
  },

  isOpen() { return this._open; },
  isFocused() { return this.el.classList.contains("focused"); },

  open() {
    this._open = true;
    this.applyOpen();
    this.raise();
    WindowManager.put(this._id, { open: true });
    WindowManager.notifyOpenChanged(this._id);
  },

  close() {
    // Anchor windows can't be closed — they're the load-bearing surface.
    if (this._role === "anchor") {
      this.raise();
      return;
    }
    this._open = false;
    this.applyOpen();
    WindowManager.put(this._id, { open: false });
    WindowManager.notifyOpenChanged(this._id);
  },

  toggle() {
    // Anchor: clicking the deskbar entry just raises (never closes).
    if (this._role === "anchor") {
      if (!this._open) this.open();
      else this.raise();
      return;
    }
    if (this._open) this.close();
    else this.open();
  },

  raise() {
    const z = WindowManager.nextZ();
    this._geom.z = z;
    if (!WindowManager.isMobile()) this.el.style.zIndex = String(z);
    document.querySelectorAll(".window.focused").forEach((el) => {
      if (el !== this.el) el.classList.remove("focused");
    });
    this.el.classList.add("focused");
    WindowManager.put(this._id, { z });
    WindowManager.notifyFocusChanged();
  },

  applyMode() {
    if (WindowManager.isMobile()) {
      this.el.style.left = "";
      this.el.style.top = "";
      this.el.style.width = "";
      this.el.style.height = "";
      this.el.style.zIndex = "";
    } else {
      this.applyGeom();
    }
  },

  applyGeom() {
    if (WindowManager.isMobile()) return;
    const g = this._geom;
    this.el.style.left = g.x + "px";
    this.el.style.top = g.y + "px";
    this.el.style.width = g.w + "px";
    this.el.style.height = g.h + "px";
    this.el.style.zIndex = String(g.z);
  },

  applyOpen() {
    this.el.hidden = !this._open;
  },

  _wireDrag(handle) {
    let dragging = false;
    let startX = 0, startY = 0, startGX = 0, startGY = 0;

    handle.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      if (e.target.closest("[data-window-close]")) return;
      if (WindowManager.isMobile()) return;
      dragging = true;
      startX = e.clientX; startY = e.clientY;
      startGX = this._geom.x; startGY = this._geom.y;
      this.raise();
      document.body.style.userSelect = "none";
      e.preventDefault();
    });

    this._docMove = (e) => {
      if (!dragging) return;
      this._geom.x = startGX + (e.clientX - startX);
      this._geom.y = startGY + (e.clientY - startY);
      this._geom = WindowManager.clamp(this._geom);
      this.applyGeom();
    };

    this._docUp = () => {
      if (!dragging) return;
      dragging = false;
      document.body.style.userSelect = "";
      WindowManager.put(this._id, { x: this._geom.x, y: this._geom.y });
    };

    document.addEventListener("mousemove", this._docMove);
    document.addEventListener("mouseup", this._docUp);
  },

  _wireResize(grip) {
    let resizing = false;
    let startX = 0, startY = 0, startW = 0, startH = 0;

    grip.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      if (WindowManager.isMobile()) return;
      resizing = true;
      startX = e.clientX; startY = e.clientY;
      startW = this._geom.w; startH = this._geom.h;
      this.raise();
      document.body.style.userSelect = "none";
      e.preventDefault();
      e.stopPropagation();
    });

    const move = (e) => {
      if (!resizing) return;
      this._geom.w = Math.max(WM_MIN_W, startW + (e.clientX - startX));
      this._geom.h = Math.max(WM_MIN_H, startH + (e.clientY - startY));
      // fixedOrigin: keep x/y locked while resizing — without this,
      // hitting the right edge would clamp w then re-clamp x leftward,
      // visually growing the window in the wrong direction.
      this._geom = WindowManager.clamp(this._geom, { fixedOrigin: true });
      this.applyGeom();
    };

    const up = () => {
      if (!resizing) return;
      resizing = false;
      document.body.style.userSelect = "";
      WindowManager.put(this._id, { w: this._geom.w, h: this._geom.h });
    };

    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  },
};

// ============================================================
// Deskbar — re-applies window state classes on every LiveView
// update so morphdom can't blow them away when room_id /
// agent count refreshes the deskbar template.
// ============================================================

Hooks.Deskbar = {
  mounted() {
    queueMicrotask(() => WindowManager._refreshDeskbarEntries());
  },
  updated() {
    queueMicrotask(() => WindowManager._refreshDeskbarEntries());
  },
};

// ============================================================

// Auto-scroll transcript to bottom on new messages (unless user scrolled up)
Hooks.ScrollBottom = {
  mounted() {
    this.pinned = true;
    this.el.addEventListener("scroll", () => {
      const atBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 30;
      this.pinned = atBottom;
    });
    this.scrollToBottom();
    this.observer = new MutationObserver(() => {
      if (this.pinned) this.scrollToBottom();
    });
    this.observer.observe(this.el, { childList: true, subtree: true });
  },
  updated() {
    if (this.pinned) this.scrollToBottom();
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

// Chat textarea: keystroke handling
Hooks.ChatInput = {
  mounted() {
    // Server can push value changes (completions, clears)
    this.handleEvent("update_input", ({ value }) => {
      this.el.value = value;
    });

    this.el.addEventListener("keydown", (e) => {
      const hasDropdown = !!document.querySelector(".chat-dropdown");

      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (hasDropdown) {
          this.pushEvent("chat_tab_complete", {});
        } else {
          const value = this.el.value.trim();
          if (value) {
            this.pushEvent("send_chat", { message: value });
            this.el.value = "";
          }
        }
        return;
      }

      if (e.key === "ArrowUp" && hasDropdown) {
        e.preventDefault();
        this.pushEvent("chat_dropdown_up", {});
      } else if (e.key === "ArrowDown" && hasDropdown) {
        e.preventDefault();
        this.pushEvent("chat_dropdown_down", {});
      }

      if (e.key === "Tab") {
        e.preventDefault();
        this.pushEvent("chat_tab_complete", {});
      }

      if (e.key === "Escape") {
        this.pushEvent("chat_escape", {});
      }
    });

    this.el.addEventListener("input", () => {

      // Only push to server when a completion trigger is present.
      const v = this.el.value;
      if (
        v.startsWith("/") ||
        /(^|\s)@/.test(v) ||
        v.includes("[[")
      ) {
        this.pushEvent("chat_input_change", { value: v });
      } else if (this._hadDropdown) {
        // Clear the dropdown if trigger chars were deleted
        this.pushEvent("chat_input_change", { value: v });
      }
      this._hadDropdown = !!document.querySelector(".chat-dropdown");
    });

    this.el.addEventListener("paste", (e) => {
      const text = e.clipboardData.getData("text/plain");
      const lines = text.split("\n").length;
      if (lines > 3 || text.length > 150) {
        e.preventDefault();
        this.pushEvent("chat_paste", { text });
      }
    });
  },
};

// Drag handle above the textarea — drag up to make taller
Hooks.DragHandle = {
  mounted() {
    const textarea = document.getElementById("chat-textarea");
    if (!textarea) return;

    let dragging = false;
    let startY = 0;
    let startH = 0;

    const setHeight = (h) => {
      const clamped = Math.max(36, Math.min(h, 300));
      textarea.style.height = clamped + "px";
      textarea.style.minHeight = clamped + "px";
    };

    this.el.addEventListener("mousedown", (e) => {
      dragging = true;
      startY = e.clientY;
      startH = textarea.offsetHeight;
      document.body.style.cursor = "row-resize";
      document.body.style.userSelect = "none";
      e.preventDefault();
    });

    document.addEventListener("mousemove", (e) => {
      if (!dragging) return;
      setHeight(startH + (startY - e.clientY));
    });

    document.addEventListener("mouseup", () => {
      if (dragging) {
        dragging = false;
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
      }
    });
  },
};

// Copy raw content to clipboard
Hooks.CopyMarkdown = {
  mounted() {
    this.el.addEventListener("click", () => {
      const markdown = this.el.dataset.markdown;
      const label = this.el.querySelector(".btn-label");
      if (markdown && label) {
        navigator.clipboard.writeText(markdown).then(() => {
          label.textContent = "Copied!";
          setTimeout(() => (label.textContent = "Copy"), 1500);
        });
      }
    });
  },
};

// CRDT-backed markdown editor
Hooks.YjsEditor = {
  async mounted() {
    const { createEditor } = await import("./editor.js");
    const recordId = this.el.dataset.recordId;
    this._editor = createEditor(this.el, recordId, {
      navigate: (target) => {
        window.liveSocket.redirect(`/records/${target}`);
      },
    });
  },
  destroyed() {
    if (this._editor) {
      this._editor.destroy();
      this._editor = null;
    }
  },
};

// --- Socket ---

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

liveSocket.connect();
window.liveSocket = liveSocket;
