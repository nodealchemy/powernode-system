#!/usr/bin/env node
// dev-cell-mcp-proxy.js — a local, root-owned reverse proxy that is the
// ONLY thing on this instance allowed to hold the node's mTLS client
// cert/key. It listens on 127.0.0.1 and forwards MCP traffic to one of a
// small, STATIC set of destinations, presenting that destination's own
// credential on the upstream connection.
//
// WHY THIS EXISTS (privilege separation): the untrusted sandbox user
// (pnagent) that runs headless `claude` must be able to reach /mcp, but
// must NEVER hold the node's own mTLS private key — with node.key, a
// compromised/misbehaving agent could re-call the dev_cell_bootstrap
// node_api endpoint directly and MINT ITSELF A FRESH GITEA DEPLOY KEY,
// defeating the whole point of keeping the deploy key root-only. So the
// cert/key stay root-only (staged 0600 by dev-cell-bootstrap.sh, never
// chowned to pnagent), and pnagent's `claude --mcp-config` points at this
// proxy's http://127.0.0.1:<port>/mcp instead of the platform directly.
//
// ROUTING (phase 1 of docs/operations/mcp-environment-isolation.md Part II).
// The destination is carried by the PATH, bound at client-registration
// time — never by a request header, never by a model-supplied tool
// argument. Each route owns exactly one credential and one pre-built
// agent:
//
//   /mcp       -> platform (node mTLS)   [LEGACY alias, kept for cutover]
//   /mcp/prod  -> platform (node mTLS)
//   /mcp/<x>   -> as declared in the root-only route config (bearer only)
//
// The two mTLS routes are HARDCODED. No config file, and therefore no
// edit to a config file, can create a route that presents the node
// cert — the credential-confusion incident class this design most needs
// to exclude. Config-declared routes are bearer-only, and their tokens
// live in root-only config rather than in a user-readable ~/.claude.json.
//
// Route selection is EXACT-MATCH on the path. Deliberately not a prefix
// match: prefix matching is precisely how a request for one destination
// ends up at another. An unknown path is a 404 — fail closed, as before.
//
// HARDENING (this proxy is root, on a box where an unprivileged sandbox
// user is deliberately running arbitrary AI-agent-driven code — treat it
// as a real trust boundary, not a convenience shim):
//   * Forwarded headers are an ALLOWLIST, not a passthrough — verified
//     empirically (a real `claude` MCP call captured server-side) which
//     headers the streamable-HTTP transport actually sends: accept,
//     accept-encoding, content-type, content-length, mcp-protocol-version,
//     mcp-session-id — plus mcp-method and mcp-name, REQUIRED by MCP
//     protocol revision 2026-07-28 (the platform server rejects their
//     absence with JSON-RPC -32020 at HTTP 400 once a client negotiates
//     that revision). Everything else — notably authorization/cookie/
//     x-forwarded-* — is dropped rather than blindly relayed upstream.
//     A route's own bearer is injected AFTER that copy, so an inbound
//     authorization header can never survive into an upstream request.
//   * Bodies are STREAMED, never parsed. This proxy does not read, rewrite
//     or dispatch on JSON-RPC content — a deliberate security property,
//     not an omission. See Part II §11 and the review that rejected
//     catalog-merging shapes for requiring exactly that capability.
//   * headersTimeout bounds slowloris-style header-dribbling; a generous
//     (not Node's 5-minute default) requestTimeout bounds the whole
//     exchange WITHOUT killing the streamable-HTTP transport's
//     legitimately long-lived GET/SSE connections.
//   * maxConnections caps concurrent sockets.
//   * Request bodies are size-capped while still streamed (not buffered
//     in memory) to the upstream — a byte counter on the SAME readable
//     stream `.pipe()` is already draining aborts the connection if the
//     candidate exceeds the cap, rather than trusting Content-Length
//     alone (which a client could simply lie about).
//
// No external dependencies — Node core only, so this never needs an
// `npm install` (registry reachability is not a dependency of this unit
// starting).
//
// Runs as root (owns node.crt/node.key/ca-bundle.crt — see
// dev-cell-mcp-proxy.service). Never logs request/response bodies or
// header VALUES, only structural lines (method, path, route, status) —
// the same "never log secret material" discipline as every other script
// in this module. The one exception is opt-in and non-secret: see
// DEV_CELL_MCP_PROXY_LOG_PROTOCOL.
'use strict';

const http = require('http');
const https = require('https');
const tls = require('tls');
const fs = require('fs');
const { URL } = require('url');

const RUNTIME_DIR = process.env.DEV_CELL_RUNTIME_DIR || '/run/dev-cell';
const BIND_ADDR = process.env.DEV_CELL_MCP_PROXY_BIND || '127.0.0.1';
const PORT = parseInt(process.env.DEV_CELL_MCP_PROXY_PORT || '18443', 10);
const MAX_CONNECTIONS = parseInt(process.env.DEV_CELL_MCP_PROXY_MAX_CONNECTIONS || '20', 10);
const MAX_BODY_BYTES = parseInt(process.env.DEV_CELL_MCP_PROXY_MAX_BODY_BYTES || String(10 * 1024 * 1024), 10);
const HEADERS_TIMEOUT_MS = parseInt(process.env.DEV_CELL_MCP_PROXY_HEADERS_TIMEOUT_MS || '10000', 10);
// Deliberately generous, NOT Node's 5-minute http.Server default: the
// streamable-HTTP transport's GET opens an SSE stream that can
// legitimately stay open for a long-running dev-loop iteration —
// requestTimeout still bounds it (this is a self-DoS guard, not a
// feature), just loosely enough not to sever a normal session mid-work.
const REQUEST_TIMEOUT_MS = parseInt(process.env.DEV_CELL_MCP_PROXY_REQUEST_TIMEOUT_MS || String(60 * 60 * 1000), 10);

// Root-only route config. Absent is the NORMAL case and must stay
// harmless: with no file, the proxy serves exactly the two hardcoded
// mTLS routes, i.e. today's behaviour plus the /mcp/prod alias. A
// missing config can therefore never widen anything.
const ROUTES_FILE = process.env.DEV_CELL_MCP_ROUTES_FILE || '/etc/dev-cell/mcp-routes.json';

// Opt-in, default OFF. Logs the negotiated MCP protocol version and the
// PRESENCE (never the value) of the mirror headers, to answer the one
// empirical question phase 2 is gated on: does this client actually
// negotiate 2026-07-28 and send Mcp-Name? Values are not logged; the
// protocol version is a non-secret constant from a published spec.
const LOG_PROTOCOL = process.env.DEV_CELL_MCP_PROXY_LOG_PROTOCOL === '1';

// Only these three methods are part of the MCP streamable-HTTP transport
// (POST sends a message, GET opens the server->client SSE stream, DELETE
// terminates a session) — anything else is refused outright rather than
// blindly forwarded.
const ALLOWED_METHODS = new Set(['GET', 'POST', 'DELETE']);

// The mTLS routes. HARDCODED on purpose — see the ROUTING note above.
// LEGACY_PATH stays until every consumer (dev-cell-mcp-register.sh,
// dev-cell-executor.sh, the operator's own ~/.claude.json) has moved to
// PROD_PATH; removing it early severs live sessions mid-flight.
const LEGACY_PATH = '/mcp';
const PROD_PATH = '/mcp/prod';

// Base set verified empirically (captured server-side headers from a real
// `claude` MCP call through this exact transport) — everything NOT in this
// list is dropped, notably authorization/cookie/x-forwarded-*/user-agent,
// none of which the transport needs and none of which this purely-local
// proxy should blindly relay upstream on a client's say-so.
//
// mcp-method and mcp-name are NOT from that capture — they are REQUIRED by
// MCP protocol revision 2026-07-28: mcp-method on every Streamable HTTP
// POST, mcp-name additionally on tools/call, resources/read, and
// prompts/get. The platform server on develop enforces this once a client
// negotiates 2026-07-28, rejecting the absence with JSON-RPC -32020 at HTTP
// 400. They were added here AHEAD of the client-side protocol bump, so a
// future capture-based trim of this list MUST keep them even if a capture
// taken before that bump doesn't show them being sent.
const FORWARDED_HEADERS = new Set([
  'accept',
  'accept-encoding',
  'content-type',
  'content-length',
  'mcp-protocol-version',
  'mcp-session-id',
  'mcp-method',
  'mcp-name',
]);

function log(msg) {
  process.stderr.write(`dev-cell-mcp-proxy: ${msg}\n`);
}

function readFileOrDie(path, label) {
  try {
    return fs.readFileSync(path);
  } catch (err) {
    log(`missing ${label} at ${path} — did dev-cell-bootstrap.service run? (${err.message})`);
    process.exit(1);
  }
}

// Validate a config-declared route path. Rejects anything that could
// collide with, shadow, or traverse out of the /mcp/ namespace. A
// rejected path is a BOOT FAILURE, not a skipped route: a route config
// the operator believes is in force but which was silently dropped is
// worse than a proxy that refuses to start.
function validateConfigPath(path) {
  // Reserved-path check FIRST, so an operator who tries to redefine a
  // built-in gets the accurate reason ("reserved") rather than a generic
  // shape complaint. /mcp in particular fails the "/mcp/" prefix test, so
  // ordering this second reported a misleading cause for the one edit most
  // worth explaining clearly.
  if (path === PROD_PATH || path === LEGACY_PATH) {
    return `route path ${JSON.stringify(path)} is reserved for the built-in mTLS route and cannot be redefined`;
  }
  if (typeof path !== 'string' || !path.startsWith('/mcp/')) {
    return `route path ${JSON.stringify(path)} must be a string starting with "/mcp/"`;
  }
  if (path !== path.trim() || path.includes('..') || path.includes('?') || path.includes('#')) {
    return `route path ${JSON.stringify(path)} contains illegal characters`;
  }
  if (path.endsWith('/')) {
    return `route path ${JSON.stringify(path)} must not end with "/"`;
  }
  return null;
}

// Build the static route table. Every agent is constructed HERE, at boot,
// and thereafter selected only by exact path — never derived from request
// content. Returns a Map so lookup cannot fall through to Object.prototype
// (a plain object would resolve "/mcp/constructor"-shaped keys).
function buildRouteTable({ mcpUrl, mtlsAgent, config }) {
  const table = new Map();
  const target = new URL(mcpUrl);

  for (const path of [PROD_PATH, LEGACY_PATH]) {
    table.set(path, {
      path,
      label: path === LEGACY_PATH ? 'prod(legacy)' : 'prod',
      target,
      agent: mtlsAgent,
      // mTLS routes carry NO authorization header: the node cert IS the
      // credential. Setting one here would be a second, redundant secret.
      authorization: null,
    });
  }

  for (const route of Array(config && config.routes).flat().filter(Boolean)) {
    const err = validateConfigPath(route.path);
    if (err) throw new Error(err);
    if (table.has(route.path)) throw new Error(`duplicate route path ${JSON.stringify(route.path)}`);

    const cred = route.credential || {};
    // Phase 1 accepts exactly one credential type. An unknown type is a
    // boot failure rather than a route without a credential, which would
    // reach upstream unauthenticated and read as a server-side auth bug.
    if (cred.type !== 'bearer') {
      throw new Error(
        `route ${JSON.stringify(route.path)} has credential type ${JSON.stringify(cred.type)}; ` +
        'only "bearer" is supported (the mTLS credential is reachable ONLY from the built-in routes)'
      );
    }
    if (typeof cred.token !== 'string' || cred.token.trim() === '') {
      throw new Error(`route ${JSON.stringify(route.path)} has an empty bearer token`);
    }
    if (typeof route.url !== 'string' || route.url.trim() === '') {
      throw new Error(`route ${JSON.stringify(route.path)} has no url`);
    }

    const routeTarget = new URL(route.url);
    if (routeTarget.protocol !== 'http:' && routeTarget.protocol !== 'https:') {
      throw new Error(`route ${JSON.stringify(route.path)} url must be http(s), got ${routeTarget.protocol}`);
    }

    table.set(route.path, {
      path: route.path,
      label: route.label || route.path.slice('/mcp/'.length),
      target: routeTarget,
      // A bearer route NEVER gets the mTLS agent. This is the single most
      // important line in the file: it is what stops a request for a
      // lesser destination from presenting the node's client cert.
      agent: routeTarget.protocol === 'https:'
        ? new https.Agent({ keepAlive: true })
        : new http.Agent({ keepAlive: true }),
      authorization: `Bearer ${cred.token}`,
    });
  }

  return table;
}

// Exact match only. See the ROUTING note: prefix matching is the bug.
function selectRoute(pathname, table) {
  return table.get(pathname) || null;
}

function loadRouteConfig(path) {
  let raw;
  try {
    raw = fs.readFileSync(path, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw new Error(`could not read route config ${path}: ${err.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`could not parse route config ${path}: ${err.message}`);
  }
}

function createServer(table) {
  const server = http.createServer((req, res) => {
    const reqUrl = new URL(req.url, `http://${BIND_ADDR}`);
    const route = selectRoute(reqUrl.pathname, table);

    if (!route || !ALLOWED_METHODS.has(req.method)) {
      log(`refused ${req.method} ${reqUrl.pathname} (no such route, or method not one of ${[...ALLOWED_METHODS].join('/')})`);
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('not found');
      return;
    }

    if (LOG_PROTOCOL) {
      // Presence, not values — except the protocol version, which is a
      // published non-secret constant and is the whole point of the capture.
      log(
        `capture route=${route.label} method=${req.method} ` +
        `protocol=${req.headers['mcp-protocol-version'] || '(absent)'} ` +
        `mcp-method=${req.headers['mcp-method'] !== undefined ? 'present' : 'absent'} ` +
        `mcp-name=${req.headers['mcp-name'] !== undefined ? 'present' : 'absent'}`
      );
    }

    const target = route.target;
    const headers = { host: target.host };
    for (const name of FORWARDED_HEADERS) {
      if (req.headers[name] !== undefined) headers[name] = req.headers[name];
    }
    // AFTER the allowlist copy, so no inbound authorization can survive
    // and no route can be talked into a credential it does not own.
    if (route.authorization) headers.authorization = route.authorization;

    const transport = target.protocol === 'https:' ? https : http;
    const upstreamReq = transport.request(
      {
        hostname: target.hostname,
        port: target.port || (target.protocol === 'https:' ? 443 : 80),
        path: target.pathname + target.search + reqUrl.search,
        method: req.method,
        headers,
        agent: route.agent,
      },
      (upstreamRes) => {
        if (res.writableEnded) return;
        res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
        upstreamRes.pipe(res);
      }
    );

    // Multiple independent failure paths below (a body-size abort, an
    // upstream connection error, an inbound error) can each want to end
    // `res` — verified empirically that without this guard, a SECOND path
    // calling res.end() after the FIRST already did throws
    // ERR_STREAM_WRITE_AFTER_END as an uncaught exception and crashes the
    // whole proxy process (killing every other in-flight connection too).
    // Every response-ending call in this handler goes through this one
    // function instead of calling res.writeHead/res.end directly.
    function endWithError(status, message) {
      if (res.writableEnded) return;
      if (!res.headersSent) res.writeHead(status, { 'content-type': 'text/plain' });
      res.end(message);
    }

    // Defense in depth: `res` itself can still error out (e.g. the client
    // already disconnected) independent of anything above — without a
    // listener here, that would ALSO be an uncaught 'error' event.
    res.on('error', (err) => log(`response stream error: ${err.message}`));

    upstreamReq.on('error', (err) => {
      log(`upstream request error on route ${route.label}: ${err.message}`);
      endWithError(502, 'upstream error');
    });

    req.on('error', (err) => {
      log(`inbound request error: ${err.message}`);
      upstreamReq.destroy();
    });

    // Byte-counting guard on top of the pipe, not instead of it — a
    // separate 'data' listener on the same readable stream sees every
    // chunk `.pipe()` is also forwarding (Node dispatches 'data' to all
    // listeners once a stream is flowing), so the body is never buffered
    // in memory just to measure it. Content-Length alone isn't trusted —
    // a client could send a false/absent one and stream more than it
    // declared. unpipe() before destroy(): stops `.pipe()` from attempting
    // to flush any further buffered writes into a target this handler is
    // about to tear down itself.
    let bodyBytes = 0;
    let aborted = false;
    req.on('data', (chunk) => {
      if (aborted) return;
      bodyBytes += chunk.length;
      if (bodyBytes > MAX_BODY_BYTES) {
        aborted = true;
        log(`request body exceeded ${MAX_BODY_BYTES} bytes — aborting`);
        req.unpipe(upstreamReq);
        req.destroy();
        upstreamReq.destroy();
        endWithError(413, 'payload too large');
      }
    });

    req.pipe(upstreamReq);
  });

  server.maxConnections = MAX_CONNECTIONS;
  server.headersTimeout = HEADERS_TIMEOUT_MS;
  server.requestTimeout = REQUEST_TIMEOUT_MS;
  return server;
}

function start() {
  const mcpCredFile = `${RUNTIME_DIR}/mcp_credentials.json`;
  let mcpUrl;
  try {
    const cred = JSON.parse(fs.readFileSync(mcpCredFile, 'utf8'));
    mcpUrl = cred && cred.mcp_url;
  } catch (err) {
    log(`could not read/parse ${mcpCredFile} — did dev-cell-bootstrap.service run? (${err.message})`);
    process.exit(1);
  }
  if (!mcpUrl) {
    log(`${mcpCredFile} has no mcp_url`);
    process.exit(1);
  }

  const cert = readFileOrDie(`${RUNTIME_DIR}/node.crt`, 'node client cert');
  const key = readFileOrDie(`${RUNTIME_DIR}/node.key`, 'node client key');
  const caBundle = readFileOrDie(`${RUNTIME_DIR}/ca-bundle.crt`, 'platform CA bundle');
  // BUG-O: trust BOTH the platform's internal CA (ca-bundle.crt — for the mTLS
  // handshake + any internal endpoints) AND Node's bundled public roots. The
  // upstream platform URL is typically served by a PUBLIC CA (Let's Encrypt)
  // whose issuer isn't in ca-bundle.crt, and Node — unlike curl — does NOT fall
  // back to the system trust store once an explicit `ca` is set, so verification
  // failed "unable to get issuer certificate". Concatenating tls.rootCertificates
  // restores public-CA verification without dropping the internal CA.
  const ca = [caBundle, ...tls.rootCertificates];
  const mtlsAgent = new https.Agent({ cert, key, ca, keepAlive: true });

  let table;
  try {
    table = buildRouteTable({ mcpUrl, mtlsAgent, config: loadRouteConfig(ROUTES_FILE) });
  } catch (err) {
    // Fail closed and LOUD. A half-built route table would leave the
    // operator believing a destination is wired when it is not.
    log(`route config error (${ROUTES_FILE}): ${err.message}`);
    process.exit(1);
  }

  const server = createServer(table);
  server.listen(PORT, BIND_ADDR, () => {
    const summary = [...table.values()]
      .map((r) => `${r.path}->${r.label}${r.authorization ? '(bearer)' : '(mTLS)'}`)
      .join(', ');
    log(`listening on http://${BIND_ADDR}:${PORT} — routes: ${summary}; maxConnections=${MAX_CONNECTIONS}, maxBodyBytes=${MAX_BODY_BYTES}`);
  });

  process.on('SIGTERM', () => server.close(() => process.exit(0)));
  process.on('SIGINT', () => server.close(() => process.exit(0)));
}

// Exported for the test harness; only starts sockets when run as a program.
module.exports = { buildRouteTable, selectRoute, validateConfigPath, createServer, LEGACY_PATH, PROD_PATH };

if (require.main === module) start();
