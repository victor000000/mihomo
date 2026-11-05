const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../../web/index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

async function render(data, ok = true) {
  const elements = new Map();
  const context = vm.createContext({
    document: { querySelector(selector) {
      if (!elements.has(selector)) elements.set(selector, { innerHTML: '', className: '' });
      return elements.get(selector);
    } },
    fetch: async () => ({ ok, status: ok ? 200 : 503, json: async () => data }),
    setInterval() {},
    console,
  });
  vm.runInContext(script, context, { timeout: 1000 });
  await new Promise(resolve => setImmediate(resolve));
  return elements;
}

function snapshot() {
  return {
    host: 'fixture', observed_at: new Date().toISOString(), build_ms: 5,
    mihomo: { state: 'ok', routes: [], groups: [], connections_active: 1 },
    hypomux: { state: 'ok', tun: true, ports_up: 0, service: 'Running',
      carrying: null, carried_conns: null, chain_expected_conns: 1 },
    smartdns: { state: 'retired', required: false },
  };
}

test('closed legacy ports do not report a healthy TUN as down', async () => {
  const elements = await render(snapshot());
  assert.match(elements.get('#hypomux-sub').innerHTML, /HypoMux TUN ready/);
  assert.doesNotMatch(elements.get('#hypomux-sub').innerHTML, /DIALER DOWN/);
  assert.match(elements.get('#hypomux-kv').innerHTML, /not available from mihomo chains/);
});

test('old TUN snapshots remain readable until the collector is restarted', async () => {
  const data = snapshot();
  delete data.hypomux.tun;
  delete data.schema_version;
  data.hypomux.carried_conns = 99;
  const elements = await render(data);
  assert.match(elements.get('#hypomux-sub').innerHTML, /HypoMux TUN ready/);
  assert.match(elements.get('#hypomux-kv').innerHTML, /not available from mihomo chains/);
});

test('retired SmartDNS is not rendered as a failed required service', async () => {
  const elements = await render(snapshot());
  assert.equal(elements.get('#d-smartdns').className, 'dot idle');
  assert.match(elements.get('#smartdns-kv').innerHTML, /retired/);
  assert.doesNotMatch(elements.get('#smartdns-kv').innerHTML, /degraded|class="tag bad"/);
});

test('snapshot age uses producer time instead of browser refresh time', async () => {
  const data = snapshot();
  data.observed_at = new Date(Date.now() - 90000).toISOString();
  const elements = await render(data);
  assert.match(elements.get('#meta').innerHTML, /stale/);
});

test('an HTTP success containing an error is still unavailable', async () => {
  const elements = await render({ error: 'snapshot corrupt' });
  assert.match(elements.get('#meta').innerHTML, /collector unreachable/);
});

test('an unavailable snapshot does not look like a new successful sample', async () => {
  const elements = await render({}, false);
  assert.match(elements.get('#meta').innerHTML, /collector unreachable/);
});

test('host strings are escaped before entering markup', async () => {
  const data = snapshot();
  data.host = '<img src=x onerror=alert(1)>';
  const elements = await render(data);
  assert.match(elements.get('#meta').innerHTML, /&lt;img/);
  assert.doesNotMatch(elements.get('#meta').innerHTML, /<img/);
});
