package handlers

import (
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/storage"
)

// recordingClient captures the path every POST is aimed at.
type recordingClient struct{ posted []string }

func (c *recordingClient) GetJSON(string) (*http.Response, error) { return nil, nil }

func (c *recordingClient) PostJSON(path string, _ []byte) (*http.Response, error) {
	c.posted = append(c.posted, path)
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("{}"))}, nil
}

// callback_path is the one field whose guard CANNOT live in ChownTask.Validate:
// postChownCompletion runs whether or not ApplyChown refused, so a task whose
// only defect is the callback would be "refused" and then have that refusal —
// error text and all — POSTed to the caller's host over the agent's mTLS
// identity. transport.Client builds its URL as PlatformURL + path, so a value
// not beginning with "/" splices into the authority component.
func TestChownCallbackPathFallsBackToThePlatformDefault(t *testing.T) {
	offOrigin := []string{
		"@example.invalid/collect",            // userinfo splice
		"https://example.invalid/collect",     // absolute URL
		"//example.invalid/collect",           // protocol-relative
		"/api/v1/../../../admin/x",            // on-origin, off-endpoint
		"/api/v1/system/worker_api/x?to=evil", // query string
		"/api/v1/other/endpoint",              // on-origin, outside worker_api
	}
	for _, supplied := range offOrigin {
		if got := chownCallbackPath(supplied); got != defaultChownCallbackPath {
			t.Errorf("callback_path %q resolved to %q; expected the platform default", supplied, got)
		}
	}
}

func TestChownCallbackPathKeepsTheProducersOwnPath(t *testing.T) {
	// System::Storage::ChownDispatchService emits exactly this literal.
	if got := chownCallbackPath(defaultChownCallbackPath); got != defaultChownCallbackPath {
		t.Fatalf("the producer's own callback_path was rewritten to %q", got)
	}
	if got := chownCallbackPath(""); got != defaultChownCallbackPath {
		t.Fatalf("an absent callback_path resolved to %q", got)
	}
}

// The end-to-end shape: a refused task still reports, and never to the
// caller's host.
func TestPostChownCompletionNeverLeavesThePlatformOrigin(t *testing.T) {
	client := &recordingClient{}
	ct := &storage.ChownTask{
		StorageAssignmentID: "019f7cb5-3858-7000-8000-000000000009",
		MountPath:           "/etc",
		OldUID:              0,
		NewUID:              1000,
		CallbackPath:        "@example.invalid/collect",
	}
	if err := postChownCompletion(client, ct, errors.New("taskguard: refused: mount_path: would mask the system path /etc")); err != nil {
		t.Fatalf("callback POST failed: %v", err)
	}
	if len(client.posted) != 1 {
		t.Fatalf("expected exactly one POST, got %v", client.posted)
	}
	if client.posted[0] != defaultChownCallbackPath {
		t.Fatalf("the refusal was POSTed to %q", client.posted[0])
	}
}
