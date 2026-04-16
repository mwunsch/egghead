import { Socket } from "https://cdn.jsdelivr.net/npm/phoenix@1.8.5/priv/static/phoenix.mjs/+esm";
import {
  EditorView, keymap, drawSelection,
  MatchDecorator, Decoration, ViewPlugin, WidgetType
} from "https://esm.sh/@codemirror/view@6";
import { EditorState, RangeSetBuilder, StateField } from "https://esm.sh/@codemirror/state@6";
import { markdown } from "https://esm.sh/@codemirror/lang-markdown@6";
import { defaultKeymap, history, historyKeymap } from "https://esm.sh/@codemirror/commands@6";
import { syntaxHighlighting, HighlightStyle } from "https://esm.sh/@codemirror/language@6";
import { tags } from "https://esm.sh/@lezer/highlight@1";
import * as Y from "https://esm.sh/yjs@13";
import { yCollab } from "https://esm.sh/y-codemirror.next@0.3";
import * as awarenessProtocol from "https://esm.sh/y-protocols@1/awareness";

// --- Markdown highlight style (matches .markdown-body CSS) ---

const markdownHighlight = HighlightStyle.define([
  { tag: tags.heading1, fontSize: "24px", fontWeight: "300", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading2, fontSize: "20px", fontWeight: "300", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading3, fontSize: "18px", fontWeight: "400", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading4, fontSize: "16px", fontWeight: "400", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading5, fontWeight: "600", color: "var(--heading)", fontFamily: "var(--font-display)" },
  { tag: tags.heading6, fontWeight: "600", color: "var(--heading)", fontFamily: "var(--font-display)" },
  { tag: tags.processingInstruction, color: "var(--syntax)", fontFamily: "var(--font-mono)", fontWeight: "400" },
  { tag: tags.strong, fontWeight: "700" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through", color: "var(--muted)" },
  { tag: tags.monospace, fontFamily: "var(--font-mono)", fontSize: "0.88em", color: "var(--fg)" },
  { tag: tags.link, color: "var(--link)" },
  { tag: tags.url, color: "var(--link)" },
  { tag: tags.quote, color: "var(--muted)", fontStyle: "italic" },
  { tag: tags.meta, color: "var(--syntax)", fontFamily: "var(--font-mono)", fontSize: "0.88em" },
  { tag: tags.contentSeparator, color: "var(--chrome-lo)" },
]);

const proseTheme = EditorView.theme({
  ".cm-gutters": { display: "none" },
  ".cm-activeLineGutter": { display: "none" },
  ".cm-activeLine": { backgroundColor: "transparent" },
  "&.cm-focused": { outline: "none" },
});

// --- Link decorators ---

function makeMatchPlugin(matcher) {
  return ViewPlugin.fromClass(
    class {
      constructor(view) { this.decorations = matcher.createDeco(view); }
      update(update) { this.decorations = matcher.updateDeco(update, this.decorations); }
    },
    { decorations: (v) => v.decorations }
  );
}

const wikilinkHighlighter = makeMatchPlugin(new MatchDecorator({
  regexp: /\[\[([^\]]+)\]\]/g,
  decoration: () => Decoration.mark({ class: "cm-wikilink" }),
}));

const urlHighlighter = makeMatchPlugin(new MatchDecorator({
  regexp: /https?:\/\/[^\s)>\]]+/g,
  decoration: () => Decoration.mark({ class: "cm-url" }),
}));

// --- Markdown link widget: [text](url) → clickable [text] ---

class LinkWidget extends WidgetType {
  constructor(text, url) {
    super();
    this.text = text;
    this.url = url;
  }

  eq(other) { return this.text === other.text && this.url === other.url; }

  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-md-link";

    const open = document.createElement("span");
    open.className = "cm-md-link-bracket";
    open.textContent = "[";

    const a = document.createElement("a");
    a.className = "cm-md-link-text";
    a.textContent = this.text;
    a.title = this.url;
    a.href = this.url;
    a.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      window.open(this.url, "_blank");
    });

    const close = document.createElement("span");
    close.className = "cm-md-link-bracket";
    close.textContent = "]";

    span.append(open, a, close);
    return span;
  }

  ignoreEvent() { return false; }
}

const mdLinkField = StateField.define({
  create(state) { return buildMdLinkDecos(state); },
  update(decos, tr) {
    if (tr.docChanged || tr.selection) return buildMdLinkDecos(tr.state);
    return decos;
  },
  provide(field) { return EditorView.decorations.from(field); },
});

function buildMdLinkDecos(state) {
  const builder = new RangeSetBuilder();
  const sel = state.selection.main;
  const re = /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g;

  for (let i = 1; i <= state.doc.lines; i++) {
    const line = state.doc.line(i);
    let m;
    re.lastIndex = 0;
    while ((m = re.exec(line.text)) !== null) {
      const from = line.from + m.index;
      const to = from + m[0].length;
      if (!(sel.from >= from && sel.from <= to)) {
        builder.add(from, to, Decoration.replace({
          widget: new LinkWidget(m[1], m[2]),
        }));
      }
    }
  }

  return builder.finish();
}

// --- Table widget ---

function parseTable(text) {
  const lines = text.split("\n").filter((l) => l.trim());
  if (lines.length < 2) return null;

  const splitRow = (line) => {
    const cells = line.split("|").map((c) => c.trim());
    if (cells[0] === "") cells.shift();
    if (cells[cells.length - 1] === "") cells.pop();
    return cells;
  };

  const header = splitRow(lines[0]);
  if (!/^[\s|:\-]+$/.test(lines[1])) return null;
  return { header, rows: lines.slice(2).map(splitRow) };
}

class TableWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  eq(other) { return this.text === other.text; }

  toDOM() {
    const parsed = parseTable(this.text);
    if (!parsed) {
      const span = document.createElement("span");
      span.textContent = this.text;
      return span;
    }

    const table = document.createElement("table");
    table.className = "cm-table";

    const thead = document.createElement("thead");
    const headRow = document.createElement("tr");
    for (const cell of parsed.header) {
      const th = document.createElement("th");
      th.textContent = cell;
      headRow.appendChild(th);
    }
    thead.appendChild(headRow);
    table.appendChild(thead);

    const tbody = document.createElement("tbody");
    for (const row of parsed.rows) {
      const tr = document.createElement("tr");
      for (const cell of row) {
        const td = document.createElement("td");
        td.textContent = cell;
        tr.appendChild(td);
      }
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);

    return table;
  }

  ignoreEvent() { return false; }
}

const tableField = StateField.define({
  create(state) { return buildTableDecos(state); },
  update(decos, tr) {
    if (tr.docChanged || tr.selection) return buildTableDecos(tr.state);
    return decos;
  },
  provide(field) { return EditorView.decorations.from(field); },
});

function buildTableDecos(state) {
  const builder = new RangeSetBuilder();
  const sel = state.selection.main;
  const text = state.doc.toString();
  const lines = text.split("\n");
  let i = 0, pos = 0;

  while (i < lines.length) {
    const line = lines[i];
    if (/^\s*\|/.test(line)) {
      const tableStart = pos;
      const tableLines = [line];
      let j = i + 1;
      while (j < lines.length && /^\s*\|/.test(lines[j])) {
        tableLines.push(lines[j]);
        j++;
      }
      if (tableLines.length >= 2 && /^[\s|:\-]+$/.test(tableLines[1])) {
        const tableText = tableLines.join("\n");
        let tableEnd = tableStart;
        for (const tl of tableLines) tableEnd += tl.length + 1;
        tableEnd--;

        if (!(sel.from <= tableEnd && sel.to >= tableStart)) {
          builder.add(tableStart, tableEnd, Decoration.replace({
            widget: new TableWidget(tableText), block: true,
          }));
        } else {
          let linePos = tableStart;
          for (const tl of tableLines) {
            builder.add(linePos, linePos, Decoration.line({ class: "cm-table-source" }));
            linePos += tl.length + 1;
          }
        }
        pos = tableEnd + 1;
        i = j;
        continue;
      }
    }
    pos += line.length + 1;
    i++;
  }
  return builder.finish();
}

// --- Click handler ---

function clickableLinks(navigate) {
  return EditorView.domEventHandlers({
    mousedown(event, view) {
      if (event.button !== 0) return false;
      const target = event.target;

      if (target.closest(".cm-md-link")) return false;

      const wikilink = target.closest(".cm-wikilink");
      if (wikilink) {
        const match = wikilink.textContent.match(/\[\[([^\]]+)\]\]/);
        if (match) {
          event.preventDefault();
          navigate(match[1]);
          return true;
        }
      }

      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (pos == null) return false;
      const line = view.state.doc.lineAt(pos);
      const col = pos - line.from;
      const text = line.text;

      const mdSkipRe = /\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/g;
      let s;
      while ((s = mdSkipRe.exec(text)) !== null) {
        if (col >= s.index && col <= s.index + s[0].length) return false;
      }

      const urlRe = /https?:\/\/[^\s)>\]]+/g;
      let m;
      while ((m = urlRe.exec(text)) !== null) {
        if (col >= m.index && col <= m.index + m[0].length) {
          event.preventDefault();
          window.open(m[0], "_blank");
          return true;
        }
      }

      return false;
    },
  });
}

// --- Helpers ---

function hashToInt(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) | 0;
  return 0x40000000 + (Math.abs(h) % 0x3FFFFFFF);
}

function byteOffsetToCharIndex(str, byteOffset) {
  const encoder = new TextEncoder();
  let bytes = 0;
  let chars = 0;
  for (const ch of str) {
    if (bytes >= byteOffset) break;
    bytes += encoder.encode(ch).length;
    chars++;
  }
  return chars;
}

// --- Phoenix provider ---

const USER_COLORS = [
  "#30bced", "#6eeb83", "#ffbc42", "#e84855",
  "#8b5cf6", "#f472b6", "#34d399", "#fb923c",
];

function pickColor(id) {
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) | 0;
  return USER_COLORS[Math.abs(hash) % USER_COLORS.length];
}

class PhoenixProvider {
  constructor(ydoc, channel, ytext) {
    this.ydoc = ydoc;
    this.ytext = ytext;
    this.channel = channel;
    this.synced = false;
    this.agentCursors = new Map(); // for linger color lookup

    // Awareness
    this.awareness = new awarenessProtocol.Awareness(ydoc);
    const userId = `user-${Math.floor(Math.random() * 1e9)}`;
    const color = pickColor(userId);
    this.awareness.setLocalStateField("user", {
      name: "You",
      color: color,
      colorLight: color + "40",
    });

    // Doc sync
    channel.on("sync", ({ data }) => {
      Y.applyUpdate(this.ydoc, this._decode(data));
      this.synced = true;
    });

    channel.on("update", ({ data }) => {
      Y.applyUpdate(this.ydoc, this._decode(data), "remote");
    });

    this.ydoc.on("update", (update, origin) => {
      if (origin === "remote") return;
      channel.push("update", { data: this._encode(update) });
    });

    // Awareness sync (browser ↔ browser)
    channel.on("awareness", ({ data }) => {
      awarenessProtocol.applyAwarenessUpdate(
        this.awareness, this._decode(data), "remote"
      );
    });

    this.awareness.on("update", ({ added, updated, removed }) => {
      const changed = added.concat(updated).concat(removed);
      const encoded = awarenessProtocol.encodeAwarenessUpdate(
        this.awareness, changed
      );
      channel.push("awareness", { data: this._encode(encoded) });
    });

    // Track last-known agent color for linger highlights
    this.lastAgentColor = null;

    // Agent cursor → inject into awareness so y-codemirror.next renders it
    channel.on("agent_cursor", (cursor) => {
      const clientId = hashToInt(cursor.agent_id);
      this.agentCursors.set(cursor.agent_id, cursor);
      if (cursor.active) this.lastAgentColor = cursor.color;

      if (cursor.active) {
        const textContent = this.ytext.toString();
        const charIdx = byteOffsetToCharIndex(textContent, cursor.pos);
        const safeIdx = Math.min(charIdx, textContent.length);
        const relPos = Y.createRelativePositionFromTypeIndex(this.ytext, safeIdx);
        const jsonPos = Y.relativePositionToJSON(relPos);

        const state = {
          user: {
            name: cursor.name,
            color: cursor.color,
            colorLight: cursor.color + "40",
          },
          cursor: { anchor: jsonPos, head: jsonPos },
        };

        // Set both states and meta so the awareness machinery is consistent
        const isNew = !this.awareness.states.has(clientId);
        this.awareness.states.set(clientId, state);
        this.awareness.meta.set(clientId, {
          clock: (this.awareness.meta.get(clientId)?.clock || 0) + 1,
          lastUpdated: Date.now(),
        });

        this.awareness.emit("change", [
          { added: isNew ? [clientId] : [], updated: isNew ? [] : [clientId], removed: [] },
          "agent",
        ]);
      } else {
        this.agentCursors.delete(cursor.agent_id);
        const hadState = this.awareness.states.has(clientId);
        this.awareness.states.delete(clientId);
        this.awareness.meta.delete(clientId);

        if (hadState) {
          this.awareness.emit("change", [
            { added: [], updated: [], removed: [clientId] },
            "agent",
          ]);
        }
      }
    });
  }

  _encode(data) {
    return btoa(String.fromCharCode(...data));
  }

  _decode(b64) {
    const binary = atob(b64);
    return new Uint8Array(binary.length).map((_, i) => binary.charCodeAt(i));
  }

  destroy() {
    awarenessProtocol.removeAwarenessStates(
      this.awareness, [this.ydoc.clientID], null
    );
    this.awareness.destroy();
  }
}

// --- Linger highlight: remote edits fade out in the editing agent's color ---

const LINGER_DURATION_MS = 2000;

function lingerPluginFor(provider) {
  return ViewPlugin.fromClass(
    class {
      constructor() {
        this.decorations = Decoration.none;
        this.pending = [];
      }

      update(update) {
        if (update.docChanged) {
          this.decorations = this.decorations.map(update.changes);

          if (!provider.synced) return;

          const now = Date.now();
          this.pending = this.pending.filter((p) => p.expires > now);

          const isRemote = update.transactions.some(
            (tr) => tr.docChanged && !tr.isUserEvent("input") &&
                    !tr.isUserEvent("delete") && !tr.isUserEvent("undo") &&
                    !tr.isUserEvent("redo")
          );

          if (isRemote) {
            const color = provider.lastAgentColor || "#F0B030";
            const expires = now + LINGER_DURATION_MS;

            update.changes.iterChanges((_fromA, _toA, fromB, toB) => {
              if (fromB < toB) {
                this.pending.push({ from: fromB, to: toB, expires, color });
              }
            });
          }

          this.decorations = Decoration.set(
            this.pending
              .sort((a, b) => a.from - b.from)
              .map((p) => Decoration.mark({
                class: "cm-linger",
                attributes: { style: `--linger-color: ${p.color}` },
              }).range(
                Math.min(p.from, update.view.state.doc.length),
                Math.min(p.to, update.view.state.doc.length)
              ))
          );

          if (this.pending.length > 0 && !this._timer) {
            this._timer = setTimeout(() => {
              this._timer = null;
              update.view.dispatch();
            }, LINGER_DURATION_MS + 50);
          }
        }
      }
    },
    { decorations: (v) => v.decorations }
  );
}

// --- Editor factory ---

export function createEditor(element, recordId, { navigate } = {}) {
  const ydoc = new Y.Doc();
  const ytext = ydoc.getText("content");

  const socket = new Socket("/yjs");
  socket.connect();
  const channel = socket.channel(`doc:${recordId}`);

  const provider = new PhoenixProvider(ydoc, channel, ytext);

  const nav = navigate || ((target) => {
    window.location.href = `/records/${target}`;
  });

  const extensions = [
    proseTheme,
    markdown(),
    syntaxHighlighting(markdownHighlight),
    wikilinkHighlighter,
    urlHighlighter,
    mdLinkField,
    tableField,
    clickableLinks(nav),
    keymap.of([...defaultKeymap, ...historyKeymap]),
    history(),
    drawSelection(),
    yCollab(ytext, provider.awareness),
    lingerPluginFor(provider),
    EditorView.lineWrapping,
  ];

  const view = new EditorView({
    state: EditorState.create({ extensions }),
    parent: element,
  });

  // Reconnection: Phoenix channels auto-rejoin on reconnect.
  // The server's after_join re-attaches and pushes full state via "sync".
  // If the server restarted (fresh Y.Doc, no shared history), the
  // applied update will contain the current file content and Yjs
  // merges it with any local state.
  channel.onError(() => {
    element.classList.add("cm-reconnecting");
  });

  channel.join()
    .receive("ok", () => {
      element.classList.remove("cm-reconnecting");
    })
    .receive("error", (resp) => {
      console.error("Failed to join doc channel:", resp);
    });

  return {
    view,
    provider,
    socket,
    channel,
    destroy() {
      provider.destroy();
      channel.leave();
      socket.disconnect();
      view.destroy();
    },
  };
}
