import { Socket } from "https://cdn.jsdelivr.net/npm/phoenix@1.8.5/priv/static/phoenix.mjs/+esm";
import { LiveSocket } from "https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.28/priv/static/phoenix_live_view.esm.js/+esm";

// --- Hooks ---

const Hooks = {};

// Auto-scroll transcript to bottom on new messages
Hooks.ScrollBottom = {
  mounted() {
    this.scrollToBottom();
    this.observer = new MutationObserver(() => this.scrollToBottom());
    this.observer.observe(this.el, { childList: true, subtree: true });
  },
  updated() {
    this.scrollToBottom();
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

// Chat textarea: Enter submits, Shift+Enter inserts newline, clear after submit
Hooks.ChatInput = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        const value = this.el.value.trim();
        if (value) {
          this.pushEvent("send_chat", { message: value });
          this.el.value = "";
          this.el.style.height = "auto";
        }
      }
    });

    // Auto-resize textarea
    this.el.addEventListener("input", () => {
      this.el.style.height = "auto";
      this.el.style.height = Math.min(this.el.scrollHeight, 120) + "px";
    });
  },
};

// Copy raw markdown to clipboard
Hooks.CopyMarkdown = {
  mounted() {
    this.el.addEventListener("click", () => {
      const markdown = this.el.dataset.markdown;
      if (markdown) {
        navigator.clipboard.writeText(markdown).then(() => {
          const orig = this.el.textContent;
          this.el.textContent = "Copied!";
          setTimeout(() => (this.el.textContent = orig), 1500);
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
