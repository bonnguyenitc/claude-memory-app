'use strict';

// Renders markdown the way the editor sees it: GFM, [[wikilinks]], task lists,
// YAML frontmatter, and a data-line attribute on every block for scroll sync.
function createRenderer(markdownit, hljs) {
  const escapeHTML = (text) => text.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

  const md = markdownit({
    html: false,
    linkify: true,
    highlight(code, lang) {
      if (lang && hljs.getLanguage(lang)) {
        return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
      }
      return '';
    },
  });

  md.core.ruler.push('source_lines', (state) => {
    for (const token of state.tokens) {
      if (token.map && token.nesting >= 0) {
        token.attrSet('data-line', String(token.map[0] + state.env.lineOffset));
      }
    }
  });

  md.core.ruler.after('inline', 'task_lists', (state) => {
    const tokens = state.tokens;
    for (let i = 2; i < tokens.length; i++) {
      const inline = tokens[i];
      if (inline.type !== 'inline' || tokens[i - 1].type !== 'paragraph_open' || tokens[i - 2].type !== 'list_item_open') continue;
      const first = inline.children[0];
      const match = first && first.type === 'text' && /^\[([ xX])\]\s/.exec(first.content);
      if (!match) continue;
      first.content = first.content.slice(match[0].length);
      const box = new state.Token('html_inline', '', 0);
      box.content = `<input type="checkbox" disabled${match[1] === ' ' ? '' : ' checked'}> `;
      inline.children.unshift(box);
      tokens[i - 2].attrJoin('class', 'task-list-item');
    }
  });

  md.inline.ruler.before('link', 'wikilink', (state, silent) => {
    const { src, pos } = state;
    if (src.charCodeAt(pos) !== 0x5b || src.charCodeAt(pos + 1) !== 0x5b) return false;
    const end = src.indexOf(']]', pos + 2);
    if (end < 0) return false;
    const inner = src.slice(pos + 2, end);
    if (!inner.trim() || /[[\]\n]/.test(inner)) return false;
    if (!silent) {
      const [target, alias] = inner.split('|');
      state.push('wikilink', '', 0).meta = { target: target.trim(), label: (alias ?? target).trim() };
    }
    state.pos = end + 2;
    return true;
  });

  md.renderer.rules.wikilink = (tokens, idx, options, env) => {
    const { target, label } = tokens[idx].meta;
    const missing = env.names.has(target) ? '' : ' missing';
    const title = missing ? 'No such memory yet' : 'Open memory';
    return `<a href="#" class="wikilink${missing}" data-wiki="${escapeHTML(target)}" title="${title}">${escapeHTML(label)}</a>`;
  };

  return function render(text, names) {
    const lines = text.split('\n');
    let frontmatter = '';
    let offset = 0;
    if (lines[0] === '---') {
      const close = lines.indexOf('---', 1);
      if (close > 0) {
        const yaml = lines.slice(1, close).join('\n');
        frontmatter = `<details class="frontmatter" data-line="0"><summary>Frontmatter</summary><pre>${escapeHTML(yaml)}</pre></details>`;
        offset = close + 1;
      }
    }
    const body = lines.slice(offset).join('\n');
    return frontmatter + md.render(body, { lineOffset: offset, names: new Set(names) });
  };
}

if (typeof document !== 'undefined' && window.markdownit) {
  const renderHTML = createRenderer(window.markdownit, window.hljs);
  const post = (message) => window.webkit?.messageHandlers?.preview?.postMessage(message);

  window.render = (text, names) => {
    document.getElementById('content').innerHTML = renderHTML(text, names);
  };

  // Puts the block for `line` (zero-based, interpolated between blocks) at the top.
  window.scrollToLine = (line) => {
    let previous = null;
    let next = null;
    for (const element of document.querySelectorAll('[data-line]')) {
      const start = Number(element.dataset.line);
      if (previous && start < previous.start) continue;
      if (start <= line) {
        previous = { element, start };
      } else {
        next = { element, start };
        break;
      }
    }
    if (!previous) {
      window.scrollTo(0, 0);
      return;
    }
    const top = (element) => element.getBoundingClientRect().top + window.scrollY;
    let y = top(previous.element);
    if (next && next.start > previous.start) {
      y += (top(next.element) - y) * (line - previous.start) / (next.start - previous.start);
    }
    window.scrollTo(0, Math.max(0, y - 8));
  };

  document.addEventListener('click', (event) => {
    const link = event.target.closest('a');
    if (!link) return;
    event.preventDefault();
    if (link.dataset.wiki) {
      post({ wiki: link.dataset.wiki });
    } else if (link.getAttribute('href')) {
      post({ href: link.getAttribute('href') });
    }
  });

  document.addEventListener('DOMContentLoaded', () => post({ ready: true }));
}
