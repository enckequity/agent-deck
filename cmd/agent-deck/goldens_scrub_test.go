package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestScrubCanonicalSandboxBeforeItsAlias(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX path aliases have no nested drive-prefixed equivalent")
	}
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

func TestScrubSelectedCLIFixture(t *testing.T) {
	if channelsCLIBinPath == "" {
		t.Fatal("CLI fixture was not prepared")
	}
	real, err := filepath.EvalSymlinks(channelsCLIBinPath)
	if err != nil {
		t.Fatal(err)
	}
	got := scrub(real+"\n"+channelsCLIBinPath+"\n", "")
	want := "<AGENT_DECK_BINARY>\n<AGENT_DECK_BINARY>\n"
	if got != want {
		t.Fatalf("scrubbed CLI fixture paths = %q, want %q", got, want)
	}
}
