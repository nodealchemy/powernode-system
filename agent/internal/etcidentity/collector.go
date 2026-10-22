package etcidentity

import (
	"fmt"
	"sort"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// Collect unions all User/Group declarations across the supplied
// manifests with the hardcoded baseline, deduplicating by name. The
// returned Set's Users and Groups are sorted by UID/GID (ascending),
// which makes the rendered /etc/passwd byte-stable across reconcile
// ticks for the same input — no spurious diffs that would trigger
// gratuitous atomic writes.
//
// Conflict policy: if two manifests declare the same username with
// different UIDs (a server-side bug that should never happen given the
// platform-global allocator), the first definition wins and we report
// the conflict via the returned slice of warnings. Caller logs/raises
// as appropriate; the agent does NOT abort the render — a working
// /etc/passwd with one wrong UID is better than no /etc/passwd.
//
// Validation (IMP-01a0f109): every manifest entry is checked before it joins
// the Set, and a failing one is SKIPPED and recorded in Set.Refused (callers
// report those). A manifest entry is refused when any rendered field could
// break the colon/newline line format (CheckUserFields/CheckGroupFields),
// when its uid/gid is outside the platform range (so never 0, the system
// range, or a baseline id), when it redeclares a built-in user name, when it
// takes a uid/gid or managed home that the baseline or ANOTHER module
// already holds, or when it would add members to a privileged
// baseline group (sudo, disk, shadow, ...).
func Collect(manifests []*manifest.Manifest) (*Set, []Conflict) {
	set := Baseline()
	conflicts := []Conflict{}

	userByName := map[string]int{} // name -> index into set.Users
	uidOwner := map[int]owner{}
	homeOwner := map[string]owner{}
	baselineUsers := map[string]bool{}
	for i, u := range set.Users {
		userByName[u.Name] = i
		uidOwner[u.UID] = owner{name: u.Name}
		baselineUsers[u.Name] = true
		if isManagedHome(u.Home) {
			homeOwner[cleanHome(u.Home)] = owner{name: u.Name}
		}
	}
	groupByName := map[string]int{}
	gidOwner := map[int]owner{}
	baselineGroups := map[string]bool{}
	for i, g := range set.Groups {
		groupByName[g.Name] = i
		gidOwner[g.GID] = owner{name: g.Name}
		baselineGroups[g.Name] = true
	}
	refuse := func(kind, name, module, reason string) {
		set.Refused = append(set.Refused, Refusal{Kind: kind, Name: name, SourceModule: module, Reason: reason})
	}

	for _, m := range manifests {
		if m == nil {
			continue
		}
		for _, mu := range m.Users {
			u := User{
				Name:                mu.Name,
				UID:                 mu.UID,
				PrimaryGID:          mu.PrimaryGID,
				PrimaryGroup:        mu.PrimaryGroup,
				Shell:               mu.Shell,
				Home:                mu.Home,
				Gecos:               mu.Gecos,
				SupplementaryGroups: mu.SupplementaryGroups,
			}
			if err := checkManifestUser(u, baselineUsers); err != nil {
				refuse("user", u.Name, m.ID, err.Error())
				continue
			}
			if idx, seen := userByName[u.Name]; seen {
				if set.Users[idx].UID != u.UID {
					conflicts = append(conflicts, Conflict{
						Kind: "user", Name: u.Name,
						KeptValue: set.Users[idx].UID, DroppedValue: u.UID,
						SourceModule: m.ID,
					})
				}
				continue
			}
			if o, taken := uidOwner[u.UID]; taken && o.foreignTo(m.ID) {
				refuse("user", u.Name, m.ID, fmt.Sprintf("uid %d already belongs to %s", u.UID, o))
				continue
			}
			if isManagedHome(u.Home) {
				if o, taken := homeOwner[cleanHome(u.Home)]; taken && o.foreignTo(m.ID) {
					refuse("user", u.Name, m.ID, fmt.Sprintf("home %s already belongs to %s", cleanHome(u.Home), o))
					continue
				}
				homeOwner[cleanHome(u.Home)] = owner{name: u.Name, module: m.ID}
			}
			uidOwner[u.UID] = owner{name: u.Name, module: m.ID}
			userByName[u.Name] = len(set.Users)
			set.Users = append(set.Users, u)
		}
		for _, mg := range m.Groups {
			g := Group{Name: mg.Name, GID: mg.GID, Members: mg.Members}
			if err := checkManifestGroup(g); err != nil {
				refuse("group", g.Name, m.ID, err.Error())
				continue
			}
			if baselineGroups[g.Name] && privilegedGroups[g.Name] {
				refuse("group", g.Name, m.ID, "is a privileged built-in group a module may not add members to")
				continue
			}
			if idx, seen := groupByName[g.Name]; seen {
				if set.Groups[idx].GID != g.GID {
					conflicts = append(conflicts, Conflict{
						Kind: "group", Name: g.Name,
						KeptValue: set.Groups[idx].GID, DroppedValue: g.GID,
						SourceModule: m.ID,
					})
				}
				// Merge supplementary-group members so a group declared
				// in one module is reachable by users in another that
				// reference it as supplementary.
				set.Groups[idx].Members = mergeStrings(set.Groups[idx].Members, g.Members)
				continue
			}
			if o, taken := gidOwner[g.GID]; taken && o.foreignTo(m.ID) {
				refuse("group", g.Name, m.ID, fmt.Sprintf("gid %d already belongs to %s", g.GID, o))
				continue
			}
			gidOwner[g.GID] = owner{name: g.Name, module: m.ID}
			groupByName[g.Name] = len(set.Groups)
			set.Groups = append(set.Groups, g)
		}
	}

	sort.Slice(set.Users, func(i, j int) bool { return set.Users[i].UID < set.Users[j].UID })
	sort.Slice(set.Groups, func(i, j int) bool { return set.Groups[i].GID < set.Groups[j].GID })

	return set, conflicts
}

// owner records who first claimed a uid, gid or managed home. module is ""
// for the baseline. A claim by a DIFFERENT module (or over the baseline) is
// refused; the same module ID may reuse it, because the reconciler unions an
// old and a new digest of one module during an upgrade and a renamed user
// that keeps its id is a legitimate migration (see applyIdentityAndSudoers).
type owner struct{ name, module string }

func (o owner) foreignTo(module string) bool { return o.module == "" || o.module != module }

func (o owner) String() string {
	if o.module == "" {
		return fmt.Sprintf("built-in %q", o.name)
	}
	return fmt.Sprintf("%q (module %s)", o.name, o.module)
}

// Conflict reports a duplicate-name-with-different-id situation that
// Collect resolved via first-wins. Surface these via the agent's
// OnError hook so operators learn about server-side allocator drift.
type Conflict struct {
	Kind         string // "user" or "group"
	Name         string
	KeptValue    int
	DroppedValue int
	SourceModule string
}

func mergeStrings(a, b []string) []string {
	if len(b) == 0 {
		return a
	}
	seen := map[string]struct{}{}
	out := make([]string, 0, len(a)+len(b))
	for _, s := range a {
		if _, dup := seen[s]; dup {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	for _, s := range b {
		if _, dup := seen[s]; dup {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
