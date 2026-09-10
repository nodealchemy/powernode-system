// Package transport builds the mTLS HTTP client the agent uses for every
// post-enrollment call to the platform. It loads cert + key + CA bundle from
// the on-disk PKI directory written by internal/enroll, and does nothing else:
// there is no bearer token, no retry policy type, and no operator-facing CA
// pinning control here.
//
// # Key types
//
//	Client           — an *http.Client built from on-disk mTLS material, plus
//	                   PlatformURL and InstanceID; built by LoadFromPKIDir
//	SwappableClient  — an atomic pointer around a *Client so cert rotation can
//	                   publish refreshed material without the heartbeat,
//	                   reconcile and task-lease loops taking locks
//
// # Where cert rotation actually lives
//
// Not here. runtime.CertRotator owns it: it re-enrolls through
// /api/v1/system/node_api/enroll/refresh authenticated by the EXISTING cert
// (bootstrap tokens are single-use and cannot be reused for refresh), writes
// the new material atomically, and calls SwappableClient.Swap. It rotates at a
// FRACTION of cert lifetime (default 0.75), checked every 6h — not at a fixed
// number of days before expiry. In-flight requests on the old client finish
// cleanly because both certs verify against the same chain until the old
// NotAfter.
//
// # Endpoint contract
//
// All platform endpoints under /api/v1/system/node_api/* require this
// package's mTLS material. The TLS handshake presents the agent's cert; the
// reverse proxy verifies it and forwards the CN to Rails via
// X-Forwarded-Tls-Client-Cert-Info. See Client's own comment for the proxy-side
// clientAuth details, which are load-bearing and have been wrong before.
//
// Endpoints under /api/v1/system/worker_api/* require a separate worker token
// and are not handled by this package.
//
// Server-side counterpart: extensions/system/server/app/controllers/api/v1/
// system/node_api/base_controller.rb.
//
// Reference: Golden Eclipse plan M2.E + M0.P.
package transport
