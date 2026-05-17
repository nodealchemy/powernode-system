// Command powernode-acme is the platform's self-contained ACME client.
//
// Rails (Acme::LegoClient) shells out to this binary for cert issuance
// against Let's Encrypt + a DNS provider. v1 wires Cloudflare DNS-01;
// other lego providers are stubbed for incremental landing.
//
// Subcommands:
//
//	issue     — obtain a new cert
//	renew     — renew an existing cert (P2.5.7.next)
//	revoke    — revoke an issued cert (P2.5.7.next)
//
// Token handling — provider API tokens are NEVER passed as flags
// (would appear in process listings). The caller sets an env var and
// passes its NAME via --cf-token-env / similar; this binary reads
// the value via os.Getenv at request time. Single process, single
// invocation, no on-disk caching.
//
// Output — single JSON object on stdout on success or failure. The
// caller parses, never tries to interpret stderr. Stderr is reserved
// for lego's internal progress logs.
//
// Plan reference: Decentralized Federation §J + P2.5.7.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	acmepkg "github.com/nodealchemy/powernode-system/agent/internal/acme"
)

// emit prints v as JSON to stdout and exits. Always exits 0 on
// success-shaped result; non-zero only for unparseable CLI invocation.
// The caller distinguishes success/failure via result.ok, not exit code.
func emit(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		fmt.Fprintf(os.Stderr, "powernode-acme: encode result: %v\n", err)
		os.Exit(2)
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "powernode-acme: subcommand required (issue|renew|revoke)")
		os.Exit(2)
	}

	switch os.Args[1] {
	case "issue":
		runIssue(os.Args[2:])
	case "renew":
		runRenew(os.Args[2:])
	case "revoke":
		runRevoke(os.Args[2:])
	case "version":
		emit(map[string]string{"version": Version, "git_commit": GitCommit, "build_date": BuildDate})
	default:
		fmt.Fprintf(os.Stderr, "powernode-acme: unknown subcommand %q\n", os.Args[1])
		os.Exit(2)
	}
}

func runIssue(args []string) {
	fs := flag.NewFlagSet("issue", flag.ExitOnError)
	domain := fs.String("domain", "", "Primary domain (CN). Required.")
	sansCSV := fs.String("sans", "", "Comma-separated SAN list (optional).")
	email := fs.String("email", "", "ACME account contact email. Required.")
	acmeServer := fs.String("acme-server", "", "ACME directory URL. Defaults to LE prod.")
	issuer := fs.String("issuer", "letsencrypt-prod", "Issuer label (passed through to result).")
	dnsProvider := fs.String("dns", "cloudflare", "DNS-01 provider slug. v1: cloudflare only.")
	accountKeyPEM := fs.String("account-key-pem", "", "Existing account key PEM (optional). Empty = generate fresh.")
	cfTokenEnv := fs.String("cf-token-env", "CLOUDFLARE_DNS_API_TOKEN",
		"Name of env var holding the Cloudflare API token. Default CLOUDFLARE_DNS_API_TOKEN.")
	if err := fs.Parse(args); err != nil {
		emit(acmepkg.IssueResult{OK: false, Error: err.Error()})
		return
	}

	var sans []string
	if *sansCSV != "" {
		sans = splitCSV(*sansCSV)
	}

	result, err := acmepkg.Issue(acmepkg.IssueParams{
		Domain:                *domain,
		SANs:                  sans,
		Email:                 *email,
		ACMEServer:            *acmeServer,
		Issuer:                *issuer,
		DNSProvider:           *dnsProvider,
		AccountKeyPEM:         *accountKeyPEM,
		CloudflareAPITokenEnv: *cfTokenEnv,
	})
	if err != nil {
		emit(acmepkg.IssueResult{OK: false, Error: err.Error()})
		return
	}
	emit(result)
}

// runRenew shares Issue's flag surface — renewal IS reissuance under
// the same account key. The account_key_pem flag is required (Issue's
// is optional); the Rails caller passes it from Vault.
func runRenew(args []string) {
	fs := flag.NewFlagSet("renew", flag.ExitOnError)
	domain := fs.String("domain", "", "Primary domain (CN). Required.")
	sansCSV := fs.String("sans", "", "Comma-separated SAN list (optional).")
	email := fs.String("email", "", "ACME account contact email. Required.")
	acmeServer := fs.String("acme-server", "", "ACME directory URL. Defaults to LE prod.")
	issuer := fs.String("issuer", "letsencrypt-prod", "Issuer label.")
	dnsProvider := fs.String("dns", "cloudflare", "DNS-01 provider slug.")
	accountKeyPEM := fs.String("account-key-pem", "", "Existing account key PEM. REQUIRED for renewal.")
	cfTokenEnv := fs.String("cf-token-env", "CLOUDFLARE_DNS_API_TOKEN",
		"Name of env var holding the Cloudflare API token.")
	if err := fs.Parse(args); err != nil {
		emit(acmepkg.IssueResult{OK: false, Error: err.Error()})
		return
	}

	var sans []string
	if *sansCSV != "" {
		sans = splitCSV(*sansCSV)
	}

	result, err := acmepkg.Renew(acmepkg.IssueParams{
		Domain:                *domain,
		SANs:                  sans,
		Email:                 *email,
		ACMEServer:            *acmeServer,
		Issuer:                *issuer,
		DNSProvider:           *dnsProvider,
		AccountKeyPEM:         *accountKeyPEM,
		CloudflareAPITokenEnv: *cfTokenEnv,
	})
	if err != nil {
		emit(acmepkg.IssueResult{OK: false, Error: err.Error()})
		return
	}
	emit(result)
}

// runRevoke takes a cert PEM (from a file — too large for argv reliably)
// + the account key (also from a file) + reason code.
func runRevoke(args []string) {
	fs := flag.NewFlagSet("revoke", flag.ExitOnError)
	certFile := fs.String("cert-pem-file", "", "Path to file containing the cert PEM to revoke. Required.")
	keyFile := fs.String("account-key-pem-file", "",
		"Path to file containing the ACME account key PEM. Required.")
	email := fs.String("email", "", "ACME account email. Required (must match issuing account).")
	acmeServer := fs.String("acme-server", "", "ACME directory URL.")
	issuer := fs.String("issuer", "letsencrypt-prod", "Issuer label.")
	reason := fs.Uint("reason", 0,
		"RFC 5280 revocation reason code (0=unspecified, 1=keyCompromise, 4=superseded, 5=cessation, ...)")
	if err := fs.Parse(args); err != nil {
		emit(acmepkg.RevokeResult{OK: false, Error: err.Error()})
		return
	}

	if *certFile == "" || *keyFile == "" {
		emit(acmepkg.RevokeResult{OK: false, Error: "cert-pem-file + account-key-pem-file required"})
		return
	}

	certPEM, err := os.ReadFile(*certFile)
	if err != nil {
		emit(acmepkg.RevokeResult{OK: false, Error: fmt.Sprintf("read cert: %v", err)})
		return
	}
	accountKeyPEM, err := os.ReadFile(*keyFile)
	if err != nil {
		emit(acmepkg.RevokeResult{OK: false, Error: fmt.Sprintf("read account key: %v", err)})
		return
	}

	result, err := acmepkg.Revoke(acmepkg.RevokeParams{
		CertPEM:       string(certPEM),
		AccountKeyPEM: string(accountKeyPEM),
		Email:         *email,
		ACMEServer:    *acmeServer,
		Issuer:        *issuer,
		Reason:        *reason,
	})
	if err != nil {
		emit(acmepkg.RevokeResult{OK: false, Error: err.Error()})
		return
	}
	emit(result)
}

func splitCSV(csv string) []string {
	var out []string
	start := 0
	for i := 0; i <= len(csv); i++ {
		if i == len(csv) || csv[i] == ',' {
			tok := csv[start:i]
			if tok != "" {
				out = append(out, tok)
			}
			start = i + 1
		}
	}
	return out
}

// Build-time ldflag injection — matches the powernode-agent build.
// See Makefile LDFLAGS.
var (
	Version   = "dev"
	GitCommit = "unknown"
	BuildDate = "unknown"
)
