package etcidentity

// Baseline returns the irreducible set of /etc/passwd + /etc/group
// entries that must exist on EVERY node regardless of which modules
// are installed. Hardcoded into the agent binary so first boot has a
// valid user database before the platform has been contacted even
// once — critical for switch_root + init's own user lookups.
//
// Members chosen to satisfy:
//   - root (UID 0): always required; agent itself runs as root.
//   - pnadmin (UID 1000): the platform's standardized human-login
//     account. Matches cloud-image convention (ubuntu/ec2-user
//     also land at 1000). Has NO default sudo grants — break-glass
//     escalation goes through a sudoers grant in a deliberately-
//     installed module, not via an implicit %sudo membership. The
//     authorized_keys flow writes pnadmin's SSH public key to
//     /home/pnadmin/.ssh/authorized_keys. Renamed from "operator"
//     2026-05-30: that name collided with the Debian system group
//     "operator" (GID 37), breaking useradd at cloud-init time.
//   - nobody (UID 65534): NFS root-squash target, kernel-default
//     unprivileged identity, used by countless setuid binaries as the
//     "no permissions" fallback.
//   - daemon (UID 1): traditional unprivileged-service catch-all.
//     Some shipped systemd units still default to it.
//   - bin (UID 2): historical owner of /usr/bin contents; some legacy
//     packages chown to bin during postinst.
//   - sys (UID 3): historical owner of system files; matches Debian's
//     base-passwd defaults.
//   - sshd (UID 105): OpenSSH's privilege-separated child runs as
//     this user; without it sshd accepts the TCP connection then
//     closes immediately at kex_exchange_identification, producing
//     "Connection reset by peer" with no useful sshd log line.
//     A managed-child instance becomes unreachable for ssh-based
//     recovery without this entry. UID 105 matches Ubuntu cloud
//     image convention; group is nogroup (65534).
//
// Standard groups present:
//   - root/daemon/bin/sys/adm/tty/disk/shadow: traditional Unix groups.
//     adm reads system logs, tty controls terminals, disk owns block
//     devices, shadow gates /etc/shadow read access (required for
//     getpwent in some setups).
//   - sudo (GID 27): Ubuntu/Debian convention for the sudoers group.
//     Even though Powernode's pnadmin has no implicit %sudo grant,
//     the GROUP must exist so cloud-init's standard /etc/sudoers
//     line "%sudo ALL=(ALL:ALL) ALL" doesn't error at sudoers parse
//     time. Without this group, `sudo -ln` returns "user X may not
//     run sudo" even for a user explicitly granted via a drop-in.
//
// Add to this list only when a baseline user/group is genuinely
// required to boot — e.g., systemd-network if a future deployment
// expects it pre-populated. Otherwise let modules declare what
// they need.
func Baseline() *Set {
	return &Set{
		Users: []User{
			{Name: "root", UID: 0, PrimaryGID: 0, PrimaryGroup: "root", Shell: "/bin/bash", Home: "/root", Gecos: "root"},
			{Name: "daemon", UID: 1, PrimaryGID: 1, PrimaryGroup: "daemon", Shell: "/usr/sbin/nologin", Home: "/usr/sbin", Gecos: "daemon"},
			{Name: "bin", UID: 2, PrimaryGID: 2, PrimaryGroup: "bin", Shell: "/usr/sbin/nologin", Home: "/bin", Gecos: "bin"},
			{Name: "sys", UID: 3, PrimaryGID: 3, PrimaryGroup: "sys", Shell: "/usr/sbin/nologin", Home: "/dev", Gecos: "sys"},
			{Name: "sshd", UID: 105, PrimaryGID: 65534, PrimaryGroup: "nogroup", Shell: "/usr/sbin/nologin", Home: "/run/sshd", Gecos: ""},
			{Name: "pnadmin", UID: 1000, PrimaryGID: 1000, PrimaryGroup: "pnadmin", Shell: "/bin/bash", Home: "/home/pnadmin", Gecos: "Powernode admin"},
			{Name: "nobody", UID: 65534, PrimaryGID: 65534, PrimaryGroup: "nogroup", Shell: "/usr/sbin/nologin", Home: "/nonexistent", Gecos: "nobody"},
		},
		Groups: []Group{
			{Name: "root", GID: 0},
			{Name: "daemon", GID: 1},
			{Name: "bin", GID: 2},
			{Name: "sys", GID: 3},
			{Name: "adm", GID: 4},
			{Name: "tty", GID: 5},
			{Name: "disk", GID: 6},
			{Name: "sudo", GID: 27},
			{Name: "shadow", GID: 42}, // /etc/shadow group-ownership — read by getpwent
			{Name: "pnadmin", GID: 1000},
			{Name: "nogroup", GID: 65534},
		},
	}
}
