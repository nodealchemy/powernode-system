// Tests for dev-cell-mcp-proxy.js route table (Part II phase 1).
//
// Run: node --test extensions/system/modules/dev-cell/test/
//
// No dependencies — node:test + node:assert only, matching the proxy's own
// "never needs an npm install" constraint.
//
// The incident class this file exists to catch is CREDENTIAL CONFUSION: a
// request for a lesser destination presenting the node's mTLS client cert,
// or a config edit manufacturing a route that can reach the node key at
// all. Those assertions are marked CREDENTIAL-CONFUSION below; if one of
// them is ever weakened, the proxy's whole reason for existing is gone.

'use strict';

// Set before require: the proxy reads its limits from env at module load.
process.env.DEV_CELL_MCP_PROXY_MAX_BODY_BYTES = '1024';

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');

const proxy = require('../rootfs/usr/local/bin/dev-cell-mcp-proxy.js');
const { buildRouteTable, selectRoute, validateConfigPath, createServer, LEGACY_PATH, PROD_PATH } = proxy;

const MCP_URL = 'https://ops-hub.example.test/api/v1/mcp/message';
// A sentinel standing in for the real https.Agent that carries node.key.
// Identity comparison against this object is the oracle: any route whose
// agent IS this object can present the node's client certificate.
const MTLS_AGENT = { __sentinel: 'mtls-agent-holding-node-key' };

function build(config) {
  return buildRouteTable({ mcpUrl: MCP_URL, mtlsAgent: MTLS_AGENT, config });
}

const DEV_ROUTE = {
  routes: [{ path: '/mcp/dev', url: 'http://127.0.0.1:3000/api/v1/mcp/message', credential: { type: 'bearer', token: 'dev-token' } }],
};

test('built-in routes exist with no config at all', () => {
  const table = build(null);
  assert.deepStrictEqual([...table.keys()].sort(), [LEGACY_PATH, PROD_PATH].sort());
  for (const path of [LEGACY_PATH, PROD_PATH]) {
    const route = table.get(path);
    assert.strictEqual(route.agent, MTLS_AGENT, `${path} must use the mTLS agent`);
    assert.strictEqual(route.authorization, null, `${path} must carry no bearer`);
    assert.strictEqual(route.target.href, MCP_URL);
  }
});

test('CREDENTIAL-CONFUSION: a bearer route never receives the mTLS agent', () => {
  const table = build(DEV_ROUTE);
  const dev = table.get('/mcp/dev');
  assert.notStrictEqual(dev.agent, MTLS_AGENT);
  assert.strictEqual(dev.authorization, 'Bearer dev-token');
  // ...and adding it did not disturb the prod route's credential.
  assert.strictEqual(table.get(PROD_PATH).agent, MTLS_AGENT);
  assert.strictEqual(table.get(PROD_PATH).authorization, null);
});

test('CREDENTIAL-CONFUSION: config cannot redefine either built-in mTLS route', () => {
  for (const path of [PROD_PATH, LEGACY_PATH]) {
    assert.throws(
      () => build({ routes: [{ path, url: 'http://evil.test/', credential: { type: 'bearer', token: 't' } }] }),
      /reserved for the built-in mTLS route/,
      `${path} must be unredefinable`
    );
  }
});

test('CREDENTIAL-CONFUSION: config cannot request an mtls credential', () => {
  for (const type of ['mtls', 'cert', 'client_cert', undefined, null, '']) {
    assert.throws(
      () => build({ routes: [{ path: '/mcp/x', url: 'http://a.test/', credential: { type } }] }),
      /only "bearer" is supported/,
      `credential type ${JSON.stringify(type)} must be refused`
    );
  }
});

test('a route with an empty or missing bearer token is a boot failure', () => {
  for (const token of ['', '   ', undefined, null, 42]) {
    assert.throws(
      () => build({ routes: [{ path: '/mcp/x', url: 'http://a.test/', credential: { type: 'bearer', token } }] }),
      /empty bearer token/
    );
  }
});

test('a route with no url, or a non-http(s) url, is a boot failure', () => {
  assert.throws(() => build({ routes: [{ path: '/mcp/x', credential: { type: 'bearer', token: 't' } }] }), /has no url/);
  assert.throws(
    () => build({ routes: [{ path: '/mcp/x', url: 'file:///etc/shadow', credential: { type: 'bearer', token: 't' } }] }),
    /must be http\(s\)/
  );
});

test('duplicate config route paths are a boot failure', () => {
  const dup = { path: '/mcp/x', url: 'http://a.test/', credential: { type: 'bearer', token: 't' } };
  assert.throws(() => build({ routes: [dup, dup] }), /duplicate route path/);
});

test('validateConfigPath rejects traversal, namespace escape and trailing slash', () => {
  assert.strictEqual(validateConfigPath('/mcp/dev'), null);
  for (const bad of ['/other', 'mcp/dev', '/mcp', '/mcp/', '/mcp/../admin', '/mcp/a?b', '/mcp/a#b', ' /mcp/a', 42, null]) {
    assert.notStrictEqual(validateConfigPath(bad), null, `${JSON.stringify(bad)} must be rejected`);
  }
});

test('selectRoute is EXACT match, not prefix', () => {
  const table = build(DEV_ROUTE);
  assert.ok(selectRoute('/mcp/prod', table));
  assert.ok(selectRoute('/mcp/dev', table));
  // Near-misses that a prefix match would wrongly resolve:
  for (const miss of ['/mcp/prodigy', '/mcp/prod/', '/mcp/prod/x', '/mcp/', '/mcp/de', '/mcpx', '/']) {
    assert.strictEqual(selectRoute(miss, table), null, `${miss} must not resolve`);
  }
});

test('selectRoute does not fall through to Object.prototype keys', () => {
  const table = build(null);
  for (const key of ['/mcp/constructor', 'constructor', '__proto__', 'toString']) {
    assert.strictEqual(selectRoute(key, table), null);
  }
});

// ---- integration: a real socket, a real fake upstream ----

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

function request(port, { method = 'POST', path = '/mcp/dev', headers = {}, body = '' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

test('bearer route: injects its own Authorization and DROPS the client-supplied one', async (t) => {
  let seen = null;
  const upstream = http.createServer((req, res) => {
    seen = req.headers;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
  });
  const upstreamPort = await listen(upstream);
  t.after(() => upstream.close());

  const table = build({
    routes: [{
      path: '/mcp/dev',
      url: `http://127.0.0.1:${upstreamPort}/api/v1/mcp/message`,
      credential: { type: 'bearer', token: 'the-real-token' },
    }],
  });
  const server = createServer(table);
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, {
    headers: {
      'content-type': 'application/json',
      // A hostile/confused client trying to smuggle its own credential:
      authorization: 'Bearer attacker-supplied',
      cookie: 'session=abc',
      'x-forwarded-for': '10.0.0.1',
      'mcp-protocol-version': '2026-07-28',
    },
    body: '{"jsonrpc":"2.0"}',
  });

  assert.strictEqual(res.status, 200);
  assert.strictEqual(seen.authorization, 'Bearer the-real-token');
  assert.strictEqual(seen.cookie, undefined, 'cookie must be dropped');
  assert.strictEqual(seen['x-forwarded-for'], undefined, 'x-forwarded-* must be dropped');
  assert.strictEqual(seen['mcp-protocol-version'], '2026-07-28', 'allowlisted headers must survive');
});

test('unknown path 404s, and a disallowed method 404s', async (t) => {
  const server = createServer(build(DEV_ROUTE));
  const port = await listen(server);
  t.after(() => server.close());

  assert.strictEqual((await request(port, { path: '/mcp/nope' })).status, 404);
  assert.strictEqual((await request(port, { path: '/admin' })).status, 404);
  assert.strictEqual((await request(port, { method: 'PUT', path: '/mcp/dev' })).status, 404);
});

test('query string is preserved through the route', async (t) => {
  let seenUrl = null;
  const upstream = http.createServer((req, res) => {
    seenUrl = req.url;
    res.writeHead(200);
    res.end('ok');
  });
  const upstreamPort = await listen(upstream);
  t.after(() => upstream.close());

  const table = build({
    routes: [{ path: '/mcp/dev', url: `http://127.0.0.1:${upstreamPort}/api/v1/mcp/message`, credential: { type: 'bearer', token: 't' } }],
  });
  const server = createServer(table);
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, { path: '/mcp/dev?sessionId=xyz' });
  assert.strictEqual(seenUrl, '/api/v1/mcp/message?sessionId=xyz');
});

test('an oversized body is aborted with 413 and never reaches upstream', async (t) => {
  let reachedUpstream = false;
  const upstream = http.createServer((req, res) => {
    req.on('data', () => {});
    req.on('end', () => { reachedUpstream = true; res.writeHead(200); res.end('ok'); });
  });
  const upstreamPort = await listen(upstream);
  t.after(() => upstream.close());

  const table = build({
    routes: [{ path: '/mcp/dev', url: `http://127.0.0.1:${upstreamPort}/api/v1/mcp/message`, credential: { type: 'bearer', token: 't' } }],
  });
  const server = createServer(table);
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, { body: 'x'.repeat(4096), headers: { 'content-type': 'application/json' } }).catch((e) => ({ status: 'ECONN', err: e }));
  assert.notStrictEqual(res.status, 200);
  assert.strictEqual(reachedUpstream, false, 'an over-cap body must not complete upstream');
});
