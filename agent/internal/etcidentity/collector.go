package etcidentity

import (
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
func Collect(manifests []*manifest.Manifest) (*Set, []Conflict) {
	set := Baseline()
	conflicts := []Conflict{}

	userByName := map[string]int{} // name -> index into set.Users
	for i, u := range set.Users {
		userByName[u.Name] = i
	}
	groupByName := map[string]int{}
	for i, g := range set.Groups {
		groupByName[g.Name] = i
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
			userByName[u.Name] = len(set.Users)
			set.Users = append(set.Users, u)
		}
		for _, mg := range m.Groups {
			g := Group{Name: mg.Name, GID: mg.GID, Members: mg.Members}
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
			groupByName[g.Name] = len(set.Groups)
			set.Groups = append(set.Groups, g)
		}
	}

	sort.Slice(set.Users, func(i, j int) bool { return set.Users[i].UID < set.Users[j].UID })
	sort.Slice(set.Groups, func(i, j int) bool { return set.Groups[i].GID < set.Groups[j].GID })

	return set, conflicts
}

// Conflict reports a duplicate-name-with-different-id situation that
// Collect resolved via first-wins. Surface these via the agent's
// OnError hook so operators learn about server-side allocator drift.
type Conflict struct {
	Kind          string // "user" or "group"
	Name          string
	KeptValue     int
	DroppedValue  int
	SourceModule  string
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
