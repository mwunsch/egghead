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

// Match the existing .markdown-body CSS exactly.
const markdownHighlight = HighlightStyle.define([
  // Headings — match .markdown-body h1-h4
  { tag: tags.heading1, fontSize: "24px", fontWeight: "300", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading2, fontSize: "20px", fontWeight: "300", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading3, fontSize: "18px", fontWeight: "400", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading4, fontSize: "16px", fontWeight: "400", color: "var(--heading)", fontFamily: "var(--font-display)", lineHeight: "1.3" },
  { tag: tags.heading5, fontWeight: "600", color: "var(--heading)", fontFamily: "var(--font-display)" },
  { tag: tags.heading6, fontWeight: "600", color: "var(--heading)", fontFamily: "var(--font-display)" },

  // Markdown syntax markers (#, **, *, `, ~~, >, ```)
  { tag: tags.processingInstruction, color: "var(--syntax)", fontFamily: "var(--font-mono)", fontWeight: "400" },

  // Inline formatting
  { tag: tags.strong, fontWeight: "700" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through", color: "var(--muted)" },

  // Code
  { tag: tags.monospace, fontFamily: "var(--font-mono)", fontSize: "0.88em", color: "var(--fg)" },

  // Links
  { tag: tags.link, color: "var(--link)" },
  { tag: tags.url, color: "var(--link)" },

  // Blockquote content
  { tag: tags.quote, color: "var(--muted)", fontStyle: "italic" },

  // Meta (frontmatter delimiters, etc.)
  { tag: tags.meta, color: "var(--syntax)", fontFamily: "var(--font-mono)", fontSize: "0.88em" },

  // HR
  { tag: tags.contentSeparator, color: "var(--chrome-lo)" },
]);

// Base theme — structural overrides only; typography is in app.css
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

// [[wikilinks]] → .cm-wikilink
const wikilinkHighlighter = makeMatchPlugin(new MatchDecorator({
  regexp: /\[\[([^\]]+)\]\]/g,
  decoration: () => Decoration.mark({ class: "cm-wikilink" }),
}));

// Bare URLs → .cm-url
const urlHighlighter = makeMatchPlugin(new MatchDecorator({
  regexp: /https?:\/\/[^\s)>\]]+/g,
  decoration: () => Decoration.mark({ class: "cm-url" }),
}));

// --- Markdown link widget: [text](url) → clickable text ---

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
      const cursorInside = sel.from >= from && sel.from <= to;

      if (!cursorInside) {
        builder.add(from, to, Decoration.replace({
          widget: new LinkWidget(m[1], m[2]),
        }));
      }
    }
  }

  return builder.finish();
}

// --- Table widget: render pipe tables as <table> ---

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
  // lines[1] should be the separator (---|----|---)
  if (!/^[\s|:\-]+$/.test(lines[1])) return null;
  const rows = lines.slice(2).map(splitRow);

  return { header, rows };
}

class TableWidget extends WidgetType {
  constructor(text) {
    super();
    this.text = text;
  }

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

// StateField (not ViewPlugin) because the decoration spans line breaks.
const tableField = StateField.define({
  create(state) {
    return buildTableDecos(state);
  },
  update(decos, tr) {
    if (tr.docChanged || tr.selection) {
      return buildTableDecos(tr.state);
    }
    return decos;
  },
  provide(field) {
    return EditorView.decorations.from(field);
  },
});

function buildTableDecos(state) {
  const builder = new RangeSetBuilder();
  const doc = state.doc;
  const sel = state.selection.main;
  const text = doc.toString();
  const lines = text.split("\n");

  let i = 0;
  let pos = 0;

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
        for (const tl of tableLines) {
          tableEnd += tl.length + 1;
        }
        tableEnd--;

        const cursorInside = sel.from <= tableEnd && sel.to >= tableStart;

        if (!cursorInside) {
          builder.add(
            tableStart,
            tableEnd,
            Decoration.replace({
              widget: new TableWidget(tableText),
              block: true,
            })
          );
        } else {
          // Cursor inside: add .cm-table-source class to each line
          let linePos = tableStart;
          for (const tl of tableLines) {
            builder.add(
              linePos,
              linePos,
              Decoration.line({ class: "cm-table-source" })
            );
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
// Plain click on wikilinks → navigate.
// Plain click on URLs → open in new tab.
// Cursor placement still works on non-link text.

function clickableLinks(navigate) {
  return EditorView.domEventHandlers({
    mousedown(event, view) {
      // Only handle plain left-clicks (no selection drags)
      if (event.button !== 0) return false;

      const target = event.target;

      // Widget link clicks are handled by the widget itself
      if (target.closest(".cm-md-link")) return false;

      // Wikilink click
      const wikilink = target.closest(".cm-wikilink");
      if (wikilink) {
        const text = wikilink.textContent;
        const match = text.match(/\[\[([^\]]+)\]\]/);
        if (match) {
          event.preventDefault();
          navigate(match[1]);
          return true;
        }
      }

      // URL click — scan line for URL at click position
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (pos == null) return false;
      const line = view.state.doc.lineAt(pos);
      const col = pos - line.from;
      const text = line.text;

      // Skip positions inside a markdown [text](url) — the widget handles those
      const mdSkipRe = /\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/g;
      let skip = false;
      let s;
      while ((s = mdSkipRe.exec(text)) !== null) {
        if (col >= s.index && col <= s.index + s[0].length) {
          skip = true;
          break;
        }
      }
      if (skip) return false;

      // Bare URLs only (not inside markdown link parens)
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

// --- Phoenix channel-backed Yjs provider ---

class PhoenixProvider {
  constructor(ydoc, channel) {
    this.ydoc = ydoc;
    this.channel = channel;
    this.synced = false;

    channel.on("sync", ({ data }) => {
      const update = this._decode(data);
      Y.applyUpdate(this.ydoc, update);
      this.synced = true;
    });

    channel.on("update", ({ data }) => {
      const update = this._decode(data);
      Y.applyUpdate(this.ydoc, update, "remote");
    });

    this.ydoc.on("update", (update, origin) => {
      if (origin === "remote") return;
      channel.push("update", { data: this._encode(update) });
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
    this.ydoc.off("update", this._updateHandler);
  }
}

// --- Editor factory ---

export function createEditor(element, recordId, { navigate } = {}) {
  const ydoc = new Y.Doc();
  const ytext = ydoc.getText("content");

  const socket = new Socket("/yjs");
  socket.connect();
  const channel = socket.channel(`doc:${recordId}`);

  const provider = new PhoenixProvider(ydoc, channel);

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
    yCollab(ytext),
    EditorView.lineWrapping,
  ];

  const view = new EditorView({
    state: EditorState.create({ extensions }),
    parent: element,
  });

  channel.join()
    .receive("ok", () => {})
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
