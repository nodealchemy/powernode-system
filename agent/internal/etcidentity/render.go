package etcidentity

import (
	"fmt"
	"strings"
)

// RenderPasswd returns the byte slice that should be written to
// /etc/passwd. One line per user, glibc colon-separated format:
//
//	name:x:uid:gid:gecos:home:shell\n
//
// The literal 'x' password field signals "see /etc/shadow." All
// service accounts have locked shadow entries ('*') so this is purely
// a placeholder — there is no shadow lookup that would succeed.
func RenderPasswd(set *Set) []byte {
	var b strings.Builder
	for _, u := range set.Users {
		fmt.Fprintf(&b, "%s:x:%d:%d:%s:%s:%s\n",
			u.Name, u.UID, u.PrimaryGID, u.Gecos, u.Home, u.Shell)
	}
	return []byte(b.String())
}

// RenderGroup returns /etc/group content. Format:
//
//	name:x:gid:member1,member2,...\n
//
// The members list is whatever Collect captured — typically just
// supplementary memberships (users whose PRIMARY group this is are
// implicitly members via /etc/passwd's gid field, so getgrnam still
// resolves them correctly without listing them here, but we include
// them for compatibility with tools that scan /etc/group directly).
func RenderGroup(set *Set) []byte {
	var b strings.Builder
	for _, g := range set.Groups {
		fmt.Fprintf(&b, "%s:x:%d:%s\n", g.Name, g.GID, strings.Join(g.Members, ","))
	}
	return []byte(b.String())
}

// RenderShadow returns /etc/shadow content. Every service account
// gets a locked password ('*') — by design these are never login
// accounts. Format per shadow(5):
//
//	name:password:lastchange:min:max:warn:inactive:expire:reserved\n
//
// Zero values for the date fields mean "no expiry, no warnings,
// password change unrestricted" — the locked password is the gate.
func RenderShadow(set *Set) []byte {
	var b strings.Builder
	for _, u := range set.Users {
		// Skip the root entry — operator passwords for root are managed
		// outside the platform (initramfs / hardware-secure boot flow).
		// Writing '*' here would lock the root account, which is a foot-
		// gun for break-glass recovery scenarios.
		if u.Name == "root" {
			fmt.Fprintln(&b, "root:!*:::::::")
			continue
		}
		fmt.Fprintf(&b, "%s:*:::::::\n", u.Name)
	}
	return []byte(b.String())
}

// RenderGshadow returns /etc/gshadow content. Service groups have no
// administrators and no password — we emit the minimal valid line
// format that getsgrnam accepts.
//
//	name:password:administrators:members\n
func RenderGshadow(set *Set) []byte {
	var b strings.Builder
	for _, g := range set.Groups {
		fmt.Fprintf(&b, "%s:!::%s\n", g.Name, strings.Join(g.Members, ","))
	}
	return []byte(b.String())
}
