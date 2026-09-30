package runtime

import (
	"errors"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
)

// IMP-3f6c2f35c50d F5: one module's refused sudoers grant is logged and
// signalled through OnError, but is not a failure of the render — upgradeModule
// treats a non-nil applyIdentityAndSudoers as "refusing to restart", so a fatal
// refusal would stall the upgrade of every OTHER module on the node. A real
// write failure stays fatal.
func TestApplyIdentityAndSudoers_RefusedGrantIsSignalledButNotFatal(t *testing.T) {
	orig := applySudoers
	t.Cleanup(func() { applySudoers = orig })

	cases := []struct {
		name      string
		sudoers   error
		wantErr   bool
		wantStage string
	}{
		{
			name: "refusal only",
			sudoers: errors.Join(
				&etcsudoers.RefusedGrantError{ModuleName: "bad", GrantID: "a.b", Reason: "invalid"},
				&etcsudoers.RefusedGrantError{ModuleName: "bad", GrantID: "c/d", Reason: "invalid"},
			),
			wantErr:   false,
			wantStage: "reconciler:sudoers_refused",
		},
		{
			name: "refusal joined with a write failure",
			sudoers: errors.Join(
				&etcsudoers.RefusedGrantError{ModuleName: "bad", GrantID: "a.b", Reason: "invalid"},
				errors.New("write /etc/sudoers.d/powernode-x-y: disk full"),
			),
			wantErr:   true,
			wantStage: "reconciler:sudoers_write",
		},
		{
			name:      "plain failure",
			sudoers:   errors.New("mkdir failed"),
			wantErr:   true,
			wantStage: "reconciler:sudoers_write",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			applySudoers = func([]etcsudoers.Grant) error { return tc.sudoers }
			var stages []string
			r := &Reconciler{cfg: ReconcilerConfig{OnError: func(stage string, err error) { stages = append(stages, stage) }}}
			err := r.applyIdentityAndSudoers(nil, "reconciler:")
			if (err != nil) != tc.wantErr {
				t.Errorf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if !strings.Contains(strings.Join(stages, ","), tc.wantStage) {
				t.Errorf("OnError stages = %v, want %q among them", stages, tc.wantStage)
			}
		})
	}
}
