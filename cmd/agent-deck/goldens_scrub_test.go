package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestScrubCanonicalSandboxBeforeItsAlias(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "home")
	target := filepath.Join(base, "private", strings.TrimPrefix(home, string(filepath.Separator)))
	if err := os.MkdirAll(target, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, home); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	real, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(real, home) {
		t.Fatalf("fixture must include its alias: %q, %q", real, home)
	}
	got := scrub(real+"/project\n"+home+"/project\n", home)
	want := "<SANDBOX_HOME>/project\n<SANDBOX_HOME>/project\n"
	if got != want {
		t.Fatalf("scrubbed canonical and alias paths = %q, want %q", got, want)
	}
}
