const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

// The VM runs the real interface against a small DOM/bridge boundary. No browser
// dependency is needed for asynchronous state, rendering and native requests.
function interfaceFixture(backend = {}, storedTheme = null) {
  const nodes = new Map(), matches = new Map(), requests = [];
  function node(id = '') {
    const element = {
      id, value: '', checked: false, hidden: true, dataset: {}, style: {},
      classList: { toggle() {}, add() {}, remove() {} },
      addEventListener() {}, removeAttribute() {}, focus() {}, remove() {},
      getBoundingClientRect: () => ({ x: 0, y: 0, width: 40, height: 30, bottom: 64 }),
      querySelectorAll: (selector) => document.querySelectorAll(selector),
      querySelector: (selector) => document.querySelector(selector),
      insertAdjacentHTML(_, html) { this.innerHTML += html; },
    };
    let html = '';
    Object.defineProperty(element, 'innerHTML', {
      get: () => html,
      set(value) {
        html = value;
        for (const match of value.matchAll(/id="([^"]+)"/g)) {
          if (!nodes.has(match[1])) nodes.set(match[1], node(match[1]));
        }
        for (const attr of ['check', 'app', 'theme-choice', 'reclaim-check']) {
          if (!value.includes(`data-${attr}=`) && !value.includes('<table')) continue;
          const list = [];
          for (const match of value.matchAll(new RegExp(`<[^>]+data-${attr}="([^"]+)"[^>]*>`, 'g'))) {
            const item = node();
            item.dataset[attr.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = match[1];
            item.checked = /\schecked(?:\s|>)/.test(match[0]);
            list.push(item);
          }
          matches.set(`[data-${attr}]`, list);
        }
      },
    });
    return element;
  }
  const document = {
    body: { dataset: { theme: 'dark' } },
    querySelector(selector) {
      if (selector.startsWith('#') || selector === 'header') {
        if (!nodes.has(selector)) nodes.set(selector, node(selector));
        // IDs discovered from markup and explicitly requested IDs are identical.
        return nodes.get(selector.slice(1)) || nodes.get(selector);
      }
      return null;
    },
    querySelectorAll: (selector) => matches.get(selector) || [],
    addEventListener() {},
  };
  nodes.set('#scope', Object.assign(node('scope'), { value: 'scan' }));
  const context = vm.createContext({
    document, console, localStorage: { getItem: key => key === 'theme' ? storedTheme : null, setItem() {} },
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    ResizeObserver: class { observe() {} }, MutationObserver: class { observe() {} },
    window: { addEventListener() {}, webkit: { messageHandlers: { native: {
      postMessage(message) {
        requests.push(message);
        const fallback = message.action === 'disk' ? { total: 1000, used: 500, free: 500, trashCount: 0 } : {};
        Promise.resolve().then(() => backend[message.action]?.(message.args) ?? fallback)
          .then(result => context.window.receive({ id: message.id, result }),
            error => context.window.receive({ id: message.id, error: error.message }));
      },
    } } } },
  });
  const helper = path.join(__dirname, '../web/ui-state.js');
  if (fs.existsSync(helper)) vm.runInContext(fs.readFileSync(helper, 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8'), context);
  return { evaluate: code => vm.runInContext(code, context), element: selector => document.querySelector(selector), requests, matches };
}
const monitor = {
  cpu: 38, user: 28, system: 10, download: 2048, upload: 1024,
  chip: 'Test Mac', cores: 8, totalMemory: 18000000000, memory: 9000000000,
  wired: 1000000000, compressed: 1000000000, cached: 1000000000, free: 9000000000, swap: 0,
  power: { percent: 72, source: 'Battery Power', charging: false, cycleCount: 124, health: 89 }, processes: [],
};

test('monitor plots separate CPU user/system and download/upload histories', async () => {
  const ui = interfaceFixture({ monitor: () => monitor });
  ui.evaluate('switching("monitor")');
  await ui.evaluate('monitorSample()');
  const html = ui.element('#monitorBody').innerHTML;
  const cards = html.split('<div class="card">').slice(1);
  assert.equal((cards[0].match(/<polyline/g) || []).length, 2, 'CPU must plot user and system series');
  assert.equal((cards[2].match(/<polyline/g) || []).length, 2, 'network must plot download and upload series');
});

test('battery exposes actual cycle count and health while missing values stay unavailable', async () => {
  const ui = interfaceFixture({ monitor: () => monitor });
  ui.evaluate('switching("monitor")');
  await ui.evaluate('monitorSample()');
  assert.match(ui.element('#monitorBody').innerHTML, /Cycle Count[\s\S]*?124/);
  assert.match(ui.element('#monitorBody').innerHTML, /Health[\s\S]*?89%/);
  const missing = interfaceFixture({ monitor: () => ({ ...monitor, power: { ...monitor.power, cycleCount: null, health: null } }) });
  missing.evaluate('switching("monitor")');
  await missing.evaluate('monitorSample()');
  assert.match(missing.element('#monitorBody').innerHTML, /Cycle Count[\s\S]*?—/);
  assert.match(missing.element('#monitorBody').innerHTML, /Health[\s\S]*?—/);
});

test('uninstall refreshes installed app count instead of requesting a removed app again', async () => {
  const app = { name: 'Fixture', path: '/Applications/Fixture.app', bundleID: 'org.fixture', version: '1' };
  let installed = [app];
  const ui = interfaceFixture({
    apps: () => installed,
    appDetails: () => [{ ...app, size: 100, directory: true, kind: 'Application', shared: false }],
    trash: () => { installed = []; return { moved: [app.path], failures: [], cancelled: false }; },
  });
  await ui.evaluate('showApps()');
  await ui.evaluate('selectApp(apps[0])');
  await ui.element('#uninstall').onclick();
  await new Promise(resolve => setImmediate(resolve));
  assert.match(ui.element('#main').innerHTML, /Installed Apps \(0\)/);
  assert.equal(ui.requests.filter(r => r.action === 'appDetails').length, 1);
});

test('orphan reports render candidates and disclose bounded or inaccessible results', async () => {
  const row = { path: '/tmp/org.old.fixture', name: 'Old Fixture', size: 12, directory: true, kind: 'Candidate', shared: true };
  const ui = interfaceFixture({ apps: () => [], orphans: () => ({ rows: [row], warnings: ['One folder was inaccessible'], limited: true }) });
  await ui.evaluate('showApps()');
  ui.evaluate('appTab = "orphans"');
  await ui.evaluate('loadOrphans()');
  assert.match(ui.element('#appsBody').innerHTML, /Old Fixture/);
  assert.match(ui.element('#appsBody').innerHTML, /One folder was inaccessible/);
  assert.match(ui.element('#appsBody').innerHTML, /Partial/);
  assert.ok(ui.matches.get('[data-check]').every(c => !c.checked));
});

test('Quick Reclaim requires a scan and offers recoverable scan actions', async () => {
  const ui = interfaceFixture();
  await ui.evaluate('typeof showReclaim === "function" ? showReclaim() : undefined');
  assert.match(ui.element('#main').innerHTML, /Scan a folder first/);
  assert.match(ui.element('#main').innerHTML, /reclaimScan/);
});

test('related-only cleanup reloads remaining app details and unsafe ownership defaults off', async () => {
  const app = { name: 'Fixture', path: '/Applications/Fixture.app', bundleID: 'org.fixture', version: '1' };
  let detailsCount = 0;
  const ui = interfaceFixture({
    apps: () => [app],
    appDetails: () => { detailsCount++; return [
      { ...app, size: 100, kind: 'Application' },
      { name: 'Support', path: '/tmp/Fixture', size: 50, kind: 'Support' },
      { name: 'Helper', path: '/Library/Helper', size: 2, kind: 'Helper', system: true },
      { name: 'Uncertain', path: '/tmp/uncertain', size: 2, kind: 'Support', uncertain: true },
    ]; },
    trash: () => ({ moved: ['/tmp/Fixture'], failures: [], cancelled: false }),
  });
  await ui.evaluate('showApps()');
  await ui.evaluate('selectApp(apps[0])');
  assert.deepEqual(ui.matches.get('[data-check]').map(c => c.checked), [true, true, false, false]);
  ui.matches.get('[data-check]')[0].checked = false;
  await ui.element('#uninstall').onclick();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(detailsCount, 2);
  assert.equal(ui.requests.filter(r => r.action === 'apps').length, 2);
  assert.match(ui.element('#main').innerHTML, /Installed Apps \(1\)/);
});

test('Quick Reclaim keeps only tagged actionable rows and counts nested bytes once', async () => {
  const rows = [
    { id: 1, path: '/Users/test/project/node_modules', name: 'node_modules', size: 300, directory: true, tags: ['Node.js'] },
    { id: 2, path: '/Users/test/project/node_modules/tool/build', name: 'build', size: 200, directory: true, tags: ['Node.js', 'Build Artifacts'] },
    { id: 3, path: '/Users/test/Library/Caches/demo', name: 'Demo cache', size: 400, directory: true, tags: ['Logs & Caches'] },
    { id: 4, path: '/Users/test/Documents/movie.mp4', name: 'Private movie', size: 9999, tags: ['Videos'] },
    { id: 5, path: '/', name: 'Root', size: 0, directory: true, tags: ['Logs & Caches'] },
    { id: 6, path: '/System/Library/Caches/system', name: 'System cache', size: 20, directory: true, tags: ['Logs & Caches'] },
    { id: 7, path: '/Users/test/.cache/alias', name: 'Alias', size: 10, symlink: true, tags: ['Logs & Caches'] },
    { path: '/Users/test/.cache/unmeasured', name: 'Unmeasured row', size: 200, tags: ['Logs & Caches'] },
  ];
  const ui = interfaceFixture({ search: () => ({ rows, total: rows.length, source: 'Current scan' }) });
  ui.evaluate('scanRoot = "/Users/test"; browseData = { limited: true, skipped: 2 }');
  await ui.evaluate('typeof showReclaim === "function" ? showReclaim() : undefined');
  const html = ui.element('#main').innerHTML;
  assert.match(html, /700 B/);
  assert.match(html, /Partial/);
  assert.ok(!html.includes('Private movie'));
  assert.ok(!html.includes('System cache'));
  assert.ok(!html.includes('Alias'));
  assert.ok(!html.includes('/node_modules/tool/build'));
  const checks = ui.matches.get('[data-reclaim-check]') || [];
  assert.equal(checks.length, 2);
  assert.ok(checks.every(c => !c.checked));
  assert.ok(ui.requests.filter(r => r.action === 'search').every(r => r.args.scope === 'scan' && r.args.filters.length > 0));
  checks[0].checked = true;
  ui.element('#queueReclaim').onclick();
  assert.equal(ui.requests.filter(r => r.action === 'trash').length, 0, 'recommendations must only queue for review');
  assert.equal(ui.evaluate('queue.length'), 1);
  assert.match(ui.element('#dialog').innerHTML, /Cleanup Queue/);
});

test('Quick Reclaim ignores a stale search after navigating away', async () => {
  const finishes = [];
  const ui = interfaceFixture({ search: () => new Promise(resolve => { finishes.push(resolve); }) });
  ui.evaluate('scanRoot = "/Users/test"');
  const reclaim = ui.evaluate('typeof showReclaim === "function" ? showReclaim() : undefined');
  await new Promise(resolve => setImmediate(resolve));
  ui.evaluate('showWelcome()');
  finishes.forEach(finish => finish({ rows: [{ id: 1, name: 'Cache', path: '/Users/test/.cache/tool', size: 100, tags: ['Logs & Caches'] }], total: 1 }));
  await reclaim;
  assert.match(ui.element('#main').innerHTML, /Visualize your disk usage/);
});

test('failed searches provide retry and map navigation instead of a stranded spinner', async () => {
  const ui = interfaceFixture({ search: () => { throw new Error('Search unavailable'); } });
  await ui.evaluate('showSearch()');
  const html = ui.element('#main').innerHTML;
  assert.ok(!html.includes('spinner'));
  assert.match(html, /Search unavailable/);
  assert.match(html, /retrySearch/);
  ui.element('#returnMap').onclick();
  assert.match(ui.element('#main').innerHTML, /Visualize your disk usage/);
});

test('failed installed app loads provide a retry and home navigation', async () => {
  const ui = interfaceFixture({ apps: () => { throw new Error('Apps unavailable'); } });
  await ui.evaluate('showApps()');
  const html = ui.element('#main').innerHTML;
  assert.ok(!html.includes('spinner'));
  assert.match(html, /Apps unavailable/);
  assert.match(html, /retryApps/);
  ui.element('#appsHome').onclick();
  assert.match(ui.element('#main').innerHTML, /Visualize your disk usage/);
});

test('native quick search and update controls dispatch their dedicated actions', async () => {
  const ui = interfaceFixture({ quickSearch: () => ({ opened: true }), checkUpdates: () => ({ checked: true }) });
  await ui.element('#quickSearch').onclick();
  await ui.element('#checkUpdates').onclick();
  assert.equal(ui.requests.filter(r => r.action === 'quickSearch').length, 1);
  assert.equal(ui.requests.filter(r => r.action === 'checkUpdates').length, 1);
});

test('finishing an uninstall refreshes the list without replacing a newer app selection', async () => {
  const first = { name: 'First', path: '/Applications/First.app', bundleID: 'org.first', version: '1' };
  const second = { name: 'Second', path: '/Applications/Second.app', bundleID: 'org.second', version: '1' };
  let installed = [first, second], finishTrash;
  const ui = interfaceFixture({
    apps: () => installed,
    appDetails: args => [{ ...(args.path === first.path ? first : second), size: 100, kind: 'Application' }],
    trash: () => new Promise(resolve => { finishTrash = resolve; }),
  });
  await ui.evaluate('showApps()');
  await ui.evaluate('selectApp(apps[0])');
  const removal = ui.element('#uninstall').onclick();
  await new Promise(resolve => setImmediate(resolve));
  await ui.evaluate('selectApp(apps[1])');
  installed = [second];
  finishTrash({ moved: [first.path], failures: [], cancelled: false });
  await removal;
  assert.match(ui.element('#appDetails').innerHTML, /<h2>Second<\/h2>/);
  assert.ok(!ui.element('#appItems').innerHTML.includes('First'));
  assert.equal(ui.evaluate('apps.length'), 1);
});

test('ownership evidence and uncertainty remain visible alongside candidate paths', () => {
  const ui = interfaceFixture();
  const html = ui.evaluate('fileTable([{name:"Helper",path:"/Library/Helper",size:12,kind:"Launch agent",shared:true,system:true,uncertain:true,evidence:"Executable belongs to org.fixture",confidence:"low"}], true)');
  assert.match(html, /Executable belongs to org.fixture/);
  assert.match(html, /Shared/);
  assert.match(html, /System/);
  assert.match(html, /Uncertain/);
});

test('app discovery limits and unknown measurements stay explicit and unchecked', async () => {
  const app = { name: 'Fixture', path: '/Applications/Fixture.app', bundleID: 'org.fixture', version: '1' };
  const ui = interfaceFixture({
    apps: () => [app],
    appDetails: () => [{ ...app, size: 0, kind: 'Application', sizeKnown: false, limited: true,
      discoveryLimited: true, warnings: ['App scope inspection limit reached'] }],
  });
  await ui.evaluate('showApps()');
  await ui.evaluate('selectApp(apps[0])');
  const html = ui.element('#appDetails').innerHTML;
  assert.match(html, /App scope inspection limit reached/);
  assert.match(html, /Partial discovery/);
  assert.match(html, /Unknown/);
  assert.ok(ui.matches.get('[data-check]').every(c => !c.checked));
});

test('restored and changed themes propagate to native panels while dark remains the default', async () => {
  const ui = interfaceFixture({ appearance: () => ({ applied: true }) }, 'ocean');
  assert.equal(ui.evaluate('document.body.dataset.theme'), 'ocean');
  assert.equal(ui.requests.find(r => r.action === 'appearance')?.args.theme, 'ocean');
  ui.evaluate('showThemes()');
  ui.matches.get('[data-theme-choice]').find(button => button.dataset.themeChoice === 'aurora').onclick();
  assert.equal(ui.evaluate('document.body.dataset.theme'), 'aurora');
  assert.equal(ui.requests.filter(r => r.action === 'appearance').at(-1)?.args.theme, 'aurora');
  const original = interfaceFixture();
  assert.equal(original.evaluate('document.body.dataset.theme'), 'dark');
});
