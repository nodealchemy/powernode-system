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
// v1 scope (P2.5.7):
//
//   - Cloudflare DNS-01 issuance against Let's Encrypt prod + staging
//   - Account key reuse via caller-supplied PEM (Rails passes from Vault)
//   - JSON output of cert, private key, issuer chain, account key
//
// Other DNS providers (route53, gcloud, digitalocean, hetzner, porkbun,
// ovh) are stubbed with a clear "not yet wired" error message and will
// land incrementally — each lego provider is one import + one switch
// case below.
//
// Plan reference: Decentralized Federation §J + P2.5.7.
package acme
