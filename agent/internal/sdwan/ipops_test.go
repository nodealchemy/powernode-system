package sdwan

import "testing"

func TestIsIPAddrAddAlreadyExistsErr(t *testing.T) {
	cases := []struct {
		name string
		msg  string
		want bool
	}{
		{
			// Older iproute2 — Ubuntu 22.04, Debian 11 era
			name: "RTNETLINK File exists",
			msg:  "exit status 2: RTNETLINK answers: File exists\n",
			want: true,
		},
		{
			// Newer iproute2 — Ubuntu 24.04, Debian 12+ — the case
			// that surfaced ops2's reconcile-loop spam in this PR.
			name: "ipv6 lowercase already assigned",
			msg:  "exit status 2: Error: ipv6: address already assigned.\n",
			want: true,
		},
		{
			// Same newer iproute2, ipv4 path with capital A
			name: "ipv4 capital Address already assigned",
			msg:  "exit status 2: Error: ipv4: Address already assigned.\n",
			want: true,
		},
		{
			// Real failure — invalid address format — must NOT be
			// swallowed as already-exists.
			name: "garbage CIDR (genuine error)",
			msg:  "exit status 1: Error: any valid prefix is expected rather than \"garbage\".\n",
			want: false,
		},
		{
			// "no such device" is also a real error, not idempotent.
			name: "device not found",
			msg:  "exit status 1: Cannot find device \"wg-does-not-exist\"",
			want: false,
		},
		{
			name: "empty string",
			msg:  "",
			want: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := isIPAddrAddAlreadyExistsErr(tc.msg)
			if got != tc.want {
				t.Errorf("isIPAddrAddAlreadyExistsErr(%q) = %v, want %v", tc.msg, got, tc.want)
			}
		})
	}
}
