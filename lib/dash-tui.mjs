// dash-tui — shared ANSI/rendering/navigation engine for the *-dash tools
// (linear-dash, github-dash). Dependency-free (node builtins only). Pure
// functions operating on the shared "item" shape both tools produce:
//   { kind: 'fixed'|'section'|'row'|'blank'|'sep'|'note', text, section?, meta? }
// so a new dash tool gets scrolling, section-jump nav, and search for free by
// producing that shape and calling viewport()/scrollView().

// ---------- ANSI ----------
export const useColor = !process.env.NO_COLOR;
export const c = (code, s) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : s);
export const bold = (s) => c('1', s);
export const dim = (s) => c('2', s);
export const red = (s) => c('31', s);
export const green = (s) => c('32', s);
export const yellow = (s) => c('33', s);
export const blue = (s) => c('34', s);
export const magenta = (s) => c('35', s);
export const cyan = (s) => c('36', s);

// Clickable text via OSC 8 hyperlinks (ESC]8;;URL BEL text ESC]8;; BEL). Gated on
// a TTY: unsupported terminals or non-tty pipes (e.g. external `watch`) get plain
// text. Supported in iTerm2, modern Terminal.app, kitty, WezTerm, VS Code, etc.
export const useLinks = !process.env.NO_HYPERLINKS && Boolean(process.stdout.isTTY);
export const link = (url, s) => (url && useLinks ? `\x1b]8;;${url}\x07${s}\x1b]8;;\x07` : s);

export const stripAnsi = (s) => s.replace(/\x1b\]8;;.*?\x07/g, '').replace(/\x1b\[[0-9;]*m/g, '');
export const visLen = (s) => stripAnsi(s).length;
export const padEnd = (s, n) => s + ' '.repeat(Math.max(0, n - visLen(s)));
export const truncate = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);

// Clip a string to `max` visible columns, preserving (not counting) ANSI color and
// OSC 8 hyperlink escapes, so a too-wide line never wraps and breaks the TUI's
// one-row-per-line math. Closes any open color/link at the cut so it can't bleed.
export function clampWidth(s, max) {
  if (max <= 0 || visLen(s) <= max) {
    return s;
  }
  let out = '';
  let w = 0;
  let linkOpen = false;
  for (let i = 0; i < s.length && w < max - 1; ) {
    if (s[i] === '\x1b') {
      const csi = /^\x1b\[[0-9;]*m/.exec(s.slice(i));
      if (csi) {
        out += csi[0];
        i += csi[0].length;
        continue;
      }
      const osc = /^\x1b\]8;;.*?\x07/.exec(s.slice(i));
      if (osc) {
        out += osc[0];
        i += osc[0].length;
        linkOpen = osc[0] !== '\x1b]8;;\x07';
        continue;
      }
    }
    out += s[i];
    i++;
    w++;
  }
  out += '…';
  if (linkOpen) {
    out += '\x1b]8;;\x07';
  }
  return `${out}\x1b[0m`;
}

// ---------- text ----------
export function relTime(iso) {
  const ms = Date.now() - Date.parse(iso);
  if (!Number.isFinite(ms)) {
    return '';
  }
  const mins = Math.round(ms / 60000);
  if (mins < 60) {
    return `${Math.max(0, mins)}m ago`;
  }
  const hrs = Math.round(mins / 60);
  if (hrs < 24) {
    return `${hrs}h ago`;
  }
  return `${Math.round(hrs / 24)}d ago`;
}

// Word-wrap plain text (no ANSI) to `width`, preserving blank lines.
export function wrapText(text, width) {
  const lines = [];
  for (const para of String(text).replace(/\r/g, '').split('\n')) {
    if (!para.trim()) {
      lines.push('');
      continue;
    }
    let cur = '';
    for (const word of para.split(/\s+/)) {
      if (cur && cur.length + 1 + word.length > width) {
        lines.push(cur);
        cur = word;
      } else {
        cur = cur ? `${cur} ${word}` : word;
      }
    }
    if (cur) {
      lines.push(cur);
    }
  }
  return lines;
}

// ---------- list navigation ----------
// Row index (in selection space) at which each section begins — drives h/l jumps.
export function sectionStarts(items) {
  const starts = [];
  let r = -1;
  let prev = null;
  for (const it of items) {
    if (it.kind === 'row') {
      r++;
      if (it.section !== prev) {
        starts.push(r);
        prev = it.section;
      }
    }
  }
  return starts;
}

// Scrolling view for --watch: fixed top header, the visible body slice (selected
// row marked), and a footer. A sticky section header appears ONLY when the selected
// row's own section header has scrolled above the top of the viewport — when it's
// still visible there's nothing to pin. `nav` ({ sel, top }) persists scroll state.
// Every emitted line is clamped to the terminal width so nothing wraps.
export function viewport(items, nav, termRows, termCols, footerHint) {
  const fixed = items.filter((i) => i.kind === 'fixed');
  const body = items.filter((i) => i.kind !== 'fixed');
  const rowIdx = [];
  body.forEach((it, i) => {
    if (it.kind === 'row') {
      rowIdx.push(i);
    }
  });
  const nRows = rowIdx.length;
  const mark = (it) => `  ${cyan(bold('❯'))} ${it.text.slice(4)}`;
  const cols = termCols || 200;
  const finish = (lines) => lines.map((l) => clampWidth(l, cols)).join('\n');
  const out = fixed.map((f) => f.text);
  const avail = Math.max(3, (termRows || 40) - fixed.length - 1); // - footer

  if (nRows === 0) {
    out.push(...body.slice(0, avail).map((it) => it.text));
    out.push(dim(footerHint));
    return finish(out);
  }

  nav.sel = Math.max(0, Math.min(nav.sel, nRows - 1));
  const selBody = rowIdx[nav.sel];
  const selItem = body[selBody];
  const footer = dim(footerHint) + dim(`  [${nav.sel + 1}/${nRows}]`);

  // Fits on screen: render everything, no scroll, no sticky header.
  if (body.length <= avail) {
    nav.top = 0;
    for (const it of body) {
      out.push(it === selItem ? mark(it) : it.text);
    }
    out.push(footer);
    return finish(out);
  }

  // Index of the selected row's section header (the nearest 'section' item above it).
  let headerIdx = 0;
  for (let i = selBody; i >= 0; i--) {
    if (body[i].kind === 'section') {
      headerIdx = i;
      break;
    }
  }

  // First pass: scroll using the full height (no sticky reserved).
  const scroll = (height) => {
    let top = nav.top || 0;
    if (selBody < top) {
      top = selBody;
    }
    if (selBody >= top + height) {
      top = selBody - height + 1;
    }
    return Math.max(0, Math.min(top, Math.max(0, body.length - height)));
  };
  let top = scroll(avail);
  // Pin the header only if it's scrolled above the viewport. Showing it costs a row,
  // so recompute the scroll window against the reduced height.
  const sticky = headerIdx < top;
  if (sticky) {
    top = scroll(avail - 1);
    out.push(selItem.section);
  }
  nav.top = top;

  const height = sticky ? avail - 1 : avail;
  for (const it of body.slice(top, top + height)) {
    out.push(it === selItem ? mark(it) : it.text);
  }
  out.push(footer);
  return finish(out);
}

// Fixed header + width-clamped scrollable body + footer, for a details/drill-down
// page. Returns the frame and the max scroll offset so the caller can clamp its
// stored scroll position.
export function scrollView(header, body, scroll, termRows, termCols, footerHint) {
  const cols = termCols || 200;
  const clamp = (l) => clampWidth(l, cols);
  const avail = Math.max(3, (termRows || 40) - header.length - 1); // - footer
  const maxScroll = Math.max(0, body.length - avail);
  const top = Math.max(0, Math.min(scroll, maxScroll));
  const out = header.map(clamp);
  for (const l of body.slice(top, top + avail)) {
    out.push(clamp(l));
  }
  const pos = body.length > avail ? dim(`  [${top + 1}-${Math.min(top + avail, body.length)}/${body.length}]`) : '';
  out.push(dim(footerHint) + pos);
  return { frame: out.join('\n'), maxScroll };
}

// ---------- incremental search over a row list ----------
// `rowTexts` — ANSI-stripped, lowercased text per row (same order as the list's
// row items) — the caller builds this from its own items so this stays generic.
export function computeSearchMatches(rowTexts, query) {
  const q = query.trim().toLowerCase();
  return q ? rowTexts.flatMap((t, i) => (t.includes(q) ? [i] : [])) : [];
}

export function jumpToMatch(matches, sel) {
  if (!matches.length) {
    return sel;
  }
  return matches.find((i) => i >= sel) ?? matches[0];
}

export function cycleMatch(matches, sel, dir) {
  if (!matches.length) {
    return sel;
  }
  let pos = matches.indexOf(sel);
  if (pos === -1) {
    // selection isn't on a match (it moved) — pick the nearest match in `dir`, wrapping.
    if (dir > 0) {
      const f = matches.findIndex((i) => i > sel);
      pos = f === -1 ? 0 : f;
    } else {
      let f = -1;
      matches.forEach((i, k) => {
        if (i < sel) {
          f = k;
        }
      });
      pos = f === -1 ? matches.length - 1 : f;
    }
  } else {
    pos = (pos + dir + matches.length) % matches.length;
  }
  return matches[pos];
}

export function jumpSection(items, sel, dir) {
  const starts = sectionStarts(items);
  if (starts.length === 0) {
    return sel;
  }
  let cur = 0;
  for (let i = 0; i < starts.length; i++) {
    if (starts[i] <= sel) {
      cur = i;
    }
  }
  return starts[Math.max(0, Math.min(starts.length - 1, cur + dir))];
}

// ---------- alt-screen watch mode ----------
export const onTty = () => Boolean(process.stdout.isTTY);
export const enterAltScreen = () => onTty() && process.stdout.write('\x1b[?1049h\x1b[?25l'); // alt screen + hide cursor
export const leaveAltScreen = () => onTty() && process.stdout.write('\x1b[?25h\x1b[?1049l'); // show cursor + primary screen

// Home, redraw with each line cleared to its end (\x1b[K) so a shorter line never
// leaves remnants from the previous frame, then erase any rows below (\x1b[J).
export const writeFrame = (frame) => {
  process.stdout.write(`\x1b[H${frame.replace(/\n/g, '\x1b[K\n')}\x1b[K\x1b[J`);
};

export const halfPage = () => Math.max(1, Math.floor(((process.stdout.rows || 40) - 4) / 2));
