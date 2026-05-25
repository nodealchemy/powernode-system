// ipops.go — small helpers for `ip` subcommand idempotency. Extracted
// to keep four bridge/wg/vip applier files from independently drifting
// on which iproute2 error messages constitute "already in the desired
// state" vs an actual failure.
package sdwan

import "strings"

// iproute2 has emitted different messages over time for the "you're
// trying to add an address that's already there" case:
//
//   - older iproute2 (Ubuntu 22.04 noble pre-update, Debian 11):
//     "RTNETLINK answers: File exists"
//   - newer iproute2 (Ubuntu 24.04, Debian 12+, recent distros):
//     "Error: ipv6: address already assigned."
//     "Error: ipv4: Address already assigned."
//
// All three substring forms exist in the wild on hosts we currently
// target; pick whichever matches the running ip binary. Without this,
// the agent's reconcile loop spammed the newer-iproute2 message every
// tick on any node whose address was already correctly applied — see
// the long comment in wg_applier.go's apply path for context.
func isIPAddrAddAlreadyExistsErr(msg string) bool {
	return strings.Contains(msg, "File exists") ||
		strings.Contains(msg, "address already assigned") ||
		strings.Contains(msg, "Address already assigned")
}
