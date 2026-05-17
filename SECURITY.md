# Security Policy

We take security seriously. This document covers how to report vulnerabilities in the Powernode system extension and what to expect from us in response.

## Reporting a vulnerability

**Do not report security vulnerabilities through public GitHub issues, X, or any other public channel.** Public reports give attackers a window between disclosure and patch availability that we can't shorten.

Email **security@nodealchemy.com** with:

- Description of the vulnerability + components affected
- Steps to reproduce (proof-of-concept welcome but not required)
- Impact assessment (data exposure, privilege escalation, denial of service, supply-chain compromise, etc.)
- Your name + affiliation if you'd like attribution after the fix ships

You can expect:

- **Acknowledgment within 48 hours** of receipt
- A coordinated-disclosure timeline proposal within **5 business days**
- Weekly status updates during active investigation

## Coordinated disclosure

1. You report privately to security@nodealchemy.com
2. We investigate, develop + verify a fix, and assign a CVE if warranted
3. We release the fix + publish a security advisory on the repo
4. You may publish your write-up after the advisory ships

We aim for a 90-day disclosure window from initial report but can negotiate based on complexity. We won't pursue legal action against good-faith security research that follows this policy.

## Scope

**In scope:**

- Server-side Rails (`server/` — models, services, controllers, routes)
- React frontend (`frontend/` — operator UI for fleet + federation)
- The Go on-node agent (`agent/` — boot, enrollment, module attach, mTLS, federation handshake)
- Module supply chain (manifest validation, cosign signing, OCI artifact ingestion)
- Federation protocol (cross-platform peering, grants, social-contract validation, mTLS)
- SDWAN data plane (WireGuard binding, OVN/OVS appliers, BGP session handling)
- Initramfs + disk-image CI (build pipeline, signing, publication)
- Internal CA (Vault PKI adapter + LocalCA dev adapter)

**Out of scope:**

- Vulnerabilities in third-party dependencies — please report to the upstream project first; we'll address our exposure after the upstream fix is available (or sooner if exploitation is imminent)
- Issues requiring physical access to a deployed node
- Theoretical attacks without practical exploitability
- Findings from automated scanners without manual verification
- Misconfigurations of operator-controlled settings (e.g., privileged module attached without operator approval)

## Supported versions

| Version | Supported |
|---|---|
| `develop` branch | Active development; security fixes land here first |
| Most recent tagged release | Critical + high-severity fixes backported |
| Older tags | Please upgrade to the latest tag |

## Acknowledgments

Security researchers who responsibly disclose vulnerabilities through this process are credited in the resulting advisory unless they prefer anonymity. We don't currently run a paid bug bounty.

See also [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) — community conduct issues go through a separate channel (conduct@nodealchemy.com), not the security inbox.
