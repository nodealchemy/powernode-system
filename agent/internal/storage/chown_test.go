package storage

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// stubRunFind swaps the package-level runFind with a recorder. Returns
// the captured invocations + a restore function.
func stubRunFind(t *testing.T) (*[][]string, func()) {
	t.Helper()
	original := runFind
	captured := &[][]string{}
	runFind = func(_ context.Context, args []string) error {
		copyArgs := append([]string{}, args...)
		*captured = append(*captured, copyArgs)
		return nil
	}
	return captured, func() { runFind = original }
}

// These two assert on the taskguard.ErrRefused SENTINEL, not on message text.
// They used to match the literal "dangerous mount_path", which passed for any
// error the function happened to return at that point and would have kept
// passing if the guard were replaced by an unrelated failure.
func TestApplyChownRefusesEmptyMountPath(t *testing.T) {
	captured, restore := stubRunFind(t)
	defer restore()
	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "", OldUID: 1, NewUID: 2,
	})
	if !errors.Is(err, taskguard.ErrRefused) {
		t.Errorf("expected refusal of empty mount_path, got %v", err)
	}
	if len(*captured) != 0 {
		t.Errorf("expected find never to run, got %+v", *captured)
	}
}

func TestApplyChownRefusesSlashRoot(t *testing.T) {
	captured, restore := stubRunFind(t)
	defer restore()
	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "/", OldUID: 1, NewUID: 2,
	})
	if !errors.Is(err, taskguard.ErrRefused) {
		t.Errorf("expected refusal of / mount_path, got %v", err)
	}
	if len(*captured) != 0 {
		t.Errorf("expected find never to run, got %+v", *captured)
	}
}

func TestApplyChownNoopWhenIDsUnchanged(t *testing.T) {
	captured, restore := stubRunFind(t)
	defer restore()

	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "/var/lib/postgres", OldUID: 70110, OldGID: 70110, NewUID: 70110, NewGID: 70110,
	})
	if err != nil {
		t.Fatalf("no-op task returned error: %v", err)
	}
	if len(*captured) != 0 {
		t.Errorf("no-op task invoked find: %v", *captured)
	}
}

func TestApplyChownRunsUIDOnlyPassWhenOnlyUIDChanges(t *testing.T) {
	captured, restore := stubRunFind(t)
	defer restore()

	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "/var/lib/postgres",
		OldUID:    100, NewUID: 70110,
		OldGID: 999, NewGID: 999,
	})
	if err != nil {
		t.Fatalf("ApplyChown: %v", err)
	}
	if len(*captured) != 1 {
		t.Fatalf("expected 1 find invocation, got %d (%v)", len(*captured), *captured)
	}
	args := (*captured)[0]
	// Should include -uid 100 and chown 70110, NOT -gid or chgrp.
	if !contains(args, "-uid") || !contains(args, "100") || !contains(args, "70110") {
		t.Errorf("UID pass missing expected args: %v", args)
	}
	if contains(args, "-gid") || contains(args, "chgrp") {
		t.Errorf("UID-only task issued a GID pass: %v", args)
	}
}

func TestApplyChownRunsGIDOnlyPassWhenOnlyGIDChanges(t *testing.T) {
	captured, restore := stubRunFind(t)
	defer restore()

	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "/var/lib/postgres",
		OldUID:    70110, NewUID: 70110,
		OldGID: 100, NewGID: 70110,
	})
	if err != nil {
		t.Fatalf("ApplyChown: %v", err)
	}
	if len(*captured) != 1 {
		t.Fatalf("expected 1 find invocation, got %d", len(*captured))
	}
	args := (*captured)[0]
	if !contains(args, "-gid") || !contains(args, "chgrp") {
		t.Errorf("GID-only task missing GID args: %v", args)
	}
	if contains(args, "-uid") || contains(args, "chown") {
		t.Errorf("GID-only task issued a UID pass: %v", args)
	}
}

func TestApplyChownRunsBothPassesWhenBothChange(t *testing.T) {
	captured, restore := stubRunFind(t)
	defer restore()

	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "/var/lib/postgres",
		OldUID:    100, NewUID: 70110,
		OldGID: 200, NewGID: 70110,
	})
	if err != nil {
		t.Fatalf("ApplyChown: %v", err)
	}
	if len(*captured) != 2 {
		t.Fatalf("expected 2 find invocations, got %d (%v)", len(*captured), *captured)
	}
}

func TestApplyChownPreserveSymlinksAddsNoDereference(t *testing.T) {
	captured, restore := stubRunFind(t)
	defer restore()

	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "/var/lib/postgres",
		OldUID:    100, NewUID: 70110,
		PreserveSymlinks: true,
	})
	if err != nil {
		t.Fatalf("ApplyChown: %v", err)
	}
	if !contains((*captured)[0], "--no-dereference") {
		t.Errorf("PreserveSymlinks did not add --no-dereference: %v", (*captured)[0])
	}
}

func TestApplyChownPropagatesFindFailure(t *testing.T) {
	original := runFind
	defer func() { runFind = original }()
	runFind = func(_ context.Context, _ []string) error {
		return errors.New("simulated find failure")
	}

	err := ApplyChown(context.Background(), &ChownTask{
		MountPath: "/var/lib/postgres",
		OldUID:    100, NewUID: 70110,
	})
	if err == nil || !strings.Contains(err.Error(), "simulated find failure") {
		t.Errorf("expected wrapped find failure, got %v", err)
	}
}

func contains(args []string, needle string) bool {
	for _, a := range args {
		if a == needle {
			return true
		}
	}
	return false
}
