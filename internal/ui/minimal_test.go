package ui

// Golden + invariant tests for the minimal home-screen style ([ui] style =
// "minimal"). Regenerate the goldens with:
//
//	UPDATE_GOLDEN=1 go test ./internal/ui/ -run TestMinimalUI_Golden

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/asheshgoplani/agent-deck/internal/session"
	"github.com/asheshgoplani/agent-deck/internal/tmux"
)

// enableMinimalUIForTest turns minimal mode on for one test and restores the
// upstream look afterwards so no other test sees the minimal palette.
func enableMinimalUIForTest(t *testing.T) {
	t.Helper()
	setMinimalUI(true)
	t.Cleanup(func() { setMinimalUI(false) })
}

// newMinimalTestHome builds a Home with two groups: teamshift (working, to
// review, error) and enck-os (idle), with the cursor on selectTitle.
func newMinimalTestHome(t *testing.T, width, height int, selectTitle string, collapseEnck bool) *Home {
	t.Helper()
	home := NewHome()
	// NewHome applies the (isolated, empty) user config, which turns minimal
	// mode off; enable it afterwards.
	enableMinimalUIForTest(t)
	home.width = width
	home.height = height
	home.initialLoading = false
	// Filters and view mode persist in the shared _test profile; pin them so
	// earlier tests cannot change the rendered order or the filter slot.
	home.statusFilter = ""
	home.timeFilter = session.TimeFilterAll
	home.groupViewMode = session.GroupViewNormal
	home.previewMode = PreviewModeBoth

	homeDir, _ := os.UserHomeDir()
	mk := func(title, group string, status session.Status) *session.Instance {
		inst := session.NewInstanceWithTool(title, filepath.Join(homeDir, "dev", group), "claude")
		inst.GroupPath = group
		inst.Status = status
		return inst
	}
	instances := []*session.Instance{
		mk("fix login flow", "teamshift", session.StatusRunning),
		mk("review pricing page", "teamshift", session.StatusWaiting),
		mk("sync leads", "teamshift", session.StatusError),
		mk("calendar polish", "enck-os", session.StatusIdle),
	}

	home.instancesMu.Lock()
	home.instances = instances
	home.instancesMu.Unlock()
	home.groupTree = session.NewGroupTree(instances)
	if collapseEnck {
		home.groupTree.CollapseGroup("enck-os")
	}
	home.refreshSessionRenderSnapshot(nil)
	home.rebuildFlatItems()

	home.cursor = -1
	for i, it := range home.flatItems {
		if it.Type == session.ItemTypeSession && it.Session != nil && it.Session.Title == selectTitle {
			home.cursor = i
		}
	}
	if home.cursor < 0 {
		t.Fatalf("fixture session %q not in flatItems", selectTitle)
	}
	return home
}

func TestMinimalUI_Golden(t *testing.T) {
	cases := []struct {
		name          string
		width, height int
		selectTitle   string
		collapseEnck  bool
		timestamps    bool
	}{
		{"home_120x32", 120, 32, "review pricing page", false, true},
		{"home_80x24", 80, 24, "sync leads", true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			home := newMinimalTestHome(t, tc.width, tc.height, tc.selectTitle, tc.collapseEnck)
			home.showSessionTimestamps = tc.timestamps
			got := tmux.StripANSI(home.View())

			assertMinimalFrame(t, got, tc.width, tc.height)

			path := filepath.Join("testdata", "minimal", tc.name+".golden")
			if os.Getenv("UPDATE_GOLDEN") != "" {
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read golden %s: %v (UPDATE_GOLDEN=1 to create)", path, err)
			}
			if got != string(want) {
				t.Errorf("minimal frame differs from %s (UPDATE_GOLDEN=1 to regenerate)\n--- got ---\n%s\n--- want ---\n%s", path, got, want)
			}
		})
	}
}

// assertMinimalFrame checks the design invariants independent of the golden.
func assertMinimalFrame(t *testing.T, frame string, width, height int) {
	t.Helper()
	banned := []string{
		"📁", "⏱", "📌", "⬢", "🔒", "⚡", "├", "└", "▶", "▾", "1·",
		"SESSIONS", "PREVIEW", "This can happen if",
		"!@#", "filter •", "auto-dismiss", "⟨", "Agent Deck",
		"Status:", "Model:", "Not connected",
	}
	for _, s := range banned {
		if strings.Contains(frame, s) {
			t.Errorf("minimal frame contains %q", s)
		}
	}
	lines := strings.Split(frame, "\n")
	if len(lines) != height {
		t.Errorf("frame has %d lines, want %d", len(lines), height)
	}
	for i, line := range lines {
		if w := lipgloss.Width(line); w > width {
			t.Errorf("line %d is %d cells wide, want <= %d: %q", i, w, width, line)
		}
	}
	for _, want := range []string{"agent deck", "1 working", "1 to review", "1 error", "teamshift"} {
		if !strings.Contains(frame, want) {
			t.Errorf("minimal frame missing %q", want)
		}
	}
}

func TestMinimalUI_ErrorPanelIsTwoLines(t *testing.T) {
	home := newMinimalTestHome(t, 120, 32, "sync leads", false)
	frame := tmux.StripANSI(home.View())
	if !strings.Contains(frame, "not running") {
		t.Errorf("error panel missing %q", "not running")
	}
	restart, del := home.actionKey(hotkeyRestart), home.actionKey(hotkeyDelete)
	if want := restart + " restart · " + del + " delete"; !strings.Contains(frame, want) {
		t.Errorf("error panel missing key line %q", want)
	}
}

func TestMinimalUI_FilterSlot(t *testing.T) {
	home := newMinimalTestHome(t, 120, 32, "fix login flow", false)
	if got := home.renderFilterBarMinimalUI(); got != "" {
		t.Errorf("unfiltered filter slot = %q, want blank", got)
	}
	home.statusFilter = session.StatusWaiting
	got := tmux.StripANSI(home.renderFilterBarMinimalUI())
	if !strings.Contains(got, "showing: to review") || !strings.Contains(got, "0 clear") {
		t.Errorf("filtered slot = %q, want showing: to review ... 0 clear", got)
	}
}

// TestMinimalUI_ListStartMatchesRender guards the one layout-budget change
// (no panel titles): the first list row renders at the Y that mouse mapping
// and scroll math assume.
func TestMinimalUI_ListStartMatchesRender(t *testing.T) {
	for _, size := range [][2]int{{120, 32}, {80, 24}, {60, 30}, {45, 20}} {
		home := newMinimalTestHome(t, size[0], size[1], "fix login flow", false)
		lines := strings.Split(tmux.StripANSI(home.View()), "\n")
		startY := home.getListContentStartY()
		first := home.flatItems[0].Group.Name
		if startY >= len(lines) || !strings.Contains(lines[startY], first) {
			t.Errorf("%dx%d: line %d = %q, want the first group row", size[0], size[1], startY, lines[startY])
		}
		if got := home.mouseYToItemIndex(startY); got != 0 {
			t.Errorf("%dx%d: mouseYToItemIndex(%d) = %d, want 0", size[0], size[1], startY, got)
		}
	}
}

func TestMinimalUI_StyleConfig(t *testing.T) {
	for in, want := range map[string]string{"": "", "minimal": "minimal", " Minimal ": "minimal", "fancy": ""} {
		if got := (session.UISettings{Style: in}).GetStyle(); got != want {
			t.Errorf("GetStyle(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestMinimalUI_SelectedRowSpansWidth: the selection is a surface-colored bar
// across the whole row, not an arrow or an accent-filled title.
func TestMinimalUI_SelectedRowSpansWidth(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldProfile) })
	home := newMinimalTestHome(t, 120, 32, "review pricing page", false)
	const listWidth = 40
	var b strings.Builder
	item := home.flatItems[home.cursor]
	home.renderItem(&b, item, true, home.cursor, home.buildGroupRenderStats(home.getSessionRenderSnapshot()), home.getSessionRenderSnapshot(), listWidth)
	row := strings.TrimSuffix(b.String(), "\n")
	if w := lipgloss.Width(row); w != listWidth {
		t.Errorf("selected row is %d cells wide, want %d: %q", w, listWidth, row)
	}
	if !strings.Contains(row, "48;") {
		t.Errorf("selected row has no background color: %q", row)
	}
}

// TestMinimalUI_WorktreeIsOneBranchLine: the worktree section collapses to a
// single dim branch line, and no per-tool detail block renders.
func TestMinimalUI_WorktreeIsOneBranchLine(t *testing.T) {
	home := newMinimalTestHome(t, 120, 32, "review pricing page", false)
	sel := home.flatItems[home.cursor].Session
	sel.WorktreePath = "/tmp/wt/pricing"
	sel.WorktreeBranch = "feat/pricing"
	preview := tmux.StripANSI(home.renderPreviewPane(80, 28))
	if strings.Count(preview, "branch feat/pricing") != 1 {
		t.Errorf("preview should carry exactly one branch line:\n%s", preview)
	}
	for _, banned := range []string{"worktree", "Branch:", "Status:", "Model:", "claude\n"} {
		if strings.Contains(preview, banned) {
			t.Errorf("preview contains %q:\n%s", banned, preview)
		}
	}
}
