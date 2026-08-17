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
//   - the device/subsystem groups below: these are NOT module-declared
//     and cannot be. What references them is config the BASE OS ITSELF
//     ships — /usr/lib/udev/rules.d/*.rules and /usr/lib/tmpfiles.d/*.conf
//     — so "let modules declare what they need" never reaches them, and
//     because this package renders /etc/group AUTHORITATIVELY it replaces
//     the base image's own complete file. Omitting them silently dropped
//     every one, which on dev-cell 2026-08-17 produced, per boot:
//     systemd-tmpfiles: Failed to resolve group 'systemd-journal'/'utmp'
//     systemd-udevd:    Unknown group 'video'/'kvm'/'render'/..., ignoring
//     utempter:         pututline: Permission denied
//     and made `journalctl` unusable for any non-root user ("Failed to
//     check if we are in the 'systemd-journal' group"), forcing sudo for
//     ordinary log reads. The udev failures are the material ones: the
//     rules silently drop GROUP= on /dev/kvm, /dev/dri/render*, /dev/snd/*,
//     video and serial nodes, so unprivileged access to KVM, GPU, audio and
//     serial breaks on a fleet whose purpose is running those workloads.
//
// GIDs match what base-os-ubuntu-noble ships, so the rendered file agrees
// with the image rather than reallocating underneath it. They are also
// clear of the platform's own allocations, which start at 70000 (see
// reserved.go) — no collision is possible.
//
// The rest of Debian's base-passwd set (mail, news, uucp, man, proxy, dip,
// plugdev, staff, games, ...) is deliberately NOT here. Measured on the
// live image: those groups have zero references in shipped udev/tmpfiles/
// systemd config AND own zero files, so adding them would only create dead
// entries. Add a group here when something the OS ships references it or
// owns files as it; otherwise let modules declare what they need.
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

			// Device/subsystem groups referenced by shipped udev rules and
			// tmpfiles.d config. See the package comment above for why these
			// cannot be left to modules. Ordered by GID.
			{Name: "lp", GID: 7},                // parallel/USB printer nodes
			{Name: "kmem", GID: 15},             // /dev/mem, /dev/kmem, /dev/port
			{Name: "dialout", GID: 20},          // serial ports — /dev/ttyS*, /dev/ttyUSB*
			{Name: "cdrom", GID: 24},            // optical devices — /dev/sr*
			{Name: "floppy", GID: 25},           // /dev/fd*
			{Name: "tape", GID: 26},             // /dev/st*, /dev/nst*
			{Name: "audio", GID: 29},            // ALSA — /dev/snd/*
			{Name: "utmp", GID: 43},             // /run/utmp, /var/log/wtmp — utempter, who, w, last
			{Name: "video", GID: 44},            // /dev/video*, /dev/fb*, /dev/dri/card*
			{Name: "render", GID: 994},          // /dev/dri/render* — GPU compute without display access
			{Name: "kvm", GID: 995},             // /dev/kvm — unprivileged VM launch
			{Name: "sgx", GID: 996},             // /dev/sgx_*
			{Name: "input", GID: 997},           // /dev/input/* (most-referenced: 12 shipped rules)
			{Name: "systemd-journal", GID: 999}, // /var/log/journal — non-root `journalctl`

			{Name: "pnadmin", GID: 1000},
			{Name: "nogroup", GID: 65534},
		},
	}
}
