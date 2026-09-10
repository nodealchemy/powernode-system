// Package enroll handles the bootstrap-token → mTLS cert exchange against
// the platform's /api/v1/system/node_api/enroll endpoint.
//
// Once an Identity has been discovered (see internal/identity), enroll
// generates an Ed25519 keypair, builds a CSR signed by the local key, POSTs
// it with the bootstrap token, and persists the returned cert chain in the
// PKI directory chosen by ResolveDefaultPKIPaths — the persist-layer path
// /persist/var/lib/powernode/pki on initramfs/post-pivot hosts, or the FHS
// path /var/lib/powernode/pki on cloud-VM hosts (see storage.go).
//
// # Lifecycle
//
//	identity.Resolve()        —— see internal/identity
//	     │
//	     ▼
//	enroll.Client.Enroll(req)
//	     │
//	     ├── generate Ed25519 keypair (agent private key never leaves the agent)
//	     ├── build CSR with CN = NodeInstance ID, SAN = SDWAN /128
//	     ├── POST /node_api/enroll with token + CSR PEM
//	     ├── platform's InternalCaService signs; returns cert + chain
//	     └── persist cert + chain + key to the resolved PKI dir; chmod 0600 on the key
//
// Subsequent agent operations use this mTLS material via internal/transport.
//
// # Key types
//
//	Client            — wraps the HTTP exchange + TLS pinning
//	EnrollRequest /   — the wire types for POST /node_api/enroll
//	EnrollResponse
//	Keypair           — the locally generated Ed25519 pair (GenerateKeypair);
//	                    BuildCSR turns it into the CSR that is posted
//	EnrolledIdentity  — cert + chain + key, as persisted by Save
//	PKIPaths          — where those land; PathsUnder for an explicit dir,
//	                    ResolveDefaultPKIPaths for the host-dependent default
//
// Persistence is a set of functions over PKIPaths (storage.go) rather than a
// Storage object.
//
// Server-side counterpart: extensions/system/server/app/controllers/api/v1/
// system/node_api/enrollment_controller.rb + node_enrollment_service.rb.
package enroll
