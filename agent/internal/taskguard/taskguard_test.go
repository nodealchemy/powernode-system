package taskguard

import (
	"errors"
	"strings"
	"testing"
)

// Every case here asserts on the ErrRefused SENTINEL rather than on message
// text, so a rule cannot be replaced by an unrelated failure and still pass.
// The refusal fixtures are values that ESCAPE their intended shape; the accept
// fixtures are values the platform's own producers actually emit.

func mustRefuse(t *testing.T, name string, err error) {
	t.Helper()
	if !errors.Is(err, ErrRefused) {
		t.Fatalf("%s: expected ErrRefused, got %v", name, err)
	}
}

func mustAccept(t *testing.T, name string, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: expected acceptance, got %v", name, err)
	}
}

func TestUnitName(t *testing.T) {
	refuse := map[string]string{
		"traversal":            "../../root/.ssh/authorized_keys",
		"separator":            "sub/dir.mount",
		"backslash":            `sub\dir.mount`,
		"bare dotdot":          "..",
		"leading dot":          ".hidden.mount",
		"leading dash":         "-x.mount",
		"newline":              "ok.mount\nEvil=1",
		"nul":                  "ok\x00.mount",
		"service suffix":       "powernode-019f7cb5-rails.service",
		"no suffix":            "powernode-storage-data",
		"suffix only":          ".mount",
		"empty":                "",
		"space":                "powernode storage.mount",
		"length":               strings.Repeat("a", 300) + ".mount",
		"traversal after join": "../escaped.mount",
	}
	for name, v := range refuse {
		mustRefuse(t, name, UnitName("unit_name", v, ".mount"))
	}

	accept := []string{
		"powernode-storage-mnt-data.mount",
		"powernode-storage-gw-019f7cb5-3858-7000-8000-000000000004.mount",
		"powernode-storage-srv-exports-data.mount",
	}
	for _, v := range accept {
		mustAccept(t, v, UnitName("unit_name", v, ".mount"))
	}

	// With no suffix restriction, a legal bare name is accepted — and the
	// empty value is STILL refused. This form is what isolates the empty rule:
	// with a suffix restriction in play, "" is caught by the suffix check
	// instead, so mutating the empty check alone left every other example
	// green and read as a survivor.
	mustAccept(t, "no suffix restriction", UnitName("unit_name", "anything.service"))
	mustRefuse(t, "empty with no suffix restriction", UnitName("unit_name", ""))
}

func TestAbsPath(t *testing.T) {
	for name, v := range map[string]string{
		"empty":            "",
		"relative":         "srv/data",
		"traversal":        "/srv/../../etc/cron.d",
		"leading dotdot":   "/../etc",
		"dot component":    "/srv/./data",
		"double separator": "/srv//data",
		"trailing slash":   "/srv/data/",
		"newline":          "/srv/data\n/etc *(rw)",
	} {
		mustRefuse(t, name, AbsPath("p", v))
	}
	for _, v := range []string{"/srv/exports/data", "/mnt/data", "/var/lib/postgres", "/etc"} {
		mustAccept(t, v, AbsPath("p", v))
	}
}

func TestTargetPathRefusesCriticalRoots(t *testing.T) {
	for _, v := range []string{
		"/",
		"/etc",
		"/etc/cron.d",
		"/usr/local/bin",
		"/sysroot",
		"/persist/var",
		"/var/lib/powernode",
		"/root/.ssh",
		"/run/sdwan",
	} {
		mustRefuse(t, v, TargetPath("mount_path", v))
	}

	// Ancestor case: mounting here would MASK a critical root beneath it.
	for _, v := range []string{"/var", "/var/lib"} {
		mustRefuse(t, "ancestor "+v, TargetPath("mount_path", v))
	}

	for _, v := range []string{
		"/srv/exports/data",
		"/mnt/data",
		"/var/lib/postgres",
		"/opt/app/data",
		"/home/svc/share",
	} {
		mustAccept(t, v, TargetPath("mount_path", v))
	}
}

func TestIdentifier(t *testing.T) {
	for name, v := range map[string]string{
		"empty":          "",
		"separator":      "acc/1",
		"escape prefix":  "/../escaped",
		"traversal":      "..",
		"leading dot":    ".hidden",
		"leading dash":   "-flag",
		"newline":        "acc\nZZ",
		"space":          "nginx --zz",
		"shell operator": "acc;rm",
	} {
		mustRefuse(t, name, Identifier("id", v))
	}
	for _, v := range []string{
		"019f7cb5-3858-7000-8000-000000000001",
		"acc-1",
		"s_1",
		"nginx",
		"deadbeef",
		"self_hosted",
	} {
		mustAccept(t, v, Identifier("id", v))
	}
}

func TestConfigToken(t *testing.T) {
	for name, v := range map[string]string{
		"empty":        "",
		"newline":      "rw\nZZInjected=1",
		"carriage ret": "rw\rZZInjected=1",
		"tab":          "rw\tZZ",
		"space":        "rw ZZ",
		"nul":          "rw\x00",
		"leading dash": "-o",
	} {
		mustRefuse(t, name, ConfigToken("options[0]", v))
	}
	for _, v := range []string{
		"rw", "_netdev", "vers=4.2", "sec=sys", "no_subtree_check",
		"credentials=/run/sdwan/mount-creds/019f7cb5.cred",
		"fd00::1:/srv/exports/data", "//host/share", "nfs4", "fuse.s3fs",
		"powernode:container", "wg-sdwan-abc123",
	} {
		mustAccept(t, v, ConfigToken("options[0]", v))
	}
}

func TestSecretRefusalNeverEchoesTheValue(t *testing.T) {
	const secret = "correct-horse-battery-staple"
	err := Secret("password", secret+"\nZZ")
	mustRefuse(t, "newline in secret", err)
	if strings.Contains(err.Error(), secret) {
		t.Fatal("Secret refusal echoed the value")
	}
	mustAccept(t, "ordinary password", Secret("password", "s3cret-pass"))
}

func TestIPAddress(t *testing.T) {
	for name, v := range map[string]string{
		"empty":    "",
		"wildcard": "*",
		"comment":  "* # ",
		"cidr":     "fd00::/64",
		"hostname": "peer.example",
		"newline":  "fd00::1\n/ *(rw,no_root_squash)",
	} {
		mustRefuse(t, name, IPAddress("peer_ip", v))
	}
	for _, v := range []string{"fd00::1", "10.125.0.227", "::1"} {
		mustAccept(t, v, IPAddress("peer_ip", v))
	}
}

func TestHost(t *testing.T) {
	for name, v := range map[string]string{
		"empty":        "",
		"leading dash": "-oProxyCommand",
		"space":        "host name",
		"newline":      "host\nZZ",
		"path":         "host/share",
	} {
		mustRefuse(t, name, Host("upstream_source_host", v))
	}
	for _, v := range []string{"fd00::9", "storage.internal", "10.0.0.5", "nfs-01"} {
		mustAccept(t, v, Host("upstream_source_host", v))
	}
}

func TestPlatformPath(t *testing.T) {
	// transport.Client concatenates PlatformURL + path, so anything that does
	// not begin with "/" lands in the authority component.
	for name, v := range map[string]string{
		"empty":             "",
		"userinfo splice":   "@example.invalid/collect",
		"scheme":            "https://example.invalid/collect",
		"protocol relative": "//example.invalid/collect",
		"bare relative":     "api/v1/x",
		"newline":           "/api/v1/x\nHost: evil",
	} {
		mustRefuse(t, name, PlatformPath("callback_path", v))
	}
	for _, v := range []string{
		"/api/v1/system/worker_api/storage/chown_complete",
		"/api/v1/system/node_api/storage_assignments/019f7cb5/credential",
	} {
		mustAccept(t, v, PlatformPath("callback_path", v))
	}
}

func TestHTTPMethodAndEndpoint(t *testing.T) {
	for name, v := range map[string]string{
		"empty":   "",
		"delete":  "DELETE",
		"post":    "POST",
		"unknown": "ZZDESTROY",
		"lower":   "get",
	} {
		mustRefuse(t, name, HTTPMethod("method", v))
	}
	for _, v := range []string{"GET", "HEAD", "OPTIONS"} {
		mustAccept(t, v, HTTPMethod("method", v))
	}

	for name, v := range map[string]string{
		"empty":        "",
		"leading dash": "-ZZ-not-a-url",
		"file scheme":  "file:///etc/shadow",
		"gopher":       "gopher://127.0.0.1:11211/x",
		"no scheme":    "127.0.0.1:8080/healthz",
		"no host":      "http:///healthz",
		"newline":      "http://127.0.0.1/\nZZ",
	} {
		mustRefuse(t, name, HTTPEndpoint("endpoint", v))
	}
	for _, v := range []string{
		"http://127.0.0.1:8080/healthz",
		"https://[::1]:4567/up",
	} {
		mustAccept(t, v, HTTPEndpoint("endpoint", v))
	}
}

// The absent-field case, pinned separately: every rule fails CLOSED on an
// empty value. A validator that silently accepts "" is how a crafted payload
// reaches a default that was never reviewed.
func TestEveryRuleRefusesTheEmptyValue(t *testing.T) {
	rules := map[string]func(string, string) error{
		"UnitName":     func(f, v string) error { return UnitName(f, v, ".mount") },
		"AbsPath":      AbsPath,
		"TargetPath":   TargetPath,
		"Identifier":   Identifier,
		"ConfigToken":  ConfigToken,
		"Secret":       Secret,
		"IPAddress":    IPAddress,
		"Host":         Host,
		"PlatformPath": PlatformPath,
		"HTTPMethod":   HTTPMethod,
		"HTTPEndpoint": HTTPEndpoint,
	}
	for name, rule := range rules {
		mustRefuse(t, name+" on empty", rule("field", ""))
	}
}
