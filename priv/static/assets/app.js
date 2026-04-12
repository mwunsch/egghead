import { Socket } from "https://cdn.jsdelivr.net/npm/phoenix@1.8.5/priv/static/phoenix.mjs/+esm";
import { LiveSocket } from "https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.28/priv/static/phoenix_live_view.esm.js/+esm";

const Hooks = {};

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
