package k3sd

import (
	"context"
	"os"
	"regexp"
	"strings"
	"testing"
)

// IMP-c4fac10a72b6 — the ORACLE for the default K3s server datastore.
//
// K3s runs an etcd member only when the first server starts with
// --cluster-init (or points at an external --datastore-endpoint).
// With neither flag the server's datastore is SQLite via kine. Two
// comments in this package described the zero-value BootstrapConfig
// as "embedded etcd". Every file that ever carried that wording
// outside this package is a document or a seed —
// `git log -S"embedded etcd" -- docs server/db/seeds` names exactly
// four: docs/USE_CASE_MATRIX.md, docs/runbooks/multi-cluster-k3s.md,
// server/db/seeds/k3s_modules.rb and server/db/seeds/system_kb_seed.rb.
// One of them was backup guidance that told operators to snapshot an
// etcd that does not exist (withdrawn at USE_CASE_MATRIX.md:151).
// The Ruby guard server/spec/docs/k3s_single_server_docs_accuracy_spec.rb
// enumerates the live copies; do not restate a count here.
//
// The two halves below are pinned TOGETHER so the claim cannot drift
// back in without a failure:
//
//  1. the EXEC STRING — no BootstrapConfig (zero-value, either CNI, or
//     the flannel-over-SDWAN overlay) makes InstallK3sServer pass a
//     datastore or join flag, and the zero-value install is EXACTLY
//     the bare upstream install line;
//  2. the PROSE — every comment block in this package that mentions
//     etcd must name the SQLite/kine datastore and the --cluster-init
//     prerequisite, must not call the install "embedded etcd", and
//     must not read as deferred work (K3s HA is PARKED by operator
//     decision 2026-09-01).
//
// CAN SEE: a datastore/join flag reaching the exec string from any
// config shape; the exec string drifting from the bare install; a
// comment re-acquiring "embedded etcd" or dropping the datastore
// facts; deferral vocabulary beside an etcd mention.
// CANNOT SEE: an etcd claim phrased without the word "etcd"; the same
// claim in files outside this package (the Ruby guard
// k3s_single_server_docs_accuracy_spec.rb sweeps the documents).

// bareServerInstall is the upstream single-server install line. It
// carries no --cluster-init and no --datastore-endpoint, which is
// exactly why the datastore is SQLite via kine.
const bareServerInstall = `curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=server sh -s -`

func TestInstallK3sServer_NoConfigShapePassesADatastoreOrJoinFlag(t *testing.T) {
	cases := map[string]BootstrapConfig{
		"zero-value":     {},
		"flannel":        {CniPlugin: CniPluginFlannel},
		"ovn-kubernetes": {CniPlugin: CniPluginOvnKubernetes},
		"flannel-over-sdwan": {
			CniPlugin:      CniPluginFlannel,
			FlannelIface:   "wg-sdwan-0",
			FlannelBackend: "host-gw",
			ClusterCidr:    "10.42.0.0/16",
		},
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			a, exec, _ := serverApplierWithTmpPaths(t)
			if err := a.InstallK3sServer(context.Background(), cfg); err != nil {
				t.Fatalf("InstallK3sServer: %v", err)
			}
			if len(exec.calls) != 1 || exec.calls[0].name != "sh" {
				t.Fatalf("expected exactly one sh exec, got %+v", exec.calls)
			}
			script := strings.Join(exec.calls[0].args, " ")
			for _, flag := range []string{"--cluster-init", "--datastore-endpoint", "--server", "--token"} {
				if strings.Contains(script, flag) {
					t.Fatalf("%s: install passes %s — the datastore is no longer SQLite via kine and every document saying so is stale: %q", name, flag, script)
				}
			}
		})
	}
}

func TestInstallK3sServer_ZeroValueIsExactlyTheBareUpstreamInstall(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	if err := a.InstallK3sServer(context.Background(), BootstrapConfig{}); err != nil {
		t.Fatalf("InstallK3sServer: %v", err)
	}
	if len(exec.calls) != 1 {
		t.Fatalf("expected 1 exec call, got %d", len(exec.calls))
	}
	got := exec.calls[0].args
	if len(got) != 2 || got[0] != "-c" || got[1] != bareServerInstall {
		t.Fatalf("zero-value install drifted from the bare upstream line:\n got  %q\n want [-c %q]", got, bareServerInstall)
	}
}

// commentBlocks returns each contiguous run of `//` comment lines in a
// Go source joined into one string, so a hard-wrapped claim is judged
// as a whole rather than line by line (a line-level check passes
// "embedded" on one line and "etcd" on the next).
func commentBlocks(src string) []string {
	var blocks []string
	var cur []string
	flush := func() {
		if len(cur) > 0 {
			blocks = append(blocks, strings.Join(cur, " "))
			cur = nil
		}
	}
	for _, line := range strings.Split(src, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "//") {
			cur = append(cur, strings.TrimSpace(strings.TrimPrefix(trimmed, "//")))
			continue
		}
		flush()
	}
	flush()
	return blocks
}

func TestK3sdComments_DescribeTheDefaultDatastoreAsSQLiteNotEtcd(t *testing.T) {
	// `go test` runs with the package directory as cwd.
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	// Word-boundaried so ordinary prose cannot redden the package:
	// a bare `strings.Contains` match on "pending" fires inside
	// "depending", and "planned" inside "unplanned".
	deferral := regexp.MustCompile(`\b(not yet|planned|coming soon|pending|roadmap|will be (added|supported))\b`)
	etcdBlocks := 0
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		for i, block := range commentBlocks(string(src)) {
			if !strings.Contains(block, "etcd") {
				continue
			}
			etcdBlocks++
			if strings.Contains(block, "embedded etcd") {
				t.Errorf("%s comment block %d calls the install \"embedded etcd\"; the default datastore is SQLite via kine: %q", name, i, block)
			}
			for _, must := range []string{"SQLite", "kine", "--cluster-init"} {
				if !strings.Contains(block, must) {
					t.Errorf("%s comment block %d mentions etcd without naming %q: %q", name, i, must, block)
				}
			}
			if word := deferral.FindString(strings.ToLower(block)); word != "" {
				t.Errorf("%s comment block %d reads as deferred work (%q); K3s HA is PARKED, not scheduled: %q", name, i, word, block)
			}
		}
	}
	if etcdBlocks == 0 {
		t.Fatal("no comment in this package mentions etcd — the datastore is undocumented and this guard is vacuous")
	}
}
