// Package transport wraps the agent's HTTP/gRPC clients with mTLS — every
// request to the platform uses the agent's enrolled cert (see internal/enroll).
//
// Cert rotation is automatic: when the cert is within 30 days of expiry,
// the runtime loop calls RotateIfNearExpiry which issues a fresh CSR (using
// the same Ed25519 key) and updates the in-memory + on-disk cert.
//
// # Key types
//
//   Mtls                 — wraps tls.Config for the platform connection
//   PinnedCABundle       — operator-pinned CA cert(s); rejects unknown CAs
//   RetryClient          — exponential backoff for transient failures (5xx, network)
//
// # Endpoint contract
//
// All platform endpoints under /api/v1/system/node_api/* require this package's
// mTLS material. The platform's InstanceAuthMiddleware validates the agent
// cert, extracts NodeInstance ID from the cert SAN, and gates per-action
// permissions on it.
//
// Endpoints under /api/v1/system/worker_api/* require a separate worker token
// (not handled by this package — used by background jobs only).
//
// Server-side counterpart: extensions/system/server/app/controllers/api/v1/
// system/node_api/base_controller.rb handles the auth middleware.
package transport
