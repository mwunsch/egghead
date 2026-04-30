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
  _state: { version: 1, windows: {} },
  _z: WM_Z_BASE,
  _windows: new Map(),
  _mobile: false,
  _initialized: false,
  // Tracks which window is currently focused. Re-applied in Window
  // updated() because morphdom strips JS-added classes that aren't
  // in the server template.
  _focusedId: null,

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
      if (!raw) return { version: 1, windows: {} };
      const parsed = JSON.parse(raw);
      if (parsed && parsed.version === 1) return { version: 1, windows: parsed.windows || {} };
    } catch {}
    return { version: 1, windows: {} };
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

    // Auto-raise on mount:
    //   - anchor (load-bearing) when nothing else is focused, so first
    //     load lands with the Record window in focus.
    //   - ephemeral (transient modals like the paste preview) every
    //     time, so they always pop above persisted-geom panels whose
    //     z may have crept up past the modal's stored z.
    if (
      (this._role === "anchor" && !WindowManager._focusedId) ||
      this._role === "ephemeral"
    ) {
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
        // For server-managed windows (data-server-close="1") the
        // LiveView owns the lifecycle via phx-click — must let the
        // event bubble to Phoenix's document-level delegation.
        // For client-only windows we still suppress propagation so
        // the desktop's mousedown-to-raise doesn't fire.
        if (this.el.dataset.serverClose !== "1") {
          e.stopPropagation();
        }
        this.close();
      });
    }
  },

  updated() {
    // Re-apply geom/open in case morphdom touched style/hidden attrs.
    this.applyMode();
    this.applyOpen();
    // morphdom strips JS-only data attributes on re-render; the
    // `:not([data-window-ready])` CSS rule would then hide every
    // window. Re-set on every update.
    this.el.dataset.windowReady = "true";
    // morphdom also strips JS-added classes; re-apply focused.
    this.el.classList.toggle("focused", WindowManager._focusedId === this._id);
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
    // Server-managed close: the close button has its own phx-click.
    // Don't fight it — server prunes the element and our destroyed()
    // hook handles cleanup.
    if (this.el.dataset.serverClose === "1") return;
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
    WindowManager._focusedId = this._id;
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

// New-chat-room button — prompts for a name and pushes through the
// existing switch_chat_room handler, which validates + creates +
// switches in one path.
Hooks.NewRoomButton = {
  mounted() {
    this.el.addEventListener("click", () => {
      const name = window.prompt("New room name (alphanumeric, dashes, underscores):");
      if (name && name.trim()) {
        this.pushEvent("switch_chat_room", { room: name.trim() });
      }
    });
  },
};

// Live clock + date in the Deskbar tray. Mirrors BeOS's tray clock —
// the one fixture that was always there and always trustworthy.
//
// morphdom rewrites the tray text on every LiveView re-render (any
// button click triggers one), wiping the clock back to its template
// placeholder. updated() re-ticks so the displayed time is always
// current after a server round-trip.
Hooks.Clock = {
  mounted() {
    this._tick = () => {
      const now = new Date();
      const clock = this.el.querySelector("[data-tray-clock]");
      const date = this.el.querySelector("[data-tray-date]");
      if (clock) {
        const h = now.getHours();
        const m = String(now.getMinutes()).padStart(2, "0");
        const period = h >= 12 ? "PM" : "AM";
        const h12 = h % 12 === 0 ? 12 : h % 12;
        clock.textContent = `${h12}:${m} ${period}`;
      }
      if (date) {
        const opts = { weekday: "short", month: "short", day: "numeric" };
        date.textContent = now.toLocaleDateString(undefined, opts);
      }
    };
    this._tick();
    // Resync on the minute boundary so the displayed time matches the
    // wall clock even if the user leaves the tab idle.
    const msToNextMinute = 60000 - (Date.now() % 60000);
    this._timeout = setTimeout(() => {
      this._tick();
      this._interval = setInterval(this._tick, 60000);
    }, msToNextMinute);
  },
  updated() {
    if (this._tick) this._tick();
  },
  destroyed() {
    if (this._timeout) clearTimeout(this._timeout);
    if (this._interval) clearInterval(this._interval);
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

// Slash commands that take a second argument from a known set.
// Mirrors TUI's @action_triggers in lib/egghead/tui/chat/update.ex.
const ACTION_COMMANDS = {
  mute: "agent",
  unmute: "agent",
  handoff: "agent",
  invite: "agent",
  kick: "agent",
  whois: "agent",
  join: "room",
};

// ============================================================
// Chat input — TUI-parity completion, fully client-side.
//
// Server pushes the candidate corpus once (and on changes):
//   { commands, agents, broadcasts, records }
//
// Typing into the textarea triggers a local match against that
// corpus. A floating popover element renders the candidates next
// to the textarea. Arrow keys move the selection, Tab accepts,
// Escape dismisses, Enter sends. Plain typing is NEVER touched —
// no preventDefault on letters, digits, /, @, [[, spaces.
//
// Acceptance is also local: the textarea's value is mutated in
// place; the server never sees intermediate state. Only the final
// "send_chat" event ships the trimmed message to the room.
// ============================================================
Hooks.ChatInput = {
  mounted() {
    this._corpus = { commands: [], agents: [], broadcasts: [], records: [], rooms: [] };
    this._popover = null;       // {kind, candidates, selected, replaceFrom}
    this._popoverEl = null;     // mounted DOM element
    this._lastValue = "";

    this.handleEvent("chat_corpus", (data) => {
      if (data.commands) this._corpus.commands = data.commands;
      if (data.agents) this._corpus.agents = data.agents;
      if (data.broadcasts) this._corpus.broadcasts = data.broadcasts;
      if (data.records) this._corpus.records = data.records;
      if (data.rooms) this._corpus.rooms = data.rooms;
    });

    // /copy — server pushes the formatted transcript; we put it on
    // the system clipboard (TUI uses Egghead.OpenTUI.Clipboard.copy).
    this.handleEvent("chat_copy", ({ text }) => {
      if (typeof text !== "string" || !text) return;
      try {
        navigator.clipboard.writeText(text);
      } catch (e) { /* clipboard unavailable — no-op */ }
    });

    this.el.addEventListener("keydown", (e) => this._onKeydown(e));
    this.el.addEventListener("input", () => this._refresh());
    this.el.addEventListener("blur", (e) => {
      // Don't dismiss when focus moves to a popover item (handled by
      // the document-level mousedown guard below).
      if (e.relatedTarget && e.relatedTarget.closest(".completion-item")) return;
      // Brief delay so a click on a popover item still fires.
      setTimeout(() => this._dismiss(), 120);
    });

    // Keep textarea focused when clicking a completion item.
    if (!window._chatPopoverGuardInstalled) {
      window._chatPopoverGuardInstalled = true;
      document.addEventListener("mousedown", (e) => {
        if (e.target.closest(".completion-item")) e.preventDefault();
      });
    }

    this.el.addEventListener("paste", (e) => {
      const text = e.clipboardData.getData("text/plain");
      const lines = text.split("\n").length;
      if (lines > 3 || text.length > 150) {
        e.preventDefault();
        this.pushEvent("chat_paste", { text });
      }
    });
  },

  destroyed() {
    this._dismiss();
  },

  _onKeydown(e) {
    // Enter (no shift) — ALWAYS sends. Never hijacked by completion.
    // Also sends if the textarea is empty but paste chips are
    // attached, so a paste-only message can ship.
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      const value = this.el.value;
      const hasChips = !!this.el.closest(".chat-irc")?.querySelector(".paste-chip");
      if (value.trim() || hasChips) {
        this.pushEvent("send_chat", { message: value });
        this.el.value = "";
        this._dismiss();
      }
      return;
    }

    if (this._popover) {
      if (e.key === "ArrowUp") {
        e.preventDefault();
        this._move(-1);
        return;
      }
      if (e.key === "ArrowDown") {
        e.preventDefault();
        this._move(1);
        return;
      }
      if (e.key === "Tab") {
        e.preventDefault();
        this._accept();
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        this._dismiss();
        return;
      }
    } else if (e.key === "Tab") {
      // No popover — swallow Tab so it doesn't move focus to the next
      // window. Don't insert a literal tab character either.
      e.preventDefault();
      return;
    }

    // Everything else falls through to the textarea normally.
  },

  // Inspect text up to the cursor and decide whether to show a popover.
  _refresh() {
    const v = this.el.value;
    this._lastValue = v;
    const cursor = this.el.selectionStart;
    const before = v.slice(0, cursor);

    // /<action> <arg> — second-argument picker. Mirrors TUI behaviour:
    // /mute, /unmute, /handoff, /invite, /kick, /whois → agent picker;
    // /join → room picker. Trigger as soon as a space follows the
    // command, so `/mute ` (trailing space) immediately opens an
    // empty-prefix picker showing every candidate.
    let m = before.match(/^\/([a-zA-Z]+) ([a-zA-Z0-9\/_\-]*)$/);
    if (m) {
      const action = m[1].toLowerCase();
      const prefix = m[2].toLowerCase();
      const argType = ACTION_COMMANDS[action];
      if (argType === "agent") {
        const candidates = this._corpus.agents
          .filter((a) => {
            const id = (a.id || "").toLowerCase();
            const base = id.split("/").pop();
            return id.startsWith(prefix) || base.startsWith(prefix);
          })
          .slice(0, 8);
        if (candidates.length) {
          this._show({
            kind: "action_agent",
            candidates,
            selected: 0,
            replaceFrom: cursor - m[2].length,
            replaceTo: cursor,
          });
          return;
        }
      } else if (argType === "room") {
        const candidates = this._corpus.rooms
          .filter((r) => (r.id || "").toLowerCase().startsWith(prefix))
          .slice(0, 8);
        if (candidates.length) {
          this._show({
            kind: "action_room",
            candidates,
            selected: 0,
            replaceFrom: cursor - m[2].length,
            replaceTo: cursor,
          });
          return;
        }
      }
    }

    // /command — at the very start, no whitespace, no newline yet.
    m = before.match(/^\/([a-zA-Z]*)$/);
    if (m) {
      const prefix = m[1].toLowerCase();
      const candidates = this._corpus.commands.filter((c) =>
        c.name.startsWith(prefix)
      );
      if (candidates.length) {
        this._show({
          kind: "command",
          candidates,
          selected: 0,
          replaceFrom: 0,
          replaceTo: cursor,
        });
        return;
      }
    }

    // @mention — after start-of-input or whitespace.
    m = before.match(/(^|\s)@([a-zA-Z0-9\/_\-]*)$/);
    if (m) {
      const prefix = m[2].toLowerCase();
      const atIdx = cursor - m[2].length - 1;
      const broadcasts = this._corpus.broadcasts.filter((b) =>
        b.id.startsWith(prefix)
      );
      const agents = this._corpus.agents.filter((a) => {
        const base = a.id.split("/").pop().toLowerCase();
        return base.startsWith(prefix);
      });
      const candidates = broadcasts.concat(agents).slice(0, 8);
      if (candidates.length) {
        this._show({
          kind: "agent",
          candidates,
          selected: 0,
          replaceFrom: atIdx,
          replaceTo: cursor,
        });
        return;
      }
    }

    // [[wikilink — anywhere, looks back to the most recent unmatched [[.
    m = before.match(/\[\[([a-zA-Z0-9\/_\-]*)$/);
    if (m) {
      const prefix = m[1].toLowerCase();
      const startIdx = cursor - m[1].length - 2;
      const candidates = this._corpus.records
        .filter((r) => (r.id || "").toLowerCase().startsWith(prefix))
        .slice(0, 8);
      if (candidates.length) {
        this._show({
          kind: "record",
          candidates,
          selected: 0,
          replaceFrom: startIdx,
          replaceTo: cursor,
        });
        return;
      }
    }

    this._dismiss();
  },

  _show(state) {
    this._popover = state;
    this._render();
  },

  _move(dir) {
    if (!this._popover) return;
    const n = this._popover.candidates.length;
    this._popover.selected = (this._popover.selected + dir + n) % n;
    this._render();
  },

  _accept() {
    if (!this._popover) return;
    const c = this._popover.candidates[this._popover.selected];
    let replacement;
    switch (this._popover.kind) {
      case "command":
        replacement = "/" + c.name + " ";
        break;
      case "agent":
        replacement = "@" + (c.id || c.name) + " ";
        break;
      case "record":
        replacement = "[[" + c.id + "]] ";
        break;
      case "action_agent":
      case "action_room":
        // Bare id (no @, no [[]]) — second-argument slot. Trailing
        // space lets the user keep typing or hit Enter to dispatch.
        replacement = c.id + " ";
        break;
    }
    const v = this.el.value;
    const head = v.slice(0, this._popover.replaceFrom);
    const tail = v.slice(this._popover.replaceTo);
    const next = head + replacement + tail;
    this.el.value = next;
    const caret = head.length + replacement.length;
    this.el.setSelectionRange(caret, caret);
    this.el.focus();
    this._dismiss();
    // Re-check in case the new caret position triggers another popover
    // (rare — typically the trailing space dismisses).
    this._refresh();
  },

  _dismiss() {
    this._popover = null;
    if (this._popoverEl) {
      this._popoverEl.remove();
      this._popoverEl = null;
    }
  },

  _render() {
    if (!this._popoverEl) {
      const el = document.createElement("div");
      el.className = "chat-completion";
      el.id = "chat-completion-popover";
      // Insert just before the input wrap so it lives directly above
      // the textarea inside the chat window's vertical stack.
      const wrap = this.el.closest(".chat-irc")?.querySelector(".chat-input-wrap");
      if (wrap && wrap.parentNode) {
        wrap.parentNode.insertBefore(el, wrap);
      } else {
        document.body.appendChild(el);
      }
      this._popoverEl = el;
    }

    const items = this._popover.candidates.map((c, idx) => {
      let nameStr, descStr;
      switch (this._popover.kind) {
        case "command":
          nameStr = "/" + c.name;
          descStr = c.description || "";
          break;
        case "agent":
          nameStr = "@" + (c.id || c.name);
          descStr = c.broadcast ? c.label || "" : c.name || "";
          break;
        case "record":
          nameStr = "[[" + c.id + "]]";
          descStr = c.title || "";
          break;
        case "action_agent":
          nameStr = c.id;
          descStr = c.name || "";
          break;
        case "action_room":
          nameStr = c.id;
          descStr = "";
          break;
      }
      return { idx, nameStr, descStr, selected: idx === this._popover.selected };
    });

    this._popoverEl.innerHTML = "";
    items.forEach(({ idx, nameStr, descStr, selected }) => {
      const item = document.createElement("div");
      item.className = "completion-item" + (selected ? " selected" : "");
      const name = document.createElement("span");
      name.className = "completion-name";
      name.textContent = nameStr;
      const desc = document.createElement("span");
      desc.className = "completion-desc";
      desc.textContent = descStr;
      item.appendChild(name);
      item.appendChild(desc);
      item.addEventListener("click", () => {
        this._popover.selected = idx;
        this._accept();
      });
      this._popoverEl.appendChild(item);
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

// Persists the open/closed state of a <details> across record selections.
// Storage key: data-disclosure-key (or "default").
Hooks.Disclosure = {
  mounted() {
    const key = "egghead.disclosure." + (this.el.dataset.disclosureKey || "default");
    const saved = localStorage.getItem(key);
    if (saved === "open") this.el.open = true;
    else if (saved === "closed") this.el.open = false;
    this.el.addEventListener("toggle", () => {
      try { localStorage.setItem(key, this.el.open ? "open" : "closed"); } catch {}
    });
  },
  updated() {
    // Re-apply the persisted state after server re-renders (record switch
    // remounts the inner content but the <details> attribute resets to
    // its template default — which is `open`).
    const key = "egghead.disclosure." + (this.el.dataset.disclosureKey || "default");
    const saved = localStorage.getItem(key);
    if (saved === "closed" && this.el.open) this.el.open = false;
    if (saved === "open" && !this.el.open) this.el.open = true;
  },
};

// CRDT-backed markdown editor
Hooks.YjsEditor = {
  async mounted() {
    const { createEditor } = await import("./editor.js");
    const recordId = this.el.dataset.recordId;
    const format = this.el.dataset.format;
    this._editor = createEditor(this.el, recordId, {
      format,
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
