/* Shared, dependency-free interface rules. Native review still validates every path. */
(function (root) {
  "use strict";
  const reclaimGroups = [
    { tag: "Logs & Caches", name: "Caches & logs", note: "Apps may recreate these files. Review active app data before removing it." },
    { tag: "Node.js", name: "Node.js dependencies", note: "Dependencies and package caches may need to be downloaded again." },
    { tag: "Build Artifacts", name: "Build outputs", note: "Check project folders; a folder name alone does not prove it is disposable." },
  ];
  function report(value) {
    return {
      rows: Array.isArray(value) ? value : Array.isArray(value?.rows) ? value.rows : [],
      warnings: Array.isArray(value?.warnings) ? value.warnings.filter(x => typeof x === "string") : [],
      limited: value?.limited === true,
    };
  }
  function defaultRelatedSelection(row) {
    return !(row.shared || row.system || row.uncertain || row.skipped || row.limited || row.sizeKnown === false ||
      ["low", "uncertain"].includes(row.confidence));
  }
  function batteryMetrics(power = {}) {
    const valid = value => typeof value === "number" && Number.isFinite(value) && value >= 0;
    return {
      cycles: valid(power.cycleCount) ? Math.round(power.cycleCount).toLocaleString("en-US") : "—",
      health: valid(power.health) ? Math.round(power.health) + "%" : "—",
    };
  }
  function reclaimCandidates(values) {
    const allowed = new Set(reclaimGroups.map(group => group.tag));
    const unique = new Map();
    for (const value of values) for (const row of report(value).rows) {
      if (!row || typeof row.path !== "string" || !(row.size > 0) || !Number.isFinite(row.size) ||
        !Number.isInteger(row.id) || row.id < 0 || row.symlink || row.aggregate || row.protected) continue;
      const path = row.path.replace(/\/+$/, "") || "/";
      const parts = path.toLowerCase().split("/").filter(Boolean);
      const tags = (Array.isArray(row.tags) ? row.tags : []).filter(tag => allowed.has(tag));
      if (!tags.length || parts.some(part => [".", "..", ".trash"].includes(part))) continue;
      // Only paths accepted by the normal cleanup scope are candidates. Protected
      // home folders and volume roots remain navigation targets, never suggestions.
      const userPath = parts[0] === "users" && parts.length >= 3;
      const volumePath = parts[0] === "volumes" && parts.length >= 3;
      const appPath = parts[0] === "applications" && parts.length >= 2;
      if (!(userPath || volumePath || appPath)) continue;
      if (userPath && parts.length === 3 && ["library", "desktop", "documents", "downloads", "pictures", "music", "movies"].includes(parts[2])) continue;
      const prior = unique.get(path);
      unique.set(path, { ...row, path, size: Math.max(prior?.size || 0, row.size),
        reclaimGroups: [...new Set([...(prior?.reclaimGroups || []), ...tags])] });
    }
    const result = [];
    for (const row of [...unique.values()].sort((a, b) => a.path.length - b.path.length || a.path.localeCompare(b.path))) {
      const parent = result.find(item => row.path.startsWith(item.path + "/"));
      if (parent) parent.reclaimGroups = [...new Set([...parent.reclaimGroups, ...row.reclaimGroups])];
      else result.push(row);
    }
    return result.sort((a, b) => b.size - a.size || a.path.localeCompare(b.path));
  }
  const api = { reclaimGroups, report, defaultRelatedSelection, batteryMetrics, reclaimCandidates };
  root.DiskScopeUI = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
