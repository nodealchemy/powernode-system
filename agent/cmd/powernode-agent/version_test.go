package main

import (
	"strings"
	"testing"
)

func TestVersionTextReportsPlatformVersion(t *testing.T) {
	oldV, oldP := Version, PlatformVersion
	defer func() { Version, PlatformVersion = oldV, oldP }()

	Version, PlatformVersion = "2026-10-20-0123456789ab", "0.3.0"
	out := versionText()
	if !strings.Contains(out, "powernode-agent 2026-10-20-0123456789ab\n") {
		t.Fatalf("version line must stay date-sha12, got:\n%s", out)
	}
	if !strings.Contains(out, "platform:  0.3.0\n") {
		t.Fatalf("missing platform version line, got:\n%s", out)
	}

	PlatformVersion = ""
	if strings.Contains(versionText(), "platform:") {
		t.Fatalf("no platform line expected when PlatformVersion is empty")
	}
}
