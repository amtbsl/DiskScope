"use strict";
const $ = (s) => document.querySelector(s),
  $$ = (s) => Array.from(document.querySelectorAll(s));
const escapeHTML = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const fmt = (n, rate = false) => {
  if (n == null) return "—";
  const units = rate
    ? ["B/s", "KB/s", "MB/s", "GB/s"]
    : ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) {
    n /= 1000;
    i++;
  }
  return `${n.toLocaleString("en-US", { maximumFractionDigits: i > 1 ? 2 : 0 })} ${units[i]}`;
};
const fmtMemory = (n) => {
  if (n == null) return "—";
  const units = ["B", "KiB", "MiB", "GiB"];
  let i = 0;
  while (n >= 1024 && i < 3) {
    n /= 1024;
    i++;
  }
  return `${n.toLocaleString("en-US", { maximumFractionDigits: i > 1 ? 2 : 0 })} ${units[i]}`;
};
const icons = {
  drive:
    '<path d="M4 9l3-5h10l3 5v10H4z"/><path d="M4 10h16M7 15h.1M11 15h.1"/>',
  home: '<path d="M3 11l9-8 9 8v9h-6v-7H9v7H3z"/>',
  folder: '<path d="M3 6h6l2 3h10l-3 11H3z"/><path d="M3 9V4h6l2 2h9v3"/>',
  apps: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M7 6h.1M10 6h.1"/>',
  search: '<circle cx="10" cy="10" r="6"/><path d="M15 15l6 6"/>',
  pulse: '<path d="M2 12h5l3-9 4 18 3-9h5"/>',
  palette:
    '<path d="M12 3a9 9 0 100 18c3 0 2-3 1-4s0-3 3-3c6 0 6-11-4-11z"/><path d="M6 10h.1M9 6h.1M14 6h.1M18 9h.1"/>',
  trash: '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M9 10v7M15 10v7"/>',
  shield:
    '<path d="M12 2l9 4v7c-1 4-5 7-9 9-4-2-8-5-9-9V6z"/><path d="M8 12l3 3 5-6"/>',
  code: '<path d="M8 5l-6 7 6 7M16 5l6 7-6 7"/>',
  box: '<path d="M12 2l10 5v10l-10 5-10-5V7zM2 7l10 5 10-5M12 12v10M7 4l10 5"/>',
  hammer: '<path d="M5 3h10l4 4-3 3-4-4-2 2-3-3zM10 9l3 3-9 9-3-3z"/>',
  phone:
    '<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',
  video:
    '<rect x="2" y="5" width="14" height="14" rx="2"/><path d="M16 9l6-3v12l-6-3"/>',
  file: '<path d="M5 2h9l5 5v15H5zM14 2v6h5"/>',
  archive:
    '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M10 3v10h4v5h-4v-5M12 5h2M10 8h2M12 11h2"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
  wifi: '<path d="M2 7c6-6 14-6 20 0M5 11c4-4 10-4 14 0M8 15c2-2 6-2 8 0M12 19h.1"/>',
  power: '<path d="M13 2L4 14h7l-1 8 10-13h-8z"/>',
  eye: '<path d="M2 12c5-9 15-9 20 0-5 9-15 9-20 0z"/><circle cx="12" cy="12" r="3"/>',
  plus: '<path d="M12 4v16M4 12h16"/>',
  refresh: '<path d="M20 8V3l-3 3a8 8 0 10 3 10M20 8h-5"/>',
  export: '<path d="M12 15V2M7 7l5-5 5 5M4 13v8h16v-8"/>',
};
const icon = (name) =>
  `<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name] || icons.file}</svg>`;
function hydrate() {
  $$("[data-icon]").forEach((el) => {
    el.innerHTML = icon(el.dataset.icon);
    el.removeAttribute("data-icon");
  });
}
let requestID = 0;
const pending = new Map();
window.receive = (message) => {
  const p = pending.get(message.id);
  if (!p) return;
  clearTimeout(p.timer);
  pending.delete(message.id);
  message.error
    ? p.reject(new Error(message.error))
    : p.resolve(message.result);
};
function native(action, args = {}) {
  return new Promise((resolve, reject) => {
    const id = String(++requestID);
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error("The operation timed out. Please try again."));
    }, 240000);
    pending.set(id, { resolve, reject, timer });
    window.webkit.messageHandlers.native.postMessage({ id, action, args });
  });
}
let toastTimer, mapClickTimer;
function toast(message) {
  $("#toast").textContent = message;
  $("#toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => ($("#toast").hidden = true), 5500);
}
function error(e) {
  toast(e.message || String(e));
}
let view = "home",
  mode = "map",
  currentNode = 0,
  scanRoot = "",
  browseData = null,
  selected = null,
  filters = new Set(),
  fileType = "",
  searchToken = 0,
  appToken = 0,
  scanTimer = null,
  monitorTimer = null,
  apps = [];
const nodeRegistry = new Map();
let queue = [];
try {
  queue = JSON.parse(localStorage.getItem("queue") || "[]").filter(
    (x) => x && typeof x.path === "string",
  );
} catch {}
function saveQueue() {
  localStorage.setItem("queue", JSON.stringify(queue));
  $("#queueCount").textContent = queue.length;
}
function addQueue(entry) {
  if (!entry) return;
  if (
    queue.some(
      (e) => e.path === entry.path || entry.path.startsWith(e.path + "/"),
    )
  ) {
    toast("Already included in your queue");
    return;
  }
  queue = queue.filter((e) => !e.path.startsWith(entry.path + "/"));
  queue.push({ path: entry.path, name: entry.name, size: entry.size || 0 });
  saveQueue();
  toast(`${entry.name} added to the cleanup queue`);
}
function resetSelection() {
  clearTimeout(mapClickTimer);
  selected = null;
  $("#tooltip").hidden = true;
  $("#context").hidden = true;
}
function register(entry) {
  if (!entry) return;
  nodeRegistry.set(entry.id, entry);
  (entry.children || []).forEach(register);
}
function switching(next) {
  clearTimeout(mapClickTimer);
  view = next;
  clearInterval(monitorTimer);
  monitorTimer = null;
  $("#tooltip").hidden = true;
  $("#context").hidden = true;
  $("#appsView").classList.toggle("active", next === "apps");
  $("#monitorView").classList.toggle("active", next === "monitor");
}
function displayLoading(title, sub = "") {
  $("#main").innerHTML =
    `<div class="loading"><div class="spinner"></div><h2>${escapeHTML(title)}</h2><p>${escapeHTML(sub)}</p></div>`;
}
const filterItems = [
  ["Node.js", "box"],
  ["Xcode", "hammer"],
  ["Build Artifacts", "folder"],
  ["Android", "phone"],
  ["Docker", "box"],
  ["Videos", "video"],
  ["Disk Images", "file"],
  ["Archives", "archive"],
  ["iOS Backups", "phone"],
  ["Virtual Machines", "apps"],
  ["Large Media", "video"],
  ["Logs & Caches", "folder"],
  ["AI Models", "cpu"],
];
const colors = {
  Video: "#3b82f6",
  Image: "#f59e0b",
  Doc: "#8b5cf6",
  Dev: "#22c55e",
  Archive: "#ef4444",
  Other: "#6b7280",
};
$("#filterList").innerHTML = filterItems
  .map(
    ([name, symbol]) =>
      `<label class="filterRow"><input type="checkbox" value="${name}">${icon(symbol)}<span>${name}</span></label>`,
  )
  .join("");
$("#legendList").innerHTML = Object.entries(colors)
  .map(
    ([name, color]) =>
      `<button data-type="${name}"><i class="dot" style="background:${color}"></i>${name}</button>`,
  )
  .join("");
$("#filterList").addEventListener("change", (e) => {
  e.target.checked
    ? filters.add(e.target.value)
    : filters.delete(e.target.value);
  showSearch();
});
$("#legendList").addEventListener("click", (e) => {
  const b = e.target.closest("[data-type]");
  if (!b) return;
  fileType = fileType === b.dataset.type ? "" : b.dataset.type;
  $$("[data-type]").forEach((x) =>
    x.classList.toggle("active", x.dataset.type === fileType),
  );
  showSearch();
});
$("#clearFilters").onclick = () => {
  filters.clear();
  fileType = "";
  $$(".filterRow input").forEach((x) => (x.checked = false));
  $$("[data-type]").forEach((x) => x.classList.remove("active"));
  if (scanRoot) browse(currentNode);
};
async function disk() {
  try {
    const d = await native("disk"),
      percent = d.total ? Math.round((d.used / d.total) * 100) : 0;
    $("#diskPercent").textContent = percent + "%";
    $("#diskTotal").textContent = fmt(d.total);
    $("#diskUsed").textContent = fmt(d.used);
    $("#diskFree").textContent = fmt(d.free);
    $("#ring").style.background =
      `conic-gradient(var(--orange) ${percent}%,var(--raised) 0)`;
    $("#diskBar").style.width = percent + "%";
    $("#trashCount").textContent =
      d.trashCount == null ? "access needed" : `${d.trashCount} items`;
  } catch (e) {
    error(e);
  }
}
async function startScan(path, choose = false) {
  try {
    const result = await native(choose ? "choose" : "scan", { path });
    if (!result.started) return;
    startProgress();
  } catch (e) {
    error(e);
  }
}
function startProgress() {
  switching("scanning");
  resetSelection();
  $("#main").innerHTML =
    `<div class="loading"><div class="spinner"></div><h2>Scanning...</h2><div class="scanPath" id="scanPath">Analyzing your storage...</div><div class="progressTrack"><i></i></div><p id="scanCount">Reading files and folders</p><button id="cancelScan">Cancel Scan</button></div>`;
  $("#cancelScan").onclick = async () => {
    await native("cancel");
    clearInterval(scanTimer);
    scanTimer = null;
    toast("Scan cancelled. Previous results are kept.");
    if (scanRoot) browse(currentNode);
    else showWelcome();
  };
  clearInterval(scanTimer);
  scanTimer = setInterval(async () => {
    try {
      const s = await native("status");
      if ($("#scanPath"))
        $("#scanPath").textContent = s.current || "Reading folder...";
      if ($("#scanCount"))
        $("#scanCount").textContent =
          `${(s.count || 0).toLocaleString()} entries · ${s.skipped || 0} inaccessible paths`;
    } catch (e) {
      error(e);
    }
  }, 700);
}
window.scanFinished = async (result) => {
  clearInterval(scanTimer);
  scanTimer = null;
  scanRoot = result.root;
  currentNode = 0;
  nodeRegistry.clear();
  resetSelection();
  $("#search").value = "";
  filters.clear();
  fileType = "";
  $$(".filterRow input").forEach((x) => (x.checked = false));
  $$("[data-type]").forEach((x) => x.classList.remove("active"));
  await browse(0);
  disk();
  if (result.limited)
    toast(
      "Partial scan: the 2 million entry or depth limit was reached. Scan a smaller folder for full detail.",
    );
};
function showWelcome() {
  switching("home");
  $("#main").innerHTML =
    `<div class="welcome"><div class="heroIcon">${icon("drive")}</div><h1>DiskScope</h1><p>Visualize your disk usage with an interactive treemap.</p><div class="welcomeActions"><button class="primary" id="welcomeScan">${icon("home")}Scan Home Folder</button><button id="welcomeChoose">${icon("folder")}Choose Folder</button></div><div class="welcomeMeta">Storage map · Power search · App cleanup · Live monitor</div></div>`;
  bindWelcome();
}
function bindWelcome() {
  $("#welcomeScan").onclick = () => startScan("home");
  $("#welcomeChoose").onclick = () => startScan("", true);
}
async function browse(id = 0, offset = 0) {
  try {
    switching("disk");
    resetSelection();
    currentNode = id;
    const data = await native("browse", { node: id, offset });
    if (data.empty) {
      showWelcome();
      return;
    }
    browseData = data;
    register(data.tree);
    data.children.forEach(register);
    renderBrowser(offset);
  } catch (e) {
    error(e);
  }
}
function browserToolbar() {
  return `<div class="toolbar"><div class="breadcrumbs">${browseData.ancestors.map((e, i) => `${i ? "<span>›</span>" : ""}<button data-browse="${e.id}" title="${escapeHTML(e.path)}">${escapeHTML(e.name)}</button>`).join("")}</div><button data-mode="map" class="${mode === "map" ? "active" : ""}">Treemap</button><button data-mode="list" class="${mode === "list" ? "active" : ""}">List</button><button id="largeFiles">Large Files</button><button id="rescan" title="Rescan">${icon("refresh")}</button><button id="export" title="Export report">${icon("export")}</button></div>`;
}
function renderBrowser(offset = 0) {
  if (view !== "disk" || !browseData) return;
  const d = browseData;
  $("#main").innerHTML =
    browserToolbar() +
    `<div class="scanSummary"><span>${fmt(d.node.size)} allocated · ${d.node.count.toLocaleString()} entries</span>${d.skipped ? `<span class="warning" id="scanWarning">${d.skipped} inaccessible paths</span>` : ""}${d.limited ? '<span class="warning">Partial scan · scan a smaller folder</span>' : ""}<span class="spacer"></span></div>` +
    (mode === "map"
      ? '<div class="mapWrap"><svg id="treemap" role="group" aria-label="Interactive disk usage treemap"></svg></div>'
      : `<div class="listWrap">${fileTable(d.children)}${d.totalChildren > 400 ? `<div class="dialogFooter"><button id="previousPage" ${offset === 0 ? "disabled" : ""}>Previous</button><span>${offset + 1}–${Math.min(offset + 400, d.totalChildren)} / ${d.totalChildren}</span><button id="nextPage" ${offset + 400 >= d.totalChildren ? "disabled" : ""}>Next</button></div>` : ""}</div>`);
  $("#main")
    .querySelectorAll("[data-browse]")
    .forEach((b) => (b.onclick = () => browse(Number(b.dataset.browse))));
  $$("[data-mode]").forEach(
    (b) =>
      (b.onclick = () => {
        mode = b.dataset.mode;
        renderBrowser(offset);
      }),
  );
  $("#rescan").onclick = () => startScan(scanRoot);
  $("#largeFiles").onclick = () => showSearch(true);
  $("#export").onclick = exportReport;
  if ($("#scanWarning")) $("#scanWarning").onclick = showPermissions;
  if ($("#previousPage"))
    $("#previousPage").onclick = () =>
      browse(currentNode, Math.max(0, offset - 400));
  if ($("#nextPage"))
    $("#nextPage").onclick = () => browse(currentNode, offset + 400);
  if (mode === "map") drawMap();
  bindRows();
}
// Muted folder fills sampled from the installed reference's default dark view.
// Keep familiar system folders consistent across nesting and rescans.
const folderColors = {
  blue: "#3b5a80",
  gray: "#5a6578",
  green: "#497b59",
  brown: "#6b5949",
  purple: "#6d4c73",
  teal: "#496a7b",
  olive: "#5a6b59",
  charcoal: "#374151",
  tan: "#7c6958",
  rust: "#7c5849",
  slate: "#485b6b",
  violet: "#65516e",
};
const familiarFolders = {
  ".cache": "green", cache: "green", Chrome: "green", code: "green",
  Library: "blue", Google: "blue", blobs: "blue",
  Documents: "gray", "Application Support": "gray",
  Parallels: "tan", Caches: "tan",
  ".codex": "purple", sessions: "purple", Unity: "purple",
  Downloads: "olive", models: "slate",
  "lm-studio": "brown", Containers: "brown", Steam: "brown", Default: "brown",
  huggingface: "charcoal", hub: "charcoal", Code: "charcoal", Codex: "charcoal",
};
function directoryColor(e) {
  const familiar = Object.hasOwn(familiarFolders, e.name)
    ? familiarFolders[e.name]
    : null;
  if (familiar) return folderColors[familiar];
  let h = 0;
  for (const ch of e.name) h = (h * 31 + ch.charCodeAt(0)) | 0;
  const palette = Object.values(folderColors);
  return palette[Math.abs(h) % palette.length];
}
function drawMap() {
  const svg = $("#treemap");
  if (!svg || !browseData) return;
  const width = svg.clientWidth,
    height = svg.clientHeight;
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  let pieces = [];
  function walk(entry, x, y, w, h, depth) {
    if (w < 2 || h < 2) return;
    const children = (entry.children || []).filter((c) => c.size > 0);
    const hasChildren = children.length > 0 && w > 50 && h > 42;
    const label =
      entry.name.length > w / 6.5
        ? entry.name.slice(0, Math.max(1, Math.floor(w / 6.5) - 1)) + "…"
        : entry.name;
    if (depth > 0) {
      const color = entry.directory
        ? directoryColor(entry)
        : colors[entry.category] || colors.Other;
      pieces.push(
        `<g><rect class="map-block${selected?.id === entry.id ? " selected" : ""}" data-entry="${entry.id}" ${entry.aggregate ? 'data-aggregate="true"' : ""} x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${Math.max(0, w - 2).toFixed(2)}" height="${Math.max(0, h - 2).toFixed(2)}" rx="3" fill="${color}" role="button" aria-label="${escapeHTML(entry.name + " " + fmt(entry.size))}" tabindex="0"/>${w > 40 && h > 20 ? `<text class="map-label" x="${x + 5}" y="${y + 15}">${escapeHTML(label)}</text>` : ""}${!hasChildren && w > 70 && h > 44 ? `<text class="map-size" x="${x + 5}" y="${y + 33}">${fmt(entry.size)}</text>` : ""}</g>`,
      );
    }
    if (hasChildren || depth === 0) {
      const xx = x + (depth ? 4 : 0),
        yy = y + (depth ? 21 : 0),
        ww = w - (depth ? 8 : 0),
        hh = h - (depth ? 25 : 0);
      const sum = children.reduce((s, c) => s + c.size, 0);
      const list = children.slice();
      if (sum < entry.size * 0.995)
        list.push({
          id: entry.id,
          name: `Other ${Math.max(0, entry.childCount - children.length)} items`,
          size: entry.size - sum,
          directory: false,
          category: "Other",
          path: entry.path,
          aggregate: true,
        });
      Treemap.squarify(list, ww, hh).forEach((box) =>
        walk(box, xx + box.x, yy + box.y, box.w, box.h, depth + 1),
      );
    }
  }
  if (browseData.node.size === 0) {
    svg.innerHTML =
      '<text x="20" y="30" class="map-label">This folder contains no allocated file data.</text>';
    return;
  }
  walk(browseData.tree, 0, 0, width, height, 0);
  svg.innerHTML = pieces.join("");
  svg.onclick = (e) => {
    const target = e.target.closest("[data-entry]");
    if (target) {
      if (target.dataset.aggregate) {
        mode = "list";
        browse(Number(target.dataset.entry));
        return;
      }
      const entry = nodeRegistry.get(Number(target.dataset.entry));
      clearTimeout(mapClickTimer);
      mapClickTimer = setTimeout(() => selectEntry(entry), 220);
    }
  };
  svg.ondblclick = (e) => {
    clearTimeout(mapClickTimer);
    const target = e.target.closest("[data-entry]");
    if (target) {
      if (target.dataset.aggregate) {
        mode = "list";
        browse(Number(target.dataset.entry));
        return;
      }
      const entry = nodeRegistry.get(Number(target.dataset.entry));
      if (entry?.directory) browse(entry.id);
    }
  };
  svg.onkeydown = (e) => {
    if (e.key === "Enter") {
      if (e.target.dataset.aggregate) {
        mode = "list";
        browse(Number(e.target.dataset.entry));
        return;
      }
      const n = nodeRegistry.get(Number(e.target.dataset.entry));
      if (n?.directory) browse(n.id);
      else selectEntry(n);
    }
  };
  svg.onmousemove = (e) => {
    const target = e.target.closest("[data-entry]");
    if (!target) {
      $("#tooltip").hidden = true;
      return;
    }
    const entry = nodeRegistry.get(Number(target.dataset.entry));
    if (!entry) return;
    if (target.dataset.aggregate) {
      $("#tooltip").innerHTML =
        "<strong>Other items</strong><small>Smaller items omitted at this zoom level. Click to see the complete directory list.</small>";
    } else
      $("#tooltip").innerHTML =
        `<strong>${escapeHTML(entry.name)}</strong> · ${fmt(entry.size)}<small>${escapeHTML(entry.path)}</small><small>${entry.directory ? "Double-click to explore · " : ""}Right-click for actions</small>`;
    $("#tooltip").hidden = false;
    $("#tooltip").style.left =
      Math.min(e.clientX + 14, window.innerWidth - 440) + "px";
    $("#tooltip").style.top =
      Math.min(e.clientY + 18, window.innerHeight - 110) + "px";
  };
  svg.onmouseleave = () => ($("#tooltip").hidden = true);
  svg.oncontextmenu = (e) => {
    const target = e.target.closest("[data-entry]");
    if (target) {
      e.preventDefault();
      if (target.dataset.aggregate) {
        mode = "list";
        browse(Number(target.dataset.entry));
        return;
      }
      contextMenu(nodeRegistry.get(Number(target.dataset.entry)), e);
    }
  };
}
function selectEntry(entry) {
  if (!entry) return;
  selected = entry;
  $(".selection")?.remove();
  $(".mapWrap")?.classList.add("hasSelection");
  $("#main").insertAdjacentHTML(
    "beforeend",
    `<div class="selection"><div class="selectionInfo"><strong>${escapeHTML(entry.name)} · ${fmt(entry.size)}</strong><p title="${escapeHTML(entry.path)}">${escapeHTML(entry.path)}</p><small>${entry.directory ? `${entry.count.toLocaleString()} entries` : `${entry.category} · logical ${fmt(entry.logical)}`} · ${new Date(entry.modified * 1000).toLocaleDateString()}</small></div>${entry.directory ? `<button id="exploreSelected">Explore</button>` : ""}<button id="revealSelected">${icon("eye")}Reveal</button><button class="primary" id="queueSelected">${icon("plus")}Add to Queue</button><button class="danger" id="trashSelected" aria-label="Move selected item to Trash">${icon("trash")}</button><button id="closeSelected" aria-label="Close selection">×</button></div>`,
  );
  $("#revealSelected").onclick = () =>
    native("reveal", { path: entry.path }).catch(error);
  $("#queueSelected").onclick = () => addQueue(entry);
  $("#trashSelected").onclick = () =>
    trashRows([entry], () => startScan(scanRoot));
  $("#closeSelected").onclick = () => {
    selected = null;
    $(".selection")?.remove();
    $(".mapWrap")?.classList.remove("hasSelection");
    drawMap();
  };
  if ($("#exploreSelected"))
    $("#exploreSelected").onclick = () => browse(entry.id);
  drawMap();
}
function fileTable(rows, checkbox = false) {
  return `<table class="fileTable"><thead><tr>${checkbox ? "<th></th>" : ""}<th>NAME</th><th>SIZE ON DISK</th><th>TYPE</th><th></th></tr></thead><tbody>${rows.map((e, i) => `<tr data-row="${i}">${checkbox ? `<td><input type="checkbox" data-check="${i}" ${e.shared ? "" : "checked"} aria-label="Select ${escapeHTML(e.name)}"></td>` : ""}<td class="name"><button data-row-open="${i}" title="${escapeHTML(e.path)}">${e.directory ? "▸ " : ""}${escapeHTML(e.name)}</button><span class="path">${escapeHTML(e.path)}</span></td><td class="num">${fmt(e.size)}</td><td>${escapeHTML(e.kind || (e.directory ? "Folder" : e.category) || "File")}</td><td class="actions"><button data-row-reveal="${i}" title="Reveal in Finder">${icon("eye")}</button>${checkbox ? "" : `<button data-row-queue="${i}" title="Add to cleanup queue">${icon("plus")}</button>`}</td></tr>`).join("")}</tbody></table>`;
}
let tableRows = [];
function bindRows(rows = browseData?.children || []) {
  tableRows = rows;
  $$("[data-row-open]").forEach(
    (b) =>
      (b.onclick = () => {
        const e = rows[Number(b.dataset.rowOpen)];
        if (e.directory && e.id >= 0) browse(e.id);
        else if (e.directory) startScan(e.path);
        else native("open", { path: e.path }).catch(error);
      }),
  );
  $$("[data-row-reveal]").forEach(
    (b) =>
      (b.onclick = () =>
        native("reveal", {
          path: rows[Number(b.dataset.rowReveal)].path,
        }).catch(error)),
  );
  $$("[data-row-queue]").forEach(
    (b) => (b.onclick = () => addQueue(rows[Number(b.dataset.rowQueue)])),
  );
  $$("[data-row]").forEach((tr) => {
    tr.oncontextmenu = (e) => {
      e.preventDefault();
      contextMenu(rows[Number(tr.dataset.row)], e);
    };
    tr.onclick = (e) => {
      if (e.target.closest("button,input")) return;
      const entry = rows[Number(tr.dataset.row)];
      if (entry.directory) {
        entry.id >= 0 ? browse(entry.id) : startScan(entry.path);
      }
    };
  });
}
function contextMenu(entry, event) {
  if (!entry) return;
  $("#tooltip").hidden = true;
  const menu = $("#context");
  menu.innerHTML = `${entry.directory ? '<button data-action="explore">' + icon("folder") + "Explore folder</button>" : ""}<button data-action="reveal">${icon("eye")}Reveal in Finder</button><button data-action="open">${icon("file")}Open</button><button data-action="queue">${icon("plus")}Add to Queue</button><button data-action="trash" class="danger">${icon("trash")}Move to Trash</button><button data-action="copy">${icon("code")}Copy path</button>`;
  menu.hidden = false;
  menu.style.left = Math.min(event.clientX, window.innerWidth - 220) + "px";
  menu.style.top = Math.min(event.clientY, window.innerHeight - 230) + "px";
  menu.querySelectorAll("button").forEach(
    (b) =>
      (b.onclick = () => {
        menu.hidden = true;
        const action = b.dataset.action;
        if (action === "queue") addQueue(entry);
        else if (action === "trash")
          trashRows([entry], () => {
            if (scanRoot) startScan(scanRoot);
          });
        else if (action === "copy")
          native("copy", { path: entry.path })
            .then(() => toast("Path copied"))
            .catch(error);
        else if (action === "explore")
          entry.id >= 0 ? browse(entry.id) : startScan(entry.path);
        else native(action, { path: entry.path }).catch(error);
      }),
  );
}
document.addEventListener("click", (e) => {
  if (!e.target.closest("#context")) $("#context").hidden = true;
});
let debounce;
$("#search").addEventListener("input", () => {
  clearTimeout(debounce);
  debounce = setTimeout(() => {
    if (!$("#search").value && !filters.size && !fileType && scanRoot)
      browse(currentNode);
    else showSearch();
  }, 250);
});
$("#scope").onchange = () => {
  if ($("#search").value) showSearch();
};
async function showSearch(large = false) {
  switching("search");
  const token = ++searchToken,
    query = $("#search").value;
  displayLoading(large ? "Finding large files..." : "Searching...", query);
  try {
    const result = await native("search", {
      query,
      filters: [...filters],
      type: fileType,
      scope: $("#scope").value,
      large,
    });
    if (token !== searchToken || view !== "search") return;
    result.rows.forEach((e) => {
      if (e.id >= 0) nodeRegistry.set(e.id, e);
    });
    $("#main").innerHTML =
      `<div class="page"><h1>${large ? "Large Files" : filters.size || fileType ? "Filtered Files" : "Power Search"}</h1><p class="subtitle">${escapeHTML(result.source)} · ${result.total.toLocaleString()} matches${result.total > 500 ? " · showing largest 500" : ""}</p><div class="toolbar"><button id="returnMap">${icon("drive")}Back to map</button>${[
        ...filters,
        fileType,
      ]
        .filter(Boolean)
        .map((x) => `<span class="orange">${escapeHTML(x)}</span>`)
        .join(
          " · ",
        )}</div>${result.rows.length ? fileTable(result.rows) : `<div class="emptyResult">${scanRoot || $("#scope").value !== "scan" ? "No matching files. Spotlight only searches indexed locations." : "Scan a folder first, or switch the search scope to Home / Full Mac."}</div>`}</div>`;
    $("#returnMap").onclick = () => {
      if (scanRoot) browse(currentNode);
      else showWelcome();
    };
    bindRows(result.rows);
  } catch (e) {
    if (token === searchToken) error(e);
  }
}
async function exportReport() {
  try {
    const r = await native("export");
    if (r.path)
      toast(`Exported ${r.count.toLocaleString()} entries to ${r.path}`);
  } catch (e) {
    error(e);
  }
}
function dialog(html) {
  $("#overlay").hidden = false;
  $("#dialog").innerHTML =
    '<button class="close" id="closeDialog" aria-label="Close">×</button>' +
    html;
  $("#closeDialog").onclick = closeDialog;
  $("#closeDialog").focus();
}
function closeDialog() {
  $("#overlay").hidden = true;
}
$("#overlay").addEventListener("click", (e) => {
  if (e.target === $("#overlay")) closeDialog();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    closeDialog();
    $("#context").hidden = true;
  }
  if ((e.metaKey || e.ctrlKey) && e.key === "f") {
    e.preventDefault();
    $("#search").focus();
  }
});
function showQueue() {
  dialog(
    `<h2>${icon("trash")}Cleanup Queue</h2><p>Review your selection. Items move to Finder’s Trash and can be restored there. A parent folder includes everything inside it.</p>${queue.length ? `<table class="fileTable"><thead><tr><th>ITEM</th><th>SIZE</th><th></th></tr></thead><tbody>${queue.map((e, i) => `<tr><td class="name">${escapeHTML(e.name)}<span class="path">${escapeHTML(e.path)}</span></td><td class="num">${fmt(e.size)}</td><td><button class="small" data-remove="${i}" aria-label="Remove ${escapeHTML(e.name)} from queue">×</button></td></tr>`).join("")}</tbody></table>` : '<div class="emptyResult">Your queue is empty. Select a file in the map or list to add it.</div>'}<div class="dialogFooter"><span class="total">${queue.length} items · ${fmt(queue.reduce((s, e) => s + e.size, 0))}</span><button id="clearQueue" ${queue.length ? "" : "disabled"}>Clear Queue</button><button class="danger" id="trashQueue" ${queue.length ? "" : "disabled"}>${icon("trash")}Move to Trash</button></div>`,
  );
  $$("[data-remove]").forEach(
    (b) =>
      (b.onclick = () => {
        queue.splice(Number(b.dataset.remove), 1);
        saveQueue();
        showQueue();
      }),
  );
  $("#clearQueue").onclick = () => {
    queue = [];
    saveQueue();
    showQueue();
  };
  $("#trashQueue").onclick = async () => {
    try {
      const r = await native("trash", { paths: queue.map((e) => e.path) });
      if (r.cancelled) return;
      const moved = new Set(r.moved);
      queue = queue.filter((e) => !moved.has(e.path));
      saveQueue();
      showQueue();
      disk();
      toast(
        `${r.moved.length} items moved to Trash${r.failures.length ? ` · ${r.failures.map((e) => e.error).join("; ")}` : ""}`,
      );
      if (r.moved.length && scanRoot) {
        closeDialog();
        startScan(scanRoot);
      }
    } catch (e) {
      error(e);
    }
  };
}
const themes = [
  ["dark", "Dark", "#242424", "#fff"],
  ["light", "Light", "#eef0f3", "#202936"],
  ["midnight", "Midnight", "#111b2c", "#e8efff"],
  ["forest", "Forest", "#192c26", "#eef8f1"],
  ["purple", "Amethyst", "#251d32", "#f6edff"],
  ["sunset", "Sunset", "#302420", "#fff4e7"],
];
function showThemes() {
  dialog(
    "<h2>" +
      icon("palette") +
      'Appearance</h2><p>Choose a theme. All themes are included.</p><div class="themeGrid">' +
      themes
        .map(
          ([id, name, bg, fg]) =>
            `<button class="themeOption" data-theme-choice="${id}" style="background:${bg};color:${fg}"><strong>${name} ${document.body.dataset.theme === id ? "✓" : ""}</strong><i></i><small>Storage map · Live monitor</small></button>`,
        )
        .join("") +
      "</div>",
  );
  $$("[data-theme-choice]").forEach(
    (b) =>
      (b.onclick = () => {
        document.body.dataset.theme = b.dataset.themeChoice;
        localStorage.setItem("theme", b.dataset.themeChoice);
        closeDialog();
        drawMap();
      }),
  );
}
function showPermissions() {
  dialog(
    `<h2>${icon("shield")}Full Disk Access</h2><p>macOS protects Mail, browser data, app containers and the Trash. Scans report inaccessible paths instead of counting them as empty.</p><p>For a more complete scan, open System Settings → Privacy &amp; Security → Full Disk Access, add DiskScope.app, enable it, then quit and reopen DiskScope. External drives can be scanned with Choose Folder.</p><div class="dialogFooter"><button id="openSettings" class="primary">Open System Settings</button></div>`,
  );
  $("#openSettings").onclick = () => native("permissions").catch(error);
}
let appTab = "installed",
  related = [];
async function showApps() {
  switching("apps");
  appTab = "installed";
  displayLoading("Apps Manager", "Finding installed applications...");
  try {
    apps = await native("apps");
    if (view !== "apps") return;
    renderApps();
  } catch (e) {
    error(e);
  }
}
function renderApps() {
  ++appToken;
  $("#main").innerHTML =
    `<div class="page"><h1 class="gradient">Apps Manager</h1><p class="subtitle">Uninstall apps together with their support files, or inspect leftovers from deleted apps.</p><div class="tabs"><button id="installedTab" class="${appTab === "installed" ? "active" : ""}">Installed Apps (${apps.length})</button><button id="orphansTab" class="${appTab === "orphans" ? "active" : ""}">Leftover Cleanup</button></div><div id="appsBody">${appTab === "installed" ? '<div class="appLayout"><div class="appList"><input id="appSearch" placeholder="Search applications..." aria-label="Search applications"><div class="appItems" id="appItems"></div></div><div class="appDetails" id="appDetails"><div class="emptyResult">Select an app to inspect its files.</div></div></div>' : ""}</div></div>`;
  $("#installedTab").onclick = () => {
    appTab = "installed";
    renderApps();
  };
  $("#orphansTab").onclick = () => {
    appTab = "orphans";
    renderApps();
    loadOrphans();
  };
  if (appTab === "installed") {
    renderAppList();
    $("#appSearch").oninput = () => renderAppList($("#appSearch").value);
  }
}
function renderAppList(query = "") {
  $("#appItems").innerHTML = apps
    .filter((a) => a.name.toLowerCase().includes(query.toLowerCase()))
    .map(
      (a) =>
        `<button class="appItem" data-app="${escapeHTML(a.path)}"><span class="appBadge">${icon("apps")}</span><span>${escapeHTML(a.name)}<small>${escapeHTML(a.bundleID)} · ${escapeHTML(a.version)}</small></span></button>`,
    )
    .join("");
  $$("[data-app]").forEach(
    (b) =>
      (b.onclick = () => selectApp(apps.find((a) => a.path === b.dataset.app))),
  );
}
async function selectApp(app) {
  if (!app) return;
  const token = ++appToken;
  $$("[data-app]").forEach((b) =>
    b.classList.toggle("active", b.dataset.app === app.path),
  );
  $("#appDetails").innerHTML =
    `<h2>${escapeHTML(app.name)}</h2><div class="loading"><div class="spinner"></div><p>Measuring app and related files...</p></div>`;
  try {
    const rows = await native("appDetails", { path: app.path });
    if (token !== appToken || view !== "apps" || appTab !== "installed") return;
    related = rows;
    $("#appDetails").innerHTML =
      `<h2>${escapeHTML(app.name)}</h2><p>${escapeHTML(app.bundleID)} · ${escapeHTML(app.version)}<br>Matched by exact application name, bundle identifier and declared groups. Shared groups are unchecked; review them before selecting.</p>${fileTable(rows, true)}<div class="appActions"><strong id="appTotal">${fmt(rows.filter((e) => !e.shared).reduce((s, e) => s + e.size, 0))}</strong><button class="danger" id="uninstall">${icon("trash")}Uninstall Selected</button></div><p>Quit the app before uninstalling. Removal moves selected items to the Trash. Reinstalling an app does not restore discarded app data automatically.${rows.some((e) => e.skipped) ? "<br>Some paths were inaccessible. Full Disk Access may be needed." : ""}</p>`;
    bindRows(rows);
    $$("[data-check]").forEach(
      (c) =>
        (c.onchange = () => {
          $("#appTotal").textContent = fmt(
            checkedRows(rows).reduce((s, e) => s + e.size, 0),
          );
        }),
    );
    $("#uninstall").onclick = () =>
      trashRows(checkedRows(rows), () => selectApp(app));
  } catch (e) {
    error(e);
  }
}
function checkedRows(rows) {
  return $$("[data-check]")
    .filter((x) => x.checked)
    .map((x) => rows[Number(x.dataset.check)]);
}
async function trashRows(rows, after) {
  if (!rows.length) {
    toast("Select at least one item");
    return;
  }
  try {
    const r = await native("trash", { paths: rows.map((e) => e.path) });
    if (r.cancelled) return;
    toast(
      `${r.moved.length} items moved to Trash${r.failures.length ? " · " + r.failures.map((e) => e.error).join("; ") : ""}`,
    );
    disk();
    if (after) after();
  } catch (e) {
    error(e);
  }
}
async function loadOrphans() {
  const token = ++appToken;
  $("#appsBody").innerHTML =
    '<div class="loading"><div class="spinner"></div><p>Checking bundle identifiers against installed apps and Spotlight...</p></div>';
  try {
    const rows = await native("orphans");
    if (token !== appToken || view !== "apps" || appTab !== "orphans") return;
    related = rows;
    $("#appsBody").innerHTML =
      `<p class="subtitle">${rows.length} leftover candidates. Matches are heuristic; portable apps or incomplete Spotlight indexing may produce false positives. No items are preselected.</p>${rows.length ? fileTable(rows, true) : '<div class="emptyResult">No leftover candidates found in accessible Library folders.</div>'}<div class="dialogFooter"><button id="queueOrphans">Add Selected to Queue</button><button class="danger" id="trashOrphans">Move Selected to Trash</button></div>`;
    $$("[data-check]").forEach((c) => (c.checked = false));
    bindRows(rows);
    $("#queueOrphans").onclick = () => {
      checkedRows(rows).forEach(addQueue);
      showQueue();
    };
    $("#trashOrphans").onclick = () =>
      trashRows(checkedRows(rows), loadOrphans);
  } catch (e) {
    error(e);
  }
}
const history = { cpu: [], down: [], up: [] };
let monitorBusy = false;
function chart(values, color, max = 100) {
  if (!values.length) return "";
  const data = [
    ...Array(Math.max(0, 60 - values.length)).fill(0),
    ...values,
  ].slice(-60);
  const pts = data
    .map(
      (v, i) =>
        `${(i / 59) * 300},${70 - Math.min(1, v / Math.max(1, max)) * 65}`,
    )
    .join(" ");
  return `<svg class="spark" viewBox="0 0 300 75" preserveAspectRatio="none"><polygon points="0,75 ${pts} 300,75" fill="${color}18"/><polyline points="${pts}" fill="none" stroke="${color}" stroke-width="2"/></svg>`;
}
function showMonitor() {
  switching("monitor");
  $("#main").innerHTML =
    '<div class="page"><h1 class="gradient">System Monitor</h1><p class="subtitle" id="machine">Initializing sensors...</p><div id="monitorBody"><div class="loading"><div class="spinner"></div></div></div></div>';
  monitorSample();
  monitorTimer = setInterval(monitorSample, 2000);
}
async function monitorSample() {
  if (monitorBusy || view !== "monitor") return;
  monitorBusy = true;
  try {
    const m = await native("monitor");
    if (view !== "monitor") return;
    history.cpu.push(m.cpu);
    history.down.push(m.download);
    history.up.push(m.upload);
    for (const key in history) history[key] = history[key].slice(-60);
    $("#machine").textContent =
      `${m.chip} · ${m.cores} Cores · ${fmtMemory(m.totalMemory)} Memory`;
    const percent = Math.round((m.memory / m.totalMemory) * 100),
      app = Math.max(0, m.memory - m.wired - m.compressed);
    $("#monitorBody").innerHTML =
      `<div class="cards"><div class="card"><h3><span style="color:var(--blue-soft)">${icon("cpu")}</span>CPU LOAD</h3><div class="metric">${m.cpu.toFixed(1)}%</div><p><span style="color:var(--blue-soft)">User: ${m.user.toFixed(1)}%</span> <span style="color:var(--red)">Sys: ${m.system.toFixed(1)}%</span></p>${chart(history.cpu, "#3b82f6")}</div><div class="card"><h3><span style="color:var(--purple)">${icon("drive")}</span>MEMORY</h3><div class="metric">${fmtMemory(m.memory)}</div><p>of ${fmtMemory(m.totalMemory)} (${percent}%)</p><div class="memoryBar"><i style="width:${(app / m.totalMemory) * 100}%;background:#a855f7"></i><i style="width:${(m.wired / m.totalMemory) * 100}%;background:#3b82f6"></i><i style="width:${(m.compressed / m.totalMemory) * 100}%;background:#fb923c"></i></div><div class="breakdown"><span><em class="app">App</em> ${fmtMemory(app)}</span><span><em class="wired">Wired</em> ${fmtMemory(m.wired)}</span><span><em class="cached">Cached</em> ${fmtMemory(m.cached)}</span><span><em class="free">Free</em> ${fmtMemory(m.free)}</span><span><em class="compressed">Compressed</em> ${fmtMemory(m.compressed)}</span><span><em class="swap">Swap</em> ${fmtMemory(m.swap)}</span></div></div><div class="card"><h3><span style="color:var(--green)">${icon("wifi")}</span>NETWORK</h3><div class="netLine"><span class="green">↓ DOWNLOAD</span><strong>${fmt(m.download, true)}</strong></div><div class="netLine"><span style="color:var(--blue-soft)">↑ UPLOAD</span><strong>${fmt(m.upload, true)}</strong></div>${chart(history.down, "#4ade80", Math.max(1024, ...history.down))}<p>Physical en* interfaces</p></div><div class="card"><h3><span style="color:var(--amber)">${icon("power")}</span>POWER</h3><div class="powerMetric">${m.power.percent == null ? "—" : Math.round(m.power.percent) + "%"}</div><p style="text-align:center">${m.power.source === "AC Power" ? "AC Powered" : m.power.source === "Battery Power" ? "On Battery" : escapeHTML(m.power.source)}${m.power.charging ? " · Charging" : ""}</p></div></div><div class="processes"><h3>${icon("pulse")} Top Processes (by CPU)</h3><table class="fileTable"><thead><tr><th>PROCESS</th><th>CPU</th><th>MEMORY</th><th>PID</th></tr></thead><tbody>${m.processes.map((p, i) => `<tr><td><span class="rank">${i + 1}</span>${escapeHTML(p.name)}</td><td class="num">${p.cpu.toFixed(1)}%</td><td style="color:var(--purple)">${fmtMemory(p.memory)}</td><td style="color:var(--muted)">${p.pid}</td></tr>`).join("")}</tbody></table><p class="subtitle" style="margin-top:18px;font-size:11px">CPU is sampled between refreshes. Process CPU is reported by macOS ps and may exceed 100% for multiple cores. Memory is an estimate excluding reclaimable cached pages.</p></div>`;
  } catch (e) {
    error(e);
  } finally {
    monitorBusy = false;
  }
}
$("#homeView").onclick = () => {
  if (scanRoot) browse(currentNode);
  else showWelcome();
};
$("#scanMac").onclick = () => startScan("/");
$("#scanHome").onclick = () => startScan("home");
$("#choose").onclick = () => startScan("", true);
$("#appsView").onclick = showApps;
$("#monitorView").onclick = showMonitor;
$("#themeView").onclick = showThemes;
$("#queueView").onclick = showQueue;
$("#permissions").onclick = showPermissions;
$("#emptyTrash").onclick = async () => {
  try {
    const r = await native("emptyTrash");
    if (!r.cancelled) {
      toast(r.errors.length ? r.errors.join("; ") : "Trash emptied");
      disk();
    }
  } catch (e) {
    error(e);
  }
};
new ResizeObserver(() => {
  if (view === "disk" && mode === "map") drawMap();
}).observe($("#main"));
// Let AppKit drag only the header's empty space. Keep control rectangles in
// CSS pixels so resizing and a changing queue count cannot cover a button.
let dragRegionFrame = 0;
function updateDragRegions() {
  cancelAnimationFrame(dragRegionFrame);
  dragRegionFrame = requestAnimationFrame(() => {
    const header = $("header").getBoundingClientRect();
    const controls = $$("header button, header .searchBox").map((element) => {
      const rect = element.getBoundingClientRect();
      return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
    });
    native("dragRegions", {
      height: $("#overlay").hidden ? header.bottom : 0,
      controls,
    }).catch(error);
  });
}
const headerResize = new ResizeObserver(updateDragRegions);
headerResize.observe($("header"));
$$("header button, header .searchBox").forEach((element) =>
  headerResize.observe(element),
);
new MutationObserver(updateDragRegions).observe($("#overlay"), {
  attributes: true,
  attributeFilter: ["hidden"],
});
window.addEventListener("resize", updateDragRegions);
updateDragRegions();
try {
  const theme = localStorage.getItem("theme");
  if (themes.some((x) => x[0] === theme)) document.body.dataset.theme = theme;
} catch {}
hydrate();
saveQueue();
bindWelcome();
disk();
setInterval(disk, 30000);
