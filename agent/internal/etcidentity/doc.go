// Package etcidentity authoritatively renders /etc/passwd, /etc/group,
// /etc/shadow, and /etc/gshadow on the on-node Powernode root, using
// the user/group declarations served by the platform's modules API.
//
// Authority shift: the agent owns these files end-to-end. Anything not
// in the platform-supplied user/group set (plus a hardcoded baseline
// of root/nobody/daemon/bin/sys) is removed from the rendered output.
// apt-created service accounts are intentionally NOT preserved — the
// whole point of the feature is to escape per-node UID drift.
//
// File-locking: /etc/.pwd.lock is the same advisory lock that glibc's
// lckpwdf() acquires before mutating the passwd database, and that
// useradd/passwd/vipw all respect. Using flock(2) on that file gives
// us mutual exclusion with those tools without a cgo dependency.
//
// Atomicity: each of the four files is written via
// fsutil.AtomicWrite (temp + fsync + rename). The lock window covers
// all four writes, so /etc/shadow can never be out of sync with
// /etc/passwd from a reader's perspective.
//
// Plan reference: ~/.claude/plans/in-the-system-extension-swift-clarke.md
// (Section 7).
package etcidentity
