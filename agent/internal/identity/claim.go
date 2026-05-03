package identity

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"strings"
	"time"
)

// ClaimStrategy completes the physical-device enrollment loop on devices
// flashed from a generic Powernode disk image. Activated when
// BootIdentityStrategy hands back a partial Identity (server+ca but no
// bootstrap token). Polls /api/v1/system/node_api/claim with the
// device's discovered MAC + DMI UUID + hostname every PollInterval
// (default 30s) until either an operator confirms the claim — at which
// point the platform returns a single-use bootstrap token and the
// strategy returns the completed Identity — or the deadline elapses.
//
// Plan: docs/plans/wondrous-yawning-anchor.md §4.
type ClaimStrategy struct {
	// BootStrategy provides PlatformURL + CABundlePEM (and possibly an
	// already-set BootstrapToken, in which case ClaimStrategy is a
	// no-op pass-through). Defaults to a BootIdentityStrategy reading
	// /boot/identity.cfg when nil.
	BootStrategy Strategy

	// PollInterval defaults to 30s; the poll endpoint returns a
	// poll_after_seconds hint that overrides this if longer.
	PollInterval time.Duration

	// MaxPolls bounds the wait. Zero = poll forever (until ctx
	// cancellation). Useful for tests.
	MaxPolls int

	// HTTP client override for tests. Production uses a TLS client
	// configured with the boot-identity CA bundle.
	HTTPClient *http.Client
}

func (s *ClaimStrategy) Name() string { return "claim-poll" }

type claimRequest struct {
	MAC          string `json:"mac"`
	DMIUUID      string `json:"dmi_uuid,omitempty"`
	Hostname     string `json:"hostname,omitempty"`
	AgentVersion string `json:"agent_version,omitempty"`
	Architecture string `json:"architecture,omitempty"`
	PlatformHint string `json:"platform_hint,omitempty"`
}

type claimResponseEnvelope struct {
	Success bool          `json:"success"`
	Data    claimResponse `json:"data"`
}

type claimResponse struct {
	Status            string `json:"status"`
	ClaimCode         string `json:"claim_code,omitempty"`
	BootstrapToken    string `json:"bootstrap_token,omitempty"`
	InstanceUUID      string `json:"instance_uuid,omitempty"`
	PlatformURL       string `json:"platform_url,omitempty"`
	CAPemURL          string `json:"ca_pem_url,omitempty"`
	PollAfterSeconds  int    `json:"poll_after_seconds,omitempty"`
}

func (s *ClaimStrategy) Discover(ctx context.Context) (*Identity, error) {
	// Resolve the boot identity first — needed for PlatformURL + CA chain.
	bootStrat := s.BootStrategy
	if bootStrat == nil {
		bootStrat = &BootIdentityStrategy{}
	}

	boot, err := bootStrat.Discover(ctx)
	if err != nil {
		return nil, err
	}
	if boot == nil || boot.PlatformURL == "" {
		return nil, ErrNotFound
	}

	// If the boot config already has a bootstrap token (e.g. Path A
	// per-instance baked image, or operator pre-staged), pass through.
	if boot.BootstrapToken != "" {
		return boot, nil
	}

	pollInterval := s.PollInterval
	if pollInterval <= 0 {
		pollInterval = 30 * time.Second
	}

	req := s.buildRequest()
	endpoint := strings.TrimSuffix(boot.PlatformURL, "/") + "/api/v1/system/node_api/claim"
	httpClient := s.httpClient(boot)

	// Detach from the Resolver's 30s deadline — claim polling can run
	// for hours waiting for an operator to confirm. WithoutCancel drops
	// both deadline and parent cancellation; agent shutdown relies on
	// systemd SIGTERM ending the process. Acceptable trade-off: the
	// only realistic shutdown path during claim polling is the
	// operator stopping the unit, which kills the process directly.
	pollCtx := context.WithoutCancel(ctx)

	polls := 0
	for {
		select {
		case <-pollCtx.Done():
			return nil, pollCtx.Err()
		default:
		}

		resp, err := s.poll(pollCtx, httpClient, endpoint, req)
		if err != nil {
			// Network errors are non-fatal — the platform might be
			// briefly unreachable, the device should keep trying.
			fmt.Fprintf(os.Stderr, "[ClaimStrategy] poll error: %v\n", err)
		} else if resp.Status == "claimed" && resp.BootstrapToken != "" {
			completed := *boot
			completed.InstanceUUID = resp.InstanceUUID
			completed.BootstrapToken = resp.BootstrapToken
			if completed.PlatformURL == "" && resp.PlatformURL != "" {
				completed.PlatformURL = resp.PlatformURL
			}
			return &completed, nil
		} else if resp.Status == "pending" {
			s.surfaceClaimCode(resp.ClaimCode)
			if resp.PollAfterSeconds > 0 {
				pollInterval = time.Duration(resp.PollAfterSeconds) * time.Second
			}
		}

		polls++
		if s.MaxPolls > 0 && polls >= s.MaxPolls {
			return nil, errors.New("claim: max polls exhausted")
		}

		select {
		case <-pollCtx.Done():
			return nil, pollCtx.Err()
		case <-time.After(pollInterval):
		}
	}
}

func (s *ClaimStrategy) buildRequest() claimRequest {
	hostname, _ := os.Hostname()
	return claimRequest{
		MAC:          discoverMAC(),
		DMIUUID:      discoverDMIUUID(),
		Hostname:     hostname,
		AgentVersion: agentVersion(),
		Architecture: runtime.GOARCH,
	}
}

func (s *ClaimStrategy) poll(ctx context.Context, client *http.Client, url string, req claimRequest) (*claimResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 500 {
		return nil, fmt.Errorf("claim endpoint returned %d", resp.StatusCode)
	}

	var envelope claimResponseEnvelope
	if err := json.Unmarshal(respBody, &envelope); err != nil {
		return nil, err
	}
	return &envelope.Data, nil
}

func (s *ClaimStrategy) httpClient(boot *Identity) *http.Client {
	if s.HTTPClient != nil {
		return s.HTTPClient
	}

	tlsConfig := &tls.Config{}
	if boot.CABundlePEM != "" {
		pool := x509.NewCertPool()
		if pool.AppendCertsFromPEM([]byte(boot.CABundlePEM)) {
			tlsConfig.RootCAs = pool
		}
	}

	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: tlsConfig,
		},
	}
}

// surfaceClaimCode writes the claim code to /dev/tty1 (HDMI console)
// so an operator with a monitor sees the code without needing UI access.
// Best-effort — failures are silent.
func (s *ClaimStrategy) surfaceClaimCode(code string) {
	if code == "" {
		return
	}
	msg := fmt.Sprintf("\n=== Powernode claim code: %s ===\n  Confirm in operator UI to enroll this device.\n\n", code)
	if f, err := os.OpenFile("/dev/tty1", os.O_WRONLY, 0); err == nil {
		_, _ = f.WriteString(msg)
		_ = f.Close()
	}
	// Always log to stderr too so journalctl picks it up.
	fmt.Fprint(os.Stderr, msg)
}

// discoverMAC returns the MAC address of the first non-loopback
// interface (eth0, enp*, etc.). Sorted alphabetically for determinism
// across reboots — same NIC always gets the same canonical MAC.
func discoverMAC() string {
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return ""
	}
	var ifaces []string
	for _, e := range entries {
		if e.Name() == "lo" {
			continue
		}
		ifaces = append(ifaces, e.Name())
	}
	if len(ifaces) == 0 {
		return ""
	}
	// Prefer eth0 if present (RPi convention), else the alphabetically
	// first interface.
	pick := ifaces[0]
	for _, n := range ifaces {
		if n == "eth0" {
			pick = n
			break
		}
	}
	mac, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/address", pick))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(mac))
}

// discoverDMIUUID returns the system UUID. Pi has no DMI; falls back
// to /proc/cpuinfo Serial line for ARM SBCs.
func discoverDMIUUID() string {
	if data, err := os.ReadFile("/sys/class/dmi/id/product_uuid"); err == nil {
		return strings.TrimSpace(string(data))
	}
	if data, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "Serial") {
				if i := strings.LastIndex(line, ":"); i >= 0 {
					return strings.TrimSpace(line[i+1:])
				}
			}
		}
	}
	return ""
}

// agentVersion is sourced from VERSION at build time; the agent's
// main package sets it via -ldflags. Default placeholder for tests.
var agentVersion = func() string { return "0.1.0-dev" }
