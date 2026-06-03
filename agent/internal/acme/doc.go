// Package acme implements the platform's self-contained ACME client.
//
// Wraps the go-acme/lego library and exposes a small, stable Go API
// the `powernode-acme` command-line binary calls. The CLI is what
// Rails (Acme::LegoClient) shells out to for cert issuance, renewal,
// and revocation.
//
// Self-contained: lego library is vendored via the agent's go.mod;
// no external binary install required on the host. This sits behind
// the same boundary as `powernode-tcp-forwarder` (sibling Go module
// in the agent tree).
//
// Scope (shipped, originating in P2.5.7):
//
//   - DNS-01 issuance against Let's Encrypt prod + staging
//   - Account key reuse via caller-supplied PEM (Rails passes from Vault)
//   - JSON output of cert, private key, issuer chain, account key
//
// All 7 DNS providers are wired in the buildDNSProvider switch below:
// cloudflare, digitalocean, gcloud, hetzner, ovh, porkbun, route53.
// Adding another is one lego import + one switch case.
//
// Plan reference: Decentralized Federation §J + P2.5.7.
package acme
