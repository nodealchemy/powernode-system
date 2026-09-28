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

// TestParseWgLinkShow_RealisticIPLinkJSON exercises readLinkState's
// pure parsing half (IMP-82208d22fdd1) against full, realistic `ip -j
// link show <name>` output — every field a real iproute2 emits, not
// just the three this package reads — to pin two things at once: that
// unrecognized fields don't break parsing, and that the admin-up check
// reads the "UP" flag specifically, NOT operstate or LOWER_UP. A
// WireGuard link commonly reports operstate "UNKNOWN" even while fully
// admin-up (it doesn't run carrier detection the way ethernet does), so
// keying off operstate would have misread every real WG interface as
// down.
func TestParseWgLinkShow_RealisticIPLinkJSON(t *testing.T) {
	cases := []struct {
		name       string
		json       string
		wantMTU    int
		wantMaster string
		wantUp     bool
	}{
		{
			name:       "wg link enslaved to a VRF, operstate UNKNOWN despite being admin-up",
			json:       `[{"ifindex":12,"ifname":"wg-sdwan-aaaa11","flags":["POINTOPOINT","NOARP","UP","LOWER_UP"],"mtu":1420,"qdisc":"noqueue","operstate":"UNKNOWN","linkmode":"DEFAULT","group":"default","txqlen":1000,"link_type":"none","master":"sdwan-aaaa11"}]`,
			wantMTU:    1420,
			wantMaster: "sdwan-aaaa11",
			wantUp:     true,
		},
		{
			name:       "link with no master at all",
			json:       `[{"ifindex":13,"ifname":"wg-sdwan-bbbb22","flags":["POINTOPOINT","NOARP","UP","LOWER_UP"],"mtu":1420,"qdisc":"noqueue","operstate":"UNKNOWN","linkmode":"DEFAULT","group":"default","txqlen":1000,"link_type":"none"}]`,
			wantMTU:    1420,
			wantMaster: "",
			wantUp:     true,
		},
		{
			name:       "LOWER_UP present but UP absent — must read false, not true",
			json:       `[{"ifindex":14,"ifname":"wg-sdwan-cccc33","flags":["POINTOPOINT","NOARP","LOWER_UP"],"mtu":1420,"qdisc":"noop","operstate":"UNKNOWN","linkmode":"DEFAULT","group":"default","txqlen":1000,"link_type":"none","master":"sdwan-cccc33"}]`,
			wantMTU:    1420,
			wantMaster: "sdwan-cccc33",
			wantUp:     false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			state := parseWgLinkShow(tc.json)
			if state == nil {
				t.Fatalf("expected a parsed state, got nil")
			}
			if state.MTU != tc.wantMTU {
				t.Errorf("MTU = %d, want %d", state.MTU, tc.wantMTU)
			}
			if state.Master != tc.wantMaster {
				t.Errorf("Master = %q, want %q", state.Master, tc.wantMaster)
			}
			if state.Up != tc.wantUp {
				t.Errorf("Up = %v, want %v", state.Up, tc.wantUp)
			}
		})
	}
}
