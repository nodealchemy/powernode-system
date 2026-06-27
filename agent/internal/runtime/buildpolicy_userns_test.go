package runtime

import (
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// TestBuildPolicy_UserNamespaceDefault verifies the documented contract:
// Policy.UserNamespace defaults to true when the manifest omits
// security.user_namespace, and an explicit value is honored either way.
func TestBuildPolicy_UserNamespaceDefault(t *testing.T) {
	t.Run("omitted -> default true", func(t *testing.T) {
		// No security block at all.
		if got := buildPolicy(&manifest.Manifest{}); !got.UserNamespace {
			t.Errorf("nil config: expected UserNamespace=true (default), got false")
		}
		// Security block present but no user_namespace key.
		m := &manifest.Manifest{Config: map[string]any{
			"security": map[string]any{
				"capabilities": []any{"CAP_NET_BIND_SERVICE"},
			},
		}}
		if got := buildPolicy(m); !got.UserNamespace {
			t.Errorf("omitted user_namespace: expected UserNamespace=true (default), got false")
		}
	})

	t.Run("explicit false -> false", func(t *testing.T) {
		m := &manifest.Manifest{Config: map[string]any{
			"security": map[string]any{"user_namespace": false},
		}}
		if got := buildPolicy(m); got.UserNamespace {
			t.Errorf("user_namespace:false: expected UserNamespace=false, got true")
		}
	})

	t.Run("explicit true -> true", func(t *testing.T) {
		m := &manifest.Manifest{Config: map[string]any{
			"security": map[string]any{"user_namespace": true},
		}}
		if got := buildPolicy(m); !got.UserNamespace {
			t.Errorf("user_namespace:true: expected UserNamespace=true, got false")
		}
	})

	t.Run("nil manifest -> default true", func(t *testing.T) {
		if got := buildPolicy(nil); !got.UserNamespace {
			t.Errorf("nil manifest: expected UserNamespace=true (default), got false")
		}
	})
}
