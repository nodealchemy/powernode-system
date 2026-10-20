package identity

import "github.com/nodealchemy/powernode-system/agent/internal/writeguard"

// stageGuard is the writeguard hook for the staged identity path (no-op in
// production; refuses a write outside the test sandbox under test).
func stageGuard(path string) error { return writeguard.Check(path) }
