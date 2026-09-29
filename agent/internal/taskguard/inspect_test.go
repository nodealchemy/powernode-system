package taskguard

import (
	"strings"
	"testing"
)

// The node inspection collectors run as root on the node. Each argument the
// control plane supplies is checked here, and every refusal case is a value
// that escapes the shape its collector expects.

func TestInterfaceName(t *testing.T) {
	refuse := map[string]string{
		"empty":           "",
		"all keyword":     "all",
		"interfaces word": "interfaces",
		"leading dash":    "-x",
		"option shaped":   "--help",
		"leading dot":     ".wg0",
		"dotdot":          "..",
		"separator":       "wg0/../x",
		"space":           "wg0 dump",
		"newline":         "wg0\nall",
		"semicolon":       "wg0;id",
		"too long":        strings.Repeat("a", 16),
		"non ascii":       "wgé0",
		"dollar":          "wg$0",
		"nul":             "wg\x000",
	}
	for name, v := range refuse {
		mustRefuse(t, name, InterfaceName("interface", v))
	}
	for _, v := range []string{"wg0", "wg-sdwan", "vrf_mgmt", "eth0.100", "a", strings.Repeat("a", 15)} {
		mustAccept(t, v, InterfaceName("interface", v))
	}
}

func TestSystemdUnit(t *testing.T) {
	refuse := map[string]string{
		"empty":         "",
		"no suffix":     "sshd",
		"suffix only":   ".service",
		"unknown type":  "sshd.conf",
		"leading dash":  "-x.service",
		"leading dot":   ".x.service",
		"separator":     "../x.service",
		"space":         "a b.service",
		"newline":       "a.service\nb.service",
		"glob":          "powernode-*.service",
		"wildcard q":    "sshd?.service",
		"semicolon":     "a;b.service",
		"too long":      strings.Repeat("a", 260) + ".service",
		"option shaped": "--all.service",
	}
	for name, v := range refuse {
		mustRefuse(t, name, SystemdUnit("unit", v))
	}
	for _, v := range []string{
		"sshd.service", "powernode-agent.service", "systemd-networkd.service",
		"powernode-019f7cb5-3858-7000-8000-000000000004-rails.service",
		"persist-volumes-pg:main.mount", "getty@tty1.service", "wg-quick@wg0.service",
		"multi-user.target", "fstrim.timer", "dbus.socket", "system.slice",
	} {
		mustAccept(t, v, SystemdUnit("unit", v))
	}
}

func TestInspectFilePathAccepts(t *testing.T) {
	for _, v := range []string{
		"/etc/hostname",
		"/etc/systemd/system/powernode-x-rails.service",
		"/etc/systemd/system/powernode-x-rails.service.d/override.conf",
		"/etc/passwd",
		"/usr/sbin/powernode-agent",
		"/usr/lib/systemd/system/sshd.service",
		"/boot/loader/loader.conf",
		"/persist/var/lib/powernode/state.json",
		"/persist/var/lib/powernode/boot-slot.json",
		"/run/powernode/identity-marker",
		"/etc",
		"/etc/",
	} {
		mustAccept(t, v, InspectFilePath("path", v))
	}
}

func TestInspectFilePathRefusesShapeEscapes(t *testing.T) {
	for name, v := range map[string]string{
		"empty":        "",
		"relative":     "etc/hostname",
		"dotdot":       "/etc/../etc/shadow",
		"dotdot up":    "/etc/../../proc/1/environ",
		"dot":          "/etc/./hostname",
		"double slash": "/etc//hostname",
		"newline":      "/etc/hostname\n/etc/shadow",
		"space":        "/etc/host name",
		"nul":          "/etc/host\x00name",
		"too long":     "/etc/" + strings.Repeat("a", 5000),
		"root":         "/",
	} {
		mustRefuse(t, name, InspectFilePath("path", v))
	}
}

// Not on the allow-list is a refusal before any secret rule is consulted.
func TestInspectFilePathRefusesOutsideAllowList(t *testing.T) {
	for name, v := range map[string]string{
		"proc environ":      "/proc/1/environ",
		"proc self environ": "/proc/self/environ",
		"proc mem":          "/proc/1/mem",
		"sys":               "/sys/kernel/notes",
		"dev":               "/dev/sda",
		"root home":         "/root/.bash_history",
		"tmp":               "/tmp/x",
		"home":              "/home/u/.ssh/id_ed25519",
		"var log":           "/var/log/auth.log",
		"sysroot":           "/sysroot/etc/shadow",
		"persist volumes":   "/persist/volumes/pg/PG_VERSION",
		"persist root":      "/persist/anything",
		"etc lookalike":     "/etcetera/hostname",
		"usr lookalike":     "/usrx/bin/ls",
		"run other":         "/run/user/0/bus",
	} {
		mustRefuse(t, name, InspectFilePath("path", v))
	}
}

// Inside the allow-list, secret locations are still refused: the sha256 of a
// low-entropy secret is an offline oracle for it.
func TestInspectFilePathRefusesSecretLocations(t *testing.T) {
	for name, v := range map[string]string{
		"shadow":            "/etc/shadow",
		"shadow backup":     "/etc/shadow-",
		"gshadow":           "/etc/gshadow",
		"opasswd":           "/etc/security/opasswd",
		"security dir":      "/etc/security/limits.conf",
		"ssh host key":      "/etc/ssh/ssh_host_ed25519_key",
		"ssl private":       "/etc/ssl/private/server.pem",
		"wireguard dir":     "/etc/wireguard/wg0.conf",
		"powernode pki":     "/persist/var/lib/powernode/pki/node.key",
		"pki dir itself":    "/persist/var/lib/powernode/pki",
		"pki cert":          "/persist/var/lib/powernode/pki/node.crt",
		"nested pki":        "/etc/powernode/pki/ca-chain.pem",
		"storage keys":      "/run/powernode/storage/keys/cred",
		"credentials dir":   "/etc/powernode/credentials/db",
		"secrets dir":       "/etc/app/secrets/token",
		"private dir":       "/etc/app/private/x.conf",
		"dot ssh":           "/etc/skel/.ssh/id_rsa",
		"key suffix":        "/etc/app/server.key",
		"pem key":           "/etc/app/server-key.pem",
		"privkey":           "/etc/letsencrypt/live/x/privkey.pem",
		"p12":               "/etc/app/store.p12",
		"id rsa":            "/etc/app/id_rsa",
		"env file":          "/etc/app/app.env",
		"dot env":           "/etc/app/.env",
		"netrc":             "/etc/app/.netrc",
		"htpasswd":          "/etc/nginx/.htpasswd",
		"token file":        "/etc/powernode/enroll-token",
		"secret file":       "/etc/app/client_secret",
		"password file":     "/etc/app/db-password",
		"credential file":   "/etc/app/credentials.json",
		"upper case shadow": "/etc/SHADOW",
		"upper case key":    "/etc/app/SERVER.KEY",
		"underscore key":    "/etc/app/signing_key",
	} {
		mustRefuse(t, name, InspectFilePath("path", v))
	}
	// Public halves stay inspectable.
	mustAccept(t, "ssh host public key", InspectFilePath("path", "/etc/ssh/ssh_host_ed25519_key.pub"))
}
