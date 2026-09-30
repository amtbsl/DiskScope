/* Area-preserving squarified treemap. No third-party renderer. */
(function (root) {
  function squarify(items, width, height) {
    const sorted = items
      .filter((x) => x.size > 0)
      .slice()
      .sort((a, b) => b.size - a.size);
    const total = sorted.reduce((sum, x) => sum + x.size, 0);
    if (!total || width <= 0 || height <= 0) return [];
    let remaining = sorted.map((item) => ({
      item,
      area: (item.size / total) * width * height,
    }));
    let x = 0,
      y = 0,
      w = width,
      h = height;
    const out = [];
    function worst(row, side) {
      if (!row.length || side <= 0) return Infinity;
      const sum = row.reduce((s, a) => s + a.area, 0),
        max = Math.max(...row.map((a) => a.area)),
        min = Math.min(...row.map((a) => a.area));
      return Math.max(
        (side * side * max) / (sum * sum),
        (sum * sum) / (side * side * min),
      );
    }
    function place(row) {
      const sum = row.reduce((s, a) => s + a.area, 0);
      if (w >= h) {
        const rw = sum / h;
        let yy = y;
        row.forEach((a) => {
          const rh = a.area / rw;
          out.push({ ...a.item, x, y: yy, w: rw, h: rh });
          yy += rh;
        });
        x += rw;
        w = Math.max(0, w - rw);
      } else {
        const rh = sum / w;
        let xx = x;
        row.forEach((a) => {
          const rw = a.area / rh;
          out.push({ ...a.item, x: xx, y, w: rw, h: rh });
          xx += rw;
        });
        y += rh;
        h = Math.max(0, h - rh);
      }
    }
    while (remaining.length) {
      let row = [remaining.shift()];
      while (
        remaining.length &&
        worst([...row, remaining[0]], Math.min(w, h)) <=
          worst(row, Math.min(w, h))
      )
        row.push(remaining.shift());
      place(row);
    }
    return out;
  }
  const api = { squarify };
  if (typeof module !== "undefined") module.exports = api;
  else root.Treemap = api;
})(typeof window === "undefined" ? globalThis : window);
