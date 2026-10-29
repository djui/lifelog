// The archive viewer: plain JS, no libraries, no network. Data arrives as scripts in data/ that call
// window.ARCHIVE.load({...}), because browsers block fetch() from file://. Written by lifelog; edits are overwritten.
'use strict';

(function () {
  const chunks = new Map();   // "source/month" → chunk
  const waiting = new Map();  // "source/month" → [resolve]
  let manifest = null;
  let generation = 0;         // bumps on every route change, so slow chunk loads never paint an old screen

  window.ARCHIVE = {
    load(data) {
      if (data.kind === 'manifest') { manifest = data; return; }
      if (data.kind !== 'chunk') return;
      const id = data.source + '/' + data.month;
      chunks.set(id, data);
      (waiting.get(id) || []).forEach(resolve => resolve(data));
      waiting.delete(id);
    },
  };

  // MARK: Helpers

  function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs || {})) {
      if (value === undefined || value === null || value === false) continue;
      if (key === 'class') el.className = value;
      else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
      else el.setAttribute(key, value === true ? '' : value);
    }
    for (const child of children.flat()) {
      if (child === undefined || child === null || child === false) continue;
      el.append(child instanceof Node ? child : String(child));
    }
    return el;
  }

  const main = () => document.getElementById('main');
  const sourceName = id => (manifest.sources.find(s => s.id === id) || { name: id }).name;
  const plural = (n, word) => n + ' ' + word + (n === 1 ? '' : 's');
  const fold = text => (text || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const GONE = ['deleted', 'expired', 'revoked', 'unknown', 'trashed'];

  function itemHref(key, month) { return '#/item/' + encodeURIComponent(key) + '?m=' + month; }

  function months(from, to) {
    const list = [];
    let [y, m] = from.split('-').map(Number);
    const [ty, tm] = to.split('-').map(Number);
    while (y < ty || (y === ty && m <= tm)) {
      list.push(y + '-' + String(m).padStart(2, '0'));
      if (++m > 12) { m = 1; y++; }
    }
    return list;
  }

  function shiftDay(day, delta) {
    const date = new Date(day + 'T12:00:00Z');
    date.setUTCDate(date.getUTCDate() + delta);
    return date.toISOString().slice(0, 10);
  }

  /// Every chunk the manifest knows, as {source, month}, newest first.
  function allChunks() {
    const list = [];
    for (const source of manifest.sources) for (const month of Object.keys(source.months)) list.push({ source: source.id, month });
    return list.sort((a, b) => (b.month + a.source).localeCompare(a.month + b.source));
  }

  function loadChunk(source, month) {
    const id = source + '/' + month;
    if (chunks.has(id)) return Promise.resolve(chunks.get(id));
    const known = manifest.sources.some(s => s.id === source && s.months[month]);
    if (!known) return Promise.resolve({ source, month, items: [] });
    return new Promise(resolve => {
      const first = !waiting.has(id);
      waiting.set(id, (waiting.get(id) || []).concat(resolve));
      if (!first) return;
      const script = h('script', { src: 'data/' + encodeURIComponent(source) + '/' + month + '.js' });
      script.addEventListener('error', () => {
        (waiting.get(id) || []).forEach(done => done({ source, month, items: [], missing: true }));
        waiting.delete(id);
      });
      document.head.append(script);
    });
  }

  function highlight(text, terms) {
    if (!terms.length || !text) return [text];
    const folded = fold(text);
    const parts = [];
    let at = 0;
    while (at < text.length) {
      let best = -1, length = 0;
      for (const term of terms) {
        const found = folded.indexOf(term, at);
        if (found >= 0 && (best < 0 || found < best)) { best = found; length = term.length; }
      }
      if (best < 0) break;
      parts.push(text.slice(at, best), h('mark', {}, text.slice(best, best + length)));
      at = best + length;
    }
    parts.push(text.slice(at));
    return parts;
  }

  function badges(item) {
    const list = [];
    if (item.state !== 'active') list.push(h('span', { class: 'badge state-' + item.state }, item.state));
    for (const badge of item.badges || []) if (badge !== item.state && !badge.startsWith(item.state + ' ')) list.push(h('span', { class: 'badge' }, badge));
    return list;
  }

  /// One item as a result row: time, who, title/text, badges.
  function row(item, source, month, terms) {
    const gone = GONE.includes(item.state);
    return h('li', { class: 'item' + (gone ? ' gone' : '') + (item.state === 'deleted' || item.state === 'trashed' ? ' struck' : '') },
      h('a', { class: 'time', href: itemHref(item.key, month) }, item.time || '·'),
      h('span', { class: 'source tag-' + source }, sourceName(source)),
      item.group ? h('span', { class: 'group' }, highlight(item.group, terms)) : null,
      item.who ? h('strong', { class: 'who' }, highlight(item.who, terms), ':') : null,
      item.title ? h('span', { class: 'title' }, highlight(item.title, terms)) : null,
      h('span', { class: 'text' }, highlight(short(item.text, item.title ? 160 : 400), terms)),
      badges(item));
  }

  function short(text, limit) {
    const flat = (text || '').replace(/\s+/g, ' ').trim();
    return flat.length <= limit ? flat : flat.slice(0, limit - 1) + '…';
  }

  function select(name, label, values, current, labels) {
    return h('label', {}, label + ' ',
      h('select', { name }, h('option', { value: '' }, 'all'),
        values.map(value => h('option', { value, selected: value === current }, labels ? labels(value) : value))));
  }

  // MARK: Screens

  function coverage() {
    const sources = manifest.sources;
    const every = [];
    for (const s of sources) every.push(...Object.keys(s.months), ...Object.keys(s.runs), ...s.gaps);
    const view = main();
    view.replaceChildren(h('h1', {}, 'Coverage'));
    if (!every.length) { view.append(h('p', { class: 'muted' }, 'The archive is empty.')); return; }
    every.sort();
    const range = months(every[0], every[every.length - 1]);
    const max = Math.max(1, ...sources.flatMap(s => Object.values(s.months).map(total)));
    view.append(h('p', { class: 'muted' },
      'Items per source and month. Darker is more; a red edge marks months with items that disappeared; hatched months had no complete read. Click a month for its timeline.'));
    const table = h('table', { class: 'heatmap' },
      h('thead', {}, h('tr', {}, h('th', {}, ''), range.map(month => h('th', { class: month.endsWith('-01') || month === range[0] ? 'year' : '' },
        month.endsWith('-01') || month === range[0] ? month.slice(0, 4) : '')))),
      h('tbody', {}, sources.map(s => h('tr', {}, h('th', { scope: 'row' }, s.name), range.map(month => {
        const counts = s.months[month] || {};
        const n = total(counts);
        const gone = GONE.reduce((sum, state) => sum + (counts[state] || 0), 0);
        const gap = s.gaps.includes(month);
        const level = n === 0 ? 0 : 1 + Math.min(3, Math.floor(Math.log(n) / Math.log(max + 1) * 4));
        const title = s.name + ' ' + month + ': ' + plural(n, 'item') + (gone ? ', ' + gone + ' gone' : '')
          + (s.runs[month] ? ', ' + plural(s.runs[month], 'complete read') : '') + (gap ? ', no complete read' : '');
        return h('td', { class: 'cell level-' + level + (gone ? ' has-gone' : '') + (gap ? ' gap' : ''), title },
          n ? h('a', { href: '#/timeline/' + month, 'aria-label': title }, '') : '');
      })))));
    view.append(h('div', { class: 'scroll' }, table));
    view.append(h('h2', {}, 'Sources'), h('table', { class: 'list' },
      h('thead', {}, h('tr', {}, ['Source', 'Items', 'Gone', 'Pending', 'Last complete read', 'Mode'].map(t => h('th', {}, t)))),
      h('tbody', {}, sources.map(s => h('tr', {}, h('td', {}, s.name), h('td', { class: 'num' }, s.items), h('td', { class: 'num' }, s.gone),
        h('td', { class: 'num' }, s.pending), h('td', {}, s.lastComplete || 'never'), h('td', {}, s.mode || '–'))))));
  }

  function total(counts) { return Object.values(counts).reduce((a, b) => a + b, 0); }

  function disappeared(params) {
    const source = params.get('source') || '', state = params.get('state') || '';
    const list = manifest.disappeared.filter(g => (!source || g.source === source) && (!state || g.state === state));
    const states = [...new Set(manifest.disappeared.map(g => g.state))].sort();
    const form = h('form', { class: 'filters', onchange: event => {
      const data = new URLSearchParams(new FormData(event.currentTarget));
      for (const [key, value] of [...data]) if (!value) data.delete(key);
      location.hash = '#/disappeared' + (data.toString() ? '?' + data : '');
    } },
      select('source', 'Source', manifest.sources.map(s => s.id), source, sourceName),
      select('state', 'State', states, state));
    main().replaceChildren(h('h1', {}, 'Disappeared'), form,
      h('p', { class: 'muted' }, plural(list.length, 'item') + ', newest first. Each stays in the archive with the last text it had.'),
      list.length ? h('ul', { class: 'gone-list' }, list.map(g => h('li', {},
        h('span', { class: 'badge state-' + g.state }, g.state),
        h('span', { class: 'source tag-' + g.source }, sourceName(g.source)),
        h('a', { href: itemHref(g.key, g.month), class: 'label' }, g.label),
        h('div', { class: 'text' }, g.text),
        h('div', { class: 'muted' }, (g.seen ? 'last seen ' + g.seen + ' → ' : '') + 'noticed ' + g.noticed + (g.reason ? ' · ' + g.reason : ''),
          ' · ', h('a', { href: g.link }, 'Markdown'))))) : h('p', {}, 'Nothing has disappeared.'));
  }

  function search(params, token) {
    const q = params.get('q') || '', source = params.get('source') || '', group = params.get('group') || '';
    const person = params.get('person') || '', state = params.get('state') || '';
    const from = params.get('from') || '', to = params.get('to') || '';
    const groups = source ? (manifest.groups[source] || []) : [...new Set(Object.values(manifest.groups).flat())].sort();
    const states = [...new Set(manifest.sources.flatMap(s => Object.values(s.months).flatMap(Object.keys)))].sort();
    const form = h('form', { class: 'filters', onsubmit: event => {
      event.preventDefault();
      const data = new URLSearchParams(new FormData(event.currentTarget));
      for (const [key, value] of [...data]) if (!value) data.delete(key);
      location.hash = '#/search?' + data;
    } },
      h('input', { type: 'search', name: 'q', value: q, placeholder: 'Search text, titles, people…', autofocus: true }),
      select('source', 'Source', manifest.sources.map(s => s.id), source, sourceName),
      select('group', 'Chat/calendar/list/folder', groups, group),
      select('person', 'Person', manifest.people, person),
      select('state', 'State', states, state),
      h('label', {}, 'From ', h('input', { type: 'date', name: 'from', value: from })),
      h('label', {}, 'To ', h('input', { type: 'date', name: 'to', value: to })),
      h('button', { type: 'submit' }, 'Search'));
    const progress = h('p', { class: 'muted' });
    const results = h('div', { class: 'results' });
    main().replaceChildren(h('h1', {}, 'Search'), form, progress, results);
    const terms = fold(q).split(/\s+/).filter(Boolean);
    if (!terms.length && !group && !person && !state) { progress.textContent = 'Type a word or pick a filter. Months are loaded newest first.'; return; }
    const list = allChunks().filter(c => (!source || c.source === source)
      && (!from || c.month >= from.slice(0, 7)) && (!to || c.month <= to.slice(0, 7)));
    const limit = 1000;
    let found = 0, done = 0;
    const days = new Map();
    function add(item, chunk) {
      let day = days.get(item.day);
      if (!day) {
        day = h('ul', { class: 'items' });
        const section = h('section', { 'data-day': item.day }, h('h3', {}, h('a', { href: '#/timeline/' + item.day }, item.day)), day);
        const after = [...results.children].find(el => el.dataset.day < item.day);
        results.insertBefore(section, after || null);
        days.set(item.day, day);
      }
      day.append(row(item, chunk.source, chunk.month, terms));
    }
    (async () => {
      for (const c of list) {
        const chunk = await loadChunk(c.source, c.month);
        if (token !== generation) return;
        for (const item of chunk.items) {
          if (found >= limit) break;
          if ((from && item.day < from) || (to && item.day > to)) continue;
          if (group && item.group !== group) continue;
          if (person && item.who !== person) continue;
          if (state && item.state !== state) continue;
          const haystack = fold([item.title, item.text, item.who, item.group].join('\n'));
          if (!terms.every(term => haystack.includes(term))) continue;
          found++;
          add(item, chunk);
        }
        done++;
        progress.textContent = plural(found, 'result') + (found >= limit ? ' (first ' + limit + ')' : '') + ' · searched ' + done + ' of ' + plural(list.length, 'month');
        if (found >= limit) return;
      }
    })();
  }

  function timeline(rest, token) {
    const every = allChunks().map(c => c.month);
    // The latest month up to today; calendar months ahead only when nothing is older.
    const past = every.filter(m => m <= today().slice(0, 7)).sort(), all = every.slice().sort();
    const latest = past.length ? past[past.length - 1] : all[all.length - 1];
    if (!rest) { if (latest) location.replace('#/timeline/' + latest); else main().replaceChildren(h('h1', {}, 'Timeline'), h('p', {}, 'The archive is empty.')); return; }
    if (/^\d{4}-\d{2}$/.test(rest)) return timelineMonth(rest, token);
    if (/^\d{4}-\d{2}-\d{2}$/.test(rest)) return timelineDay(rest, token);
    notFound();
  }

  function today() {
    const now = new Date();
    return new Date(now.getTime() - now.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  }

  async function monthItems(month, token) {
    const loaded = await Promise.all(manifest.sources.map(s => loadChunk(s.id, month)));
    if (token !== generation) return null;
    return loaded.flatMap(chunk => chunk.items.map(item => ({ item, chunk })));
  }

  async function timelineMonth(month, token) {
    const [y, m] = month.split('-').map(Number);
    const prev = m === 1 ? (y - 1) + '-12' : y + '-' + String(m - 1).padStart(2, '0');
    const next = m === 12 ? (y + 1) + '-01' : y + '-' + String(m + 1).padStart(2, '0');
    main().replaceChildren(h('h1', {}, 'Timeline · ' + month), pager('#/timeline/' + prev, prev, '#/timeline/' + next, next), h('p', { class: 'muted' }, 'Loading…'));
    const items = await monthItems(month, token);
    if (!items) return;
    const byDay = new Map();
    for (const { item, chunk } of items) {
      const day = byDay.get(item.day) || {};
      day[chunk.source] = (day[chunk.source] || 0) + 1;
      day.gone = (day.gone || 0) + (GONE.includes(item.state) ? 1 : 0);
      byDay.set(item.day, day);
    }
    const days = [...byDay.keys()].sort();
    main().replaceChildren(h('h1', {}, 'Timeline · ' + month), pager('#/timeline/' + prev, prev, '#/timeline/' + next, next),
      days.length ? h('table', { class: 'list' }, h('tbody', {}, days.map(day => h('tr', {},
        h('td', {}, h('a', { href: '#/timeline/' + day }, day)),
        h('td', {}, manifest.sources.filter(s => byDay.get(day)[s.id]).map(s => h('span', { class: 'source tag-' + s.id }, s.name + ' ' + byDay.get(day)[s.id]))),
        h('td', {}, byDay.get(day).gone ? h('span', { class: 'badge state-deleted' }, byDay.get(day).gone + ' gone') : ''))))) : h('p', {}, 'Nothing archived this month.'));
  }

  function pager(prevHref, prevLabel, nextHref, nextLabel, up) {
    return h('nav', { class: 'pager' }, h('a', { href: prevHref }, '← ' + prevLabel), up || '', h('a', { href: nextHref }, nextLabel + ' →'));
  }

  async function timelineDay(day, token) {
    const month = day.slice(0, 7);
    const nav = pager('#/timeline/' + shiftDay(day, -1), shiftDay(day, -1), '#/timeline/' + shiftDay(day, 1), shiftDay(day, 1), h('a', { href: '#/timeline/' + month }, month));
    main().replaceChildren(h('h1', {}, 'Timeline · ' + day), nav, h('p', { class: 'muted' }, 'Loading…'));
    const items = await monthItems(month, token);
    if (!items) return;
    const shown = items.filter(({ item }) => item.day === day);
    const view = [h('h1', {}, 'Timeline · ' + day), nav];
    if (!shown.length) view.push(h('p', {}, 'Nothing archived on this day.'));
    for (const source of manifest.sources) {
      const list = shown.filter(({ chunk }) => chunk.source === source.id).map(({ item }) => item)
        .sort((a, b) => (a.time || '').localeCompare(b.time || '') || a.key.localeCompare(b.key));
      if (!list.length) continue;
      view.push(h('h2', {}, source.name));
      // Messages and AI chats collapse per chat; everything else is listed.
      if (list.every(item => item.who !== undefined || item.title === undefined)) {
        const byGroup = new Map();
        for (const item of list) byGroup.set(item.group || '', (byGroup.get(item.group || '') || []).concat(item));
        for (const [group, entries] of [...byGroup].sort((a, b) => a[0].localeCompare(b[0]))) {
          const gone = entries.filter(item => GONE.includes(item.state)).length;
          view.push(h('details', {}, h('summary', {}, group || source.name, ' · ', plural(entries.length, 'message'), gone ? h('span', { class: 'badge state-deleted' }, gone + ' gone') : ''),
            h('ul', { class: 'items' }, entries.map(item => row(item, source.id, month, [])))));
        }
      } else {
        view.push(h('ul', { class: 'items' }, list.map(item => row(item, source.id, month, []))));
      }
    }
    main().replaceChildren(...view);
  }

  async function itemScreen(rest, params, token) {
    const key = decodeURIComponent(rest);
    const source = key.split('/')[0], month = params.get('m') || '';
    main().replaceChildren(h('h1', {}, 'Item'), h('p', { class: 'muted' }, 'Loading…'));
    const chunk = await loadChunk(source, month);
    if (token !== generation) return;
    const item = chunk.items.find(i => i.key === key);
    if (!item) { main().replaceChildren(h('h1', {}, 'Item'), h('p', {}, 'This item is not in ' + sourceName(source) + ' ' + month + '.')); return; }
    main().replaceChildren(
      h('p', { class: 'crumbs' }, h('a', { href: '#/timeline/' + item.day }, item.day), ' · ', sourceName(source), item.group ? ' · ' + item.group : ''),
      h('h1', { class: item.state === 'deleted' || item.state === 'trashed' ? 'struck' : '' }, item.title || (item.who ? item.who : sourceName(source))),
      h('p', {}, badges(item)),
      h('dl', { class: 'facts' },
        fact('When', item.day + (item.time ? ' ' + item.time : '')),
        fact('From', item.who), fact('In', item.group), fact('State', item.state),
        fact('Last seen', item.seen), fact('Noticed', item.noticed), fact('Reason', item.reason)),
      h('pre', { class: 'body' }, item.text),
      h('h2', {}, 'History'),
      item.history.length ? h('table', { class: 'list' }, h('tbody', {}, item.history.map(e => h('tr', {},
        h('td', {}, e.at), h('td', {}, h('span', { class: 'badge state-' + e.what }, e.what)), h('td', {}, e.detail || ''))))) : h('p', { class: 'muted' }, 'No ledger events.'),
      h('p', {}, h('a', { href: item.link }, 'Open the Markdown page')));
  }

  function fact(label, value) { return value ? [h('dt', {}, label), h('dd', {}, value)] : null; }

  function notFound() { main().replaceChildren(h('h1', {}, 'Not found'), h('p', {}, h('a', { href: '#/coverage' }, 'Back to coverage'))); }

  // MARK: Routing

  function route() {
    const token = ++generation;
    if (!manifest) return;
    const hash = location.hash.replace(/^#\/?/, '') || 'coverage';
    const [path, query] = hash.split('?');
    const params = new URLSearchParams(query || '');
    const [name, ...rest] = path.split('/');
    for (const link of document.querySelectorAll('nav a[data-route]')) link.classList.toggle('active', link.dataset.route === name);
    window.scrollTo(0, 0);
    switch (name) {
      case 'coverage': return coverage();
      case 'disappeared': return disappeared(params);
      case 'search': return search(params, token);
      case 'timeline': return timeline(rest.join('/'), token);
      case 'item': return itemScreen(rest.join('/'), params, token);
      default: return notFound();
    }
  }

  window.addEventListener('hashchange', route);
  document.addEventListener('DOMContentLoaded', () => {
    if (manifest) {
      const status = document.getElementById('status');
      status.replaceChildren(manifest.demo ? h('span', { class: 'badge demo' }, 'Demo: synthetic data') : '', manifest.updated ? ' Last run ' + manifest.updated : '');
    }
    route();
  });
})();
