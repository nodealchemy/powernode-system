#!/usr/bin/env node
// dev-cell-mcp-proxy.js — a local, root-owned reverse proxy that is the
// ONLY thing on this instance allowed to hold the node's mTLS client
// cert/key. It listens on 127.0.0.1 and forwards ONLY the /mcp path to
// the platform's real MCP endpoint, presenting the node's client cert on
// the upstream connection.
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
// HARDENING (this proxy is root, on a box where an unprivileged sandbox
// user is deliberately running arbitrary AI-agent-driven code — treat it
// as a real trust boundary, not a convenience shim):
//   * Forwarded headers are an ALLOWLIST, not a passthrough — verified
//     empirically (a real `claude` MCP call captured server-side) which
//     headers the streamable-HTTP transport actually sends: accept,
//     accept-encoding, content-type, content-length, mcp-protocol-version,
//     mcp-session-id. Everything else — notably authorization/cookie/
//     x-forwarded-* — is dropped rather than blindly relayed upstream.
//   * headersTimeout bounds slowloris-style header-dribbling; a generous
//     (not Node's 5-minute default) requestTimeout bounds the whole
//     exchange WITHOUT killing the streamable-HTTP transport's
//     legitimately long-lived GET/SSE connections.
//   * maxConnections caps concurrent sockets — this cell has exactly one
//     sandboxed client (pnagent's `claude`), so there is no legitimate
//     need for many.
//   * Request bodies are size-capped while still streamed (not buffered
//     in memory) to the upstream — a byte counter on the SAME readable
//     stream `.pipe()` is already draining aborts the connection if the
//     candidate exceeds the cap, rather than trusting Content-Length
//     alone (which a client could simply lie about).
//
// No external dependencies — Node core `http`/`https`/`fs`/`url` only, so
// this never needs an `npm install` (registry reachability is not a
// dependency of this unit starting).
//
// Runs as root (owns node.crt/node.key/ca-bundle.crt — see
// dev-cell-mcp-proxy.service). Never logs request/response bodies or
// headers, only structural lines (method, path, status) — the same
// "never log secret material" discipline as every other script in this
// module, even though nothing proxied here is key material itself.
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

// Only these three methods are part of the MCP streamable-HTTP transport
// (POST sends a message, GET opens the server->client SSE stream, DELETE
// terminates a session) — anything else is refused outright rather than
// blindly forwarded.
const ALLOWED_METHODS = new Set(['GET', 'POST', 'DELETE']);
const ALLOWED_PATH = '/mcp';

// Verified empirically (captured server-side headers from a real `claude`
// MCP call through this exact transport) — everything NOT in this list is
// dropped, notably authorization/cookie/x-forwarded-*/user-agent, none of
// which the transport needs and none of which this purely-local proxy
// should blindly relay upstream on a client's say-so.
const FORWARDED_HEADERS = new Set([
  'accept',
  'accept-encoding',
  'content-type',
  'content-length',
  'mcp-protocol-version',
  'mcp-session-id',
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

const target = new URL(mcpUrl);

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

const upstreamAgent = new https.Agent({ cert, key, ca, keepAlive: true });

const server = http.createServer((req, res) => {
  const reqUrl = new URL(req.url, `http://${BIND_ADDR}`);

  if (reqUrl.pathname !== ALLOWED_PATH || !ALLOWED_METHODS.has(req.method)) {
    log(`refused ${req.method} ${reqUrl.pathname} (only ${[...ALLOWED_METHODS].join('/')} ${ALLOWED_PATH} is forwarded)`);
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
    return;
  }

  const headers = { host: target.host };
  for (const name of FORWARDED_HEADERS) {
    if (req.headers[name] !== undefined) headers[name] = req.headers[name];
  }

  const upstreamReq = https.request(
    {
      hostname: target.hostname,
      port: target.port || 443,
      path: target.pathname + target.search + reqUrl.search,
      method: req.method,
      headers,
      agent: upstreamAgent,
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
    log(`upstream request error: ${err.message}`);
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

server.listen(PORT, BIND_ADDR, () => {
  log(`listening on http://${BIND_ADDR}:${PORT}${ALLOWED_PATH} -> ${target.origin}${target.pathname} (mTLS, node cert; maxConnections=${MAX_CONNECTIONS}, maxBodyBytes=${MAX_BODY_BYTES})`);
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
