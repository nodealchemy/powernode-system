// Package etcsudoers renders one file per declared sudo grant into
// /etc/sudoers.d/, validated by visudo before each atomic write, and
// sweeps any platform-managed files that no longer correspond to an
// active grant.
//
// Each rendered file is named powernode-<module>-<grant_id> — strict
// kebab-case so sudo's filename-processing rules accept it (sudo
// silently skips files in /etc/sudoers.d/ that contain '.' or '~').
//
// Unlike /etc/passwd, sudoers grants are NOT drained on removal —
// sudo is a runtime check with no persistent state, so revoking a
// grant MUST take effect on the next reconcile tick. The sweep step
// deletes files whose backing grant is gone; no grace window.
//
// The sweep matches the powernode- prefix only. Operator-authored
// files (/etc/sudoers.d/90-admins, etc.) are never touched.
package etcsudoers
