'use strict';

// The brain map, in the style of a knowledge-graph view: small nodes sized by how
// connected they are, faint lines, labels that fade in with zoom, and a hover that
// dims everything but a node and its neighbours. Swift sends the graph with
// setGraph() and the selected id with setSelection(); this page reports clicks back
// as { select: id | null } and { open: id }.
(function () {
  const post = (message) => window.webkit.messageHandlers.brain.postMessage(message);
  const DOUBLE_CLICK_MS = 350;
  const MIN_ZOOM = 0.1;
  const MAX_ZOOM = 8;
  const DIMMED = 0.1;
  const STORAGE_KEY = 'brain.settings';

  // Muted enough to sit on both the light and the dark background.
  const TYPE_COLORS = { user: '90, 176, 246', feedback: '240, 163, 90', project: '123, 211, 137', reference: '197, 138, 249' };

  const DEFAULTS = {
    orphans: true,
    arrows: false,
    colorByType: true,
    labels: 0.8,
    nodeSize: 1,
    linkWidth: 1,
    center: 0.06,
    repel: 90,
    linkForce: 0.35,
    linkDistance: 50,
  };

  const SECTIONS = [
    { title: 'Display', controls: [
      { key: 'colorByType', label: 'Color by type', kind: 'toggle' },
      { key: 'arrows', label: 'Arrows', kind: 'toggle' },
      { key: 'labels', label: 'Label visibility', min: 0, max: 3, step: 0.05 },
      { key: 'nodeSize', label: 'Node size', min: 0.4, max: 2.5, step: 0.05 },
      { key: 'linkWidth', label: 'Link thickness', min: 0.3, max: 3, step: 0.1 },
    ] },
    { title: 'Forces', forces: true, controls: [
      { key: 'center', label: 'Center force', min: 0, max: 0.3, step: 0.005 },
      { key: 'repel', label: 'Repel force', min: 0, max: 300, step: 5 },
      { key: 'linkForce', label: 'Link force', min: 0, max: 1, step: 0.01 },
      { key: 'linkDistance', label: 'Link distance', min: 10, max: 200, step: 1 },
    ] },
  ];

  let settings = loadSettings();
  let graph;
  let rawNodes = [];
  let rawLinks = [];
  let nodes = [];
  let neighbors = new Map();
  let selected = null;
  let hovered = null;
  let query = '';
  let lastClick = { id: null, time: 0 };
  let colors = {};
  let repaintTimer;

  function loadSettings() {
    try {
      return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}') };
    } catch (error) {
      return { ...DEFAULTS };
    }
  }

  function saveSettings() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
    } catch (error) {
      // Settings simply don't persist.
    }
  }

  // force-graph stops painting once the layout settles; fades and setting changes need more frames.
  function redraw() {
    graph.autoPauseRedraw(false);
    clearTimeout(repaintTimer);
    repaintTimer = setTimeout(() => graph.autoPauseRedraw(true), 250);
  }

  function readColors() {
    const css = getComputedStyle(document.documentElement);
    const value = (name) => css.getPropertyValue(name).trim();
    colors = { hi: value('--hi-rgb'), node: value('--node-rgb'), link: value('--link-rgb'), accent: value('--accent-rgb') };
    if (graph) redraw();
  }

  const rgba = (rgb, alpha) => `rgba(${rgb}, ${alpha})`;
  const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
  const focusId = () => hovered || selected;
  const endId = (end) => (typeof end === 'object' ? end.id : end);
  const radius = (node) => Math.min(14, (node.hub ? 8 : 3.5 + Math.sqrt(node.degree) * 1.4) * settings.nodeSize);

  function isLit(id) {
    const focus = focusId();
    return !focus || id === focus || (neighbors.get(focus) || new Set()).has(id);
  }

  // Eases a value toward its target, one frame at a time, so highlighting fades instead of snapping.
  function ease(current, target) {
    const next = current + (target - current) * 0.25;
    if (Math.abs(target - next) < 0.01) return target;
    redraw();
    return next;
  }

  function nodeColor(node) {
    if (node.hub) return colors.accent;
    return (settings.colorByType && TYPE_COLORS[node.type]) || colors.node;
  }

  function drawNode(node, ctx, scale) {
    const focus = focusId();
    const lit = isLit(node.id);
    node.fade = ease(node.fade ?? 1, lit ? 1 : DIMMED);
    const r = radius(node);

    if (node.id === focus) {
      ctx.beginPath();
      ctx.arc(node.x, node.y, r + 5, 0, 2 * Math.PI);
      ctx.fillStyle = rgba(colors.accent, 0.22);
      ctx.fill();
    }
    ctx.beginPath();
    ctx.arc(node.x, node.y, r, 0, 2 * Math.PI);
    ctx.fillStyle = rgba(nodeColor(node), node.fade);
    ctx.fill();
    if (node.id === selected) {
      ctx.beginPath();
      ctx.arc(node.x, node.y, r + 2.5, 0, 2 * Math.PI);
      ctx.strokeStyle = rgba(colors.accent, 1);
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }

    const zoomAlpha = clamp((scale * settings.labels - 0.5) / 0.7, 0, 1);
    const alpha = (focus && lit ? 1 : zoomAlpha) * node.fade;
    if (alpha > 0.02) {
      ctx.font = `${11.5 / scale}px -apple-system, sans-serif`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'top';
      ctx.fillStyle = rgba(colors.hi, alpha * (node.id === focus ? 1 : 0.8));
      ctx.fillText(node.title, node.x, node.y + r + 3 / scale);
    }
  }

  function paintPointerArea(node, color, ctx) {
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(node.x, node.y, radius(node) + 3, 0, 2 * Math.PI);
    ctx.fill();
  }

  function touchesFocus(link) {
    const focus = focusId();
    return !focus || endId(link.source) === focus || endId(link.target) === focus;
  }

  function linkColor(link) {
    const focus = focusId();
    const touches = touchesFocus(link);
    link.fade = ease(link.fade ?? 1, touches ? 1 : DIMMED);
    if (focus && touches) return rgba(colors.accent, 0.85);
    return rgba(colors.link, (link.kind === 'wikilink' ? 0.5 : 0.22) * link.fade);
  }

  function handleClick(node) {
    const now = performance.now();
    if (lastClick.id === node.id && now - lastClick.time < DOUBLE_CLICK_MS) {
      lastClick = { id: null, time: 0 };
      post({ open: node.id });
      return;
    }
    lastClick = { id: node.id, time: now };
    post({ select: node.id });
  }

  // The graph's own center force moves the whole picture; this one pulls nodes in.
  function gravity(alpha) {
    for (const node of nodes) {
      if (node.x == null) continue;
      node.vx -= node.x * settings.center * alpha;
      node.vy -= node.y * settings.center * alpha;
    }
  }

  function applyDisplay() {
    graph
      .linkWidth((link) => (link.kind === 'wikilink' ? 1.1 : 0.8) * settings.linkWidth * (focusId() && touchesFocus(link) ? 1.6 : 1))
      .linkDirectionalArrowLength(settings.arrows ? 4 + 2 * settings.linkWidth : 0);
    redraw();
  }

  function applyForces() {
    graph.d3Force('charge').strength(-settings.repel).distanceMax(600);
    graph.d3Force('link').distance(settings.linkDistance).strength(settings.linkForce);
    graph.d3ReheatSimulation();
  }

  // Search and the orphans toggle decide what is on the map; settled positions are kept.
  function refilter() {
    const needle = query.trim().toLowerCase();
    nodes = rawNodes.filter((node) => (settings.orphans || node.degree > 0) && (!needle || node.title.toLowerCase().includes(needle)));
    const visible = new Set(nodes.map((node) => node.id));
    const links = rawLinks.filter((link) => visible.has(link.source) && visible.has(link.target)).map((link) => ({ ...link }));
    neighbors = new Map();
    for (const { source, target } of links) {
      for (const [a, b] of [[source, target], [target, source]]) {
        if (!neighbors.has(a)) neighbors.set(a, new Set());
        neighbors.get(a).add(b);
      }
    }
    graph.graphData({ nodes, links });
  }

  window.setGraph = function (incoming) {
    const previous = new Map(rawNodes.map((node) => [node.id, node]));
    rawNodes = incoming.nodes.map((node) => Object.assign(previous.get(node.id) || {}, node, { degree: 0 }));
    rawLinks = incoming.links;
    const byId = new Map(rawNodes.map((node) => [node.id, node]));
    for (const { source, target } of rawLinks) {
      byId.get(source).degree += 1;
      byId.get(target).degree += 1;
    }
    renderGroups();
    refilter();
    if (previous.size === 0) setTimeout(() => graph.zoomToFit(0, 80), 150);
  };

  window.setSelection = function (id) {
    selected = id;
    if (graph) redraw();
  };

  // MARK: settings panel

  function row(control, onChange) {
    const element = document.createElement('div');
    if (control.kind === 'toggle') {
      element.className = 'row inline';
      const label = document.createElement('label');
      label.textContent = control.label;
      label.htmlFor = `s-${control.key}`;
      const input = Object.assign(document.createElement('input'), { type: 'checkbox', id: `s-${control.key}`, checked: settings[control.key] });
      input.addEventListener('change', () => onChange(control.key, input.checked));
      element.append(label, input);
      return element;
    }
    element.className = 'row';
    const head = document.createElement('div');
    head.className = 'head';
    const value = document.createElement('span');
    value.textContent = settings[control.key];
    head.append(Object.assign(document.createElement('span'), { textContent: control.label }), value);
    const input = Object.assign(document.createElement('input'), {
      type: 'range', min: control.min, max: control.max, step: control.step, value: settings[control.key], id: `s-${control.key}`,
    });
    input.addEventListener('input', () => {
      value.textContent = input.value;
      onChange(control.key, Number(input.value));
    });
    element.append(head, input);
    return element;
  }

  function buildPanel() {
    const panel = document.getElementById('panel');
    panel.replaceChildren();

    const filters = document.createElement('details');
    filters.open = true;
    filters.innerHTML = '<summary>Filters</summary>';
    const search = Object.assign(document.createElement('input'), { id: 'query', type: 'search', placeholder: 'Search memories…', value: query });
    search.addEventListener('input', () => {
      query = search.value;
      refilter();
    });
    const searchRow = document.createElement('div');
    searchRow.className = 'row';
    searchRow.append(search);
    filters.append(searchRow, row({ key: 'orphans', label: 'Orphans', kind: 'toggle' }, change));
    panel.append(filters);

    for (const section of SECTIONS) {
      const details = document.createElement('details');
      details.open = true;
      details.innerHTML = `<summary>${section.title}</summary>`;
      for (const control of section.controls) details.append(row(control, (key, value) => change(key, value, section.forces)));
      panel.append(details);
    }

    const groups = document.createElement('details');
    groups.id = 'groups';
    groups.open = true;
    panel.append(groups);

    const reset = Object.assign(document.createElement('button'), { id: 'reset', textContent: 'Restore defaults' });
    reset.addEventListener('click', () => {
      settings = { ...DEFAULTS };
      saveSettings();
      buildPanel();
      applyAll();
    });
    panel.append(reset);
    renderGroups();
  }

  function renderGroups() {
    const groups = document.getElementById('groups');
    if (!groups) return;
    const present = Object.keys(TYPE_COLORS).filter((type) => rawNodes.some((node) => node.type === type));
    groups.hidden = !settings.colorByType || present.length === 0;
    groups.innerHTML = '<summary>Types</summary>';
    for (const type of present) {
      const item = document.createElement('div');
      item.className = 'group';
      item.innerHTML = `<i style="background: rgb(${TYPE_COLORS[type]})"></i>`;
      item.append(type);
      groups.append(item);
    }
  }

  function change(key, value, forces) {
    settings[key] = value;
    saveSettings();
    if (key === 'orphans') refilter();
    else if (forces) applyForces();
    else applyDisplay();
    if (key === 'colorByType') renderGroups();
  }

  function applyAll() {
    applyDisplay();
    applyForces();
    refilter();
    renderGroups();
  }

  function create() {
    readColors();
    graph = ForceGraph()(document.getElementById('graph'))
      .backgroundColor('rgba(0,0,0,0)')
      .minZoom(MIN_ZOOM)
      .maxZoom(MAX_ZOOM)
      .nodeId('id')
      .nodeCanvasObject(drawNode)
      .nodePointerAreaPaint(paintPointerArea)
      .linkColor(linkColor)
      .linkDirectionalArrowColor(linkColor)
      .linkDirectionalArrowRelPos(0.55)
      .onNodeClick(handleClick)
      .onNodeHover((node) => {
        hovered = node ? node.id : null;
        document.body.style.cursor = node ? 'pointer' : 'default';
        redraw();
      })
      .onNodeDrag((node) => {
        hovered = node.id;
        redraw();
      })
      .onBackgroundClick(() => post({ select: null }))
      .warmupTicks(120);
    graph.d3Force('center', null);
    graph.d3Force('gravity', gravity);
    applyDisplay();
    applyForces();

    const resize = () => graph.width(window.innerWidth).height(window.innerHeight);
    window.addEventListener('resize', resize);
    resize();

    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', readColors);
    const zoomBy = (factor) => graph.zoom(clamp(graph.zoom() * factor, MIN_ZOOM, MAX_ZOOM), 200);
    document.getElementById('zoom-in').addEventListener('click', () => zoomBy(1.4));
    document.getElementById('zoom-out').addEventListener('click', () => zoomBy(1 / 1.4));
    document.getElementById('fit').addEventListener('click', () => graph.zoomToFit(400, 80));

    const gear = document.getElementById('gear');
    gear.addEventListener('click', () => {
      const panel = document.getElementById('panel');
      panel.hidden = !panel.hidden;
      gear.setAttribute('aria-expanded', String(!panel.hidden));
    });
    buildPanel();
  }

  document.addEventListener('DOMContentLoaded', () => {
    create();
    post({ ready: true });
  });
})();
