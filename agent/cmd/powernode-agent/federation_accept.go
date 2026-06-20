package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/federation"
)

// federationAcceptCmd posts the one-shot acceptance handshake to the
// parent platform's /api/v1/system/federation_api/accept endpoint. Reads
// the spawn payload from fw-cfg (LocalQemu path) OR /etc/powernode/
// federation-payload.json (ProxmoxProvider's file-fallback path), then
// invokes federation.Handler.Run.
//
// Intended to be called once per child boot from cloud-init runcmd.
// Idempotent via the marker file: subsequent invocations short-circuit
// if /var/lib/powernode-agent/federation-accepted already exists.
//
// When the agent isn't a federation-spawned child (no payload present),
// the subcommand exits 0 silently — same behavior as when the handshake
// has already completed.
func federationAcceptCmd() *cobra.Command {
	var (
		fwCfgRoot  string
		caFile     string
		markerPath string
		insecure   bool
	)
	c := &cobra.Command{
		Use:   "federation-accept",
		Short: "POST the one-shot federation acceptance handshake to the parent platform",
		Long: `Reads the spawn payload (from fw-cfg or /etc/powernode/federation-payload.json),
constructs the AcceptRequest, and POSTs to <parent_url>/api/v1/system/federation_api/accept.
Idempotent via a marker file; safe to run multiple times.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := federation.LoadConfig(fwCfgRoot)
			if err != nil {
				if errors.Is(err, federation.ErrNotConfigured) {
					fmt.Fprintln(cmd.OutOrStdout(), "[federation-accept] no spawn payload present; nothing to do")
					return nil
				}
				return fmt.Errorf("load federation config: %w", err)
			}

			h := federation.NewHandler()
			if markerPath != "" {
				h.MarkerPath = markerPath
			}
			h.Logf = func(format string, args ...any) {
				fmt.Fprintf(cmd.OutOrStdout(), "[federation-accept] "+format+"\n", args...)
			}
			if caFile != "" {
				data, err := os.ReadFile(caFile)
				if err != nil {
					return fmt.Errorf("read CA bundle %s: %w", caFile, err)
				}
				h.CABundlePEM = string(data)
			}
			if insecure {
				// Bypass TLS verify — dogfood/dev only. The parent's cert
				// might be issued for a different SAN than the agent's
				// connect-to URL (e.g. parent_url=https://ops.ipnode.us but
				// cert is for ops.powernode.org). Operator must opt-in.
				tr := http.DefaultTransport.(*http.Transport).Clone()
				tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
				h.Client = &http.Client{Timeout: 30 * time.Second, Transport: tr}
			}

			ctx, cancel := context.WithTimeout(cmd.Context(), 60*time.Second)
			defer cancel()
			resp, err := h.Run(ctx, cfg)
			if err != nil {
				return fmt.Errorf("federation accept failed: %w", err)
			}
			fmt.Fprintln(cmd.OutOrStdout(), "[federation-accept] handshake complete")

			// Chain into node-api enrollment when the parent included a
			// bootstrap_token for this child. Without this step the agent
			// has federation-peer trust but no node-api mTLS — it can't
			// fetch module assignments. Skip silently if the response
			// has no node_enrollment block (e.g. autonomous_peer mode).
			if resp != nil && resp.Data.NodeEnrollment != nil {
				ne := resp.Data.NodeEnrollment
				fmt.Fprintf(cmd.OutOrStdout(),
					"[federation-accept] node_enrollment present; enrolling subject=%s url=%s\n",
					ne.IntendedSubject, ne.PlatformURL)
				if err := chainNodeEnrollment(ctx, ne, h.CABundlePEM); err != nil {
					return fmt.Errorf("node-api enrollment chained from federation accept failed: %w", err)
				}
				fmt.Fprintln(cmd.OutOrStdout(), "[federation-accept] node-api enrollment complete")
			}
			return nil
		},
	}
	c.Flags().StringVar(&fwCfgRoot, "fw-cfg-root", "", "fw-cfg directory (default /sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode)")
	c.Flags().StringVar(&caFile, "ca-bundle", "", "PEM-encoded CA bundle to trust the parent's TLS cert (optional)")
	c.Flags().StringVar(&markerPath, "marker", "", "path to the success marker file (default /var/lib/powernode-agent/federation-accepted)")
	c.Flags().BoolVar(&insecure, "insecure", false, "skip TLS cert verification (dogfood/dev only; never use in prod)")
	return c
}

// chainNodeEnrollment runs the bootstrap-token → mTLS exchange against
// /node_api/enroll and persists the resulting EnrolledIdentity to
// /var/lib/powernode/pki. This is the bridge that converts federation-
// peer trust (no node-api auth) into a usable mTLS cert for the agent's
// service loop. Uses the public CA bundle when caBundlePEM is empty —
// the parent's cert chain must be publicly trusted (e.g. Let's Encrypt)
// for the default to work.
func chainNodeEnrollment(ctx context.Context, ne *federation.NodeEnrollment, caBundlePEM string) error {
	caPEM := []byte(caBundlePEM)
	if len(caPEM) == 0 {
		// enroll.Client requires a CABundlePEM, but we want to trust the
		// system roots if the operator didn't pass one. Read the host's
		// CA bundle from the standard location.
		bytes, err := os.ReadFile("/etc/ssl/certs/ca-certificates.crt")
		if err != nil {
			return fmt.Errorf("read system CA bundle: %w", err)
		}
		caPEM = bytes
	}

	client := &enroll.Client{
		PlatformURL:  ne.PlatformURL,
		CABundlePEM:  caPEM,
		AgentVersion: Version,
	}

	identity, err := client.Enroll(ctx, enroll.EnrollRequest{
		BootstrapToken: ne.BootstrapToken,
		Subject:        ne.IntendedSubject,
	})
	if err != nil {
		return fmt.Errorf("enroll.Client.Enroll: %w", err)
	}
	// Embed the platform's verification CA on the saved identity so
	// the long-running service can re-establish TLS without re-reading
	// the host CA bundle (it's faster + survives host CA churn).
	identity.CABundlePEM = caPEM

	// Pick the path that matches the current filesystem layout — initramfs
	// hosts get /persist/var/lib/powernode/pki (the mount-gate at
	// powernode-mount.service:22 explicitly waits on that path before
	// pivoting), cloud-VM hosts get the FHS path. Hardcoding either side
	// would silently misroute PKI for the other context; ResolveDefaultPKIDir
	// keeps the two halves coherent.
	paths := enroll.ResolveDefaultPKIPaths()
	if err := enroll.Save(identity, paths); err != nil {
		return fmt.Errorf("enroll.Save: %w", err)
	}
	return nil
}
