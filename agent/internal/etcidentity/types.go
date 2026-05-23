package etcidentity

// User is the agent-side typed view of a service account declared by
// some installed module. Field shape matches the JSON the platform's
// serialize_module_users emits.
type User struct {
	Name                 string   `json:"name"`
	UID                  int      `json:"uid"`
	PrimaryGID           int      `json:"primary_gid"`
	PrimaryGroup         string   `json:"primary_group"`
	Shell                string   `json:"shell"`
	Home                 string   `json:"home"`
	Gecos                string   `json:"gecos"`
	SupplementaryGroups  []string `json:"supplementary_groups,omitempty"`
}

// Group is the agent-side typed view of a fleet-managed Unix group.
// Members is the server-rendered list of usernames whose primary OR
// supplementary group is this group, scoped to the modules currently
// installed on this node.
type Group struct {
	Name    string   `json:"name"`
	GID     int      `json:"gid"`
	Members []string `json:"members,omitempty"`
}

// Set is the deduplicated union of all User/Group declarations across
// every installed module on this node, plus the hardcoded baseline
// (root, nobody, etc.). Collect builds one of these per reconcile tick.
type Set struct {
	Users  []User
	Groups []Group
}
