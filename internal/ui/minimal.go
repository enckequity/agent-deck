package ui

// Minimal home-screen style, selected by config.toml `[ui] style = "minimal"`.
//
// Everything here is reached through small `if minimalUI { ... }` hooks in the
// upstream renderers (home.go, styles.go), so the upstream look is untouched
// when the option is unset and the fork patch stays easy to rebase.
//
// Layout contract: minimal mode keeps the upstream line budget for the chrome
// (header 1, filter slot 1, footer 2) so the many duplicated height
// calculations in home.go stay correct. The only budget change is the panel
// title, which drops from 2 lines to 0; getVisibleHeight, the cursor-scroll
// height and getListContentStartY carry a hook for that.

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/asheshgoplani/agent-deck/internal/session"
)

// minimalUI is true when `[ui] style = "minimal"` is configured. Read by the
// render hooks; written only from the Bubble Tea goroutine (NewHome and the
// settings reload) and by tests.
var minimalUI bool

// minimalPanelTitleLines is the panel-title height in minimal mode (none).
const minimalPanelTitleLines = 0

// setMinimalUI switches the minimal style on or off and re-applies the palette
// when the value changes, so cached styles pick up the minimal colors.
func setMinimalUI(on bool) {
	if minimalUI == on {
		return
	}
	minimalUI = on
	InitTheme(string(GetCurrentTheme()))
}

// ─── Palette ────────────────────────────────────────────────────────────────

// applyMinimalPalette overrides the active colors with the quiet minimal
// palette. Called by InitTheme (theme lock held) before initStyles.
func applyMinimalPalette() {
	if currentTheme == ThemeLight {
		ColorText = lipgloss.Color("#27272a")
		ColorTextDim = lipgloss.Color("#8a8a93")
		ColorBorder = lipgloss.Color("#e4e4e7")
		ColorSurface = lipgloss.Color("#f1f1f3")
		ColorAccent = lipgloss.Color("#3b6fd8")
		ColorGreen = lipgloss.Color("#3f8f5f")
		ColorYellow = lipgloss.Color("#a87a1d")
		ColorRed = lipgloss.Color("#c24141")
	} else {
		ColorText = lipgloss.Color("#d4d4d8")
		ColorTextDim = lipgloss.Color("#71717a")
		ColorBorder = lipgloss.Color("#3f3f46")
		ColorSurface = lipgloss.Color("#27272a")
		ColorAccent = lipgloss.Color("#8ab4f8")
		ColorGreen = lipgloss.Color("#8fbc8f")
		ColorYellow = lipgloss.Color("#d7b56d")
		ColorRed = lipgloss.Color("#e07070")
	}
	// No rainbow: secondary hues collapse into the accent or dim text.
	ColorPurple = ColorAccent
	ColorCyan = ColorAccent
	ColorOrange = ColorYellow
	ColorComment = ColorTextDim
}

// applyMinimalStyles adjusts cached styles after initStyles. Called by
// InitTheme with the theme lock held.
func applyMinimalStyles() {
	dim := lipgloss.NewStyle().Foreground(ColorTextDim)
	for tool := range ToolStyleCache {
		ToolStyleCache[tool] = dim
	}
	DefaultToolStyle = dim
}

// ─── Shared helpers ─────────────────────────────────────────────────────────

func minimalDim() lipgloss.Style { return lipgloss.NewStyle().Foreground(ColorTextDim) }

// minimalStatusWord maps a session status to the plain word minimal mode uses.
// agent-deck's "waiting" means the agent finished its turn, so it reads as
// "to review".
func minimalStatusWord(status session.Status) string {
	switch status {
	case session.StatusRunning:
		return "working"
	case session.StatusWaiting:
		return "to review"
	case session.StatusError:
		return "error"
	case session.StatusStopped:
		return "stopped"
	case session.StatusStarting:
		return "starting"
	case session.StatusQueued:
		return "queued"
	}
	return "idle"
}

// minimalStatusDot returns the single status glyph and its color. The error
// substates (model unavailable, auth needed) and a stopped session that needs
// auth all collapse to a red dot.
func minimalStatusDot(status session.Status, substate session.Substate, archived bool) (string, lipgloss.Color) {
	if archived {
		return "◦", ColorTextDim
	}
	if status == session.StatusStopped && substate == session.SubstateAuth401 {
		return "•", ColorRed
	}
	switch status {
	case session.StatusRunning:
		return "•", ColorAccent
	case session.StatusWaiting:
		return "•", ColorYellow
	case session.StatusError:
		return "•", ColorRed
	case session.StatusStopped:
		return "◦", ColorTextDim
	}
	return "•", ColorTextDim
}

// minimalSegment is one styled run of a list row.
type minimalSegment struct {
	text  string
	color lipgloss.Color
	bold  bool
}

// renderMinimalRow joins segments into a row exactly width cells wide. When
// selected, every run (and the padding) carries the surface background so the
// highlight spans the whole row without ANSI resets punching holes in it.
// right is an optional right-aligned segment, dropped when it does not fit.
func renderMinimalRow(segments []minimalSegment, right *minimalSegment, width int, selected bool) string {
	style := func(seg minimalSegment) lipgloss.Style {
		s := lipgloss.NewStyle().Foreground(seg.color).Bold(seg.bold)
		if selected {
			s = s.Background(ColorSurface)
		}
		return s
	}
	used := 0
	for _, seg := range segments {
		used += cellWidth(seg.text)
	}
	rightWidth := 0
	if right != nil {
		rightWidth = cellWidth(right.text)
		if width > 0 && used+rightWidth+1 > width {
			right, rightWidth = nil, 0
		}
	}

	var b strings.Builder
	for _, seg := range segments {
		if seg.text != "" {
			b.WriteString(style(seg).Render(seg.text))
		}
	}
	if width > 0 {
		if pad := width - used - rightWidth; pad > 0 {
			b.WriteString(style(minimalSegment{color: ColorText}).Render(strings.Repeat(" ", pad)))
		}
	}
	if right != nil {
		b.WriteString(style(*right).Render(right.text))
	}
	return b.String()
}

// fitMinimalTitle truncates the title segment so the row fits width.
func fitMinimalTitle(title string, fixed, width int) string {
	if width <= 0 {
		return title
	}
	budget := max(0, width-fixed)
	if cellWidth(title) > budget {
		return cellTruncate(title, budget, "…")
	}
	return title
}

// minimalHomePath shortens $HOME to ~.
func minimalHomePath(path string) string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		if path == home {
			return "~"
		}
		if strings.HasPrefix(path, home+string(os.PathSeparator)) {
			return "~" + path[len(home):]
		}
	}
	return path
}

// ─── Chrome: header, filter slot, banners, errors, footer ───────────────────

// renderHeaderMinimalUI renders the one-line header: a dim wordmark on the
// left and a plain-words status summary on the right.
func (h *Home) renderHeaderMinimalUI() string {
	running, waiting, _, stopped, errored := h.countSessionStatuses()
	dim := minimalDim()
	sep := dim.Render(" · ")

	left := "agent deck"
	if h.profile != "" && h.profile != session.DefaultProfile {
		left += "  " + h.profile
	}
	if h.groupScope != "" {
		left += "  " + h.groupScopeDisplayName()
	}

	var parts, plain []string
	add := func(n int, word string, color lipgloss.Color) {
		if n <= 0 {
			return
		}
		text := fmt.Sprintf("%d %s", n, word)
		parts = append(parts, lipgloss.NewStyle().Foreground(color).Render(text))
		plain = append(plain, text)
	}
	add(running, "working", ColorTextDim)
	add(waiting, "to review", ColorTextDim)
	add(errored, "error", ColorRed)
	add(stopped, "stopped", ColorTextDim)
	right := strings.Join(parts, sep)
	rightWidth := cellWidth(strings.Join(plain, " · "))
	if len(parts) == 0 {
		right = dim.Render("no sessions")
		rightWidth = cellWidth("no sessions")
	}

	// One cell of margin on each side, matching the list rows.
	inner := h.width - 2
	if inner < 1 {
		return ""
	}
	if cellWidth(left)+2+rightWidth > inner {
		left = cellTruncate(left, max(0, inner-2-rightWidth), "…")
	}
	pad := inner - cellWidth(left) - rightWidth
	if pad < 1 {
		return " " + lipgloss.NewStyle().MaxWidth(inner).Render(right)
	}
	return " " + dim.Render(left) + strings.Repeat(" ", pad) + right
}

// renderFilterBarMinimalUI occupies the filter-bar slot: a blank line (the
// breathing room under the header) unless a non-default filter is active.
func (h *Home) renderFilterBarMinimalUI() string {
	var parts []string
	clearable := false
	if h.statusFilter != "" && string(h.statusFilter) != h.defaultFilter {
		clearable = true
		switch h.statusFilter {
		case FilterModeActive:
			label := h.activeFilterLabel
			if label == "" {
				label = "open"
			}
			parts = append(parts, strings.ToLower(label))
		case FilterModeArchived:
			parts = append(parts, "archived")
		default:
			parts = append(parts, minimalStatusWord(h.statusFilter))
		}
	}
	if h.timeFilter != session.TimeFilterAll {
		parts = append(parts, strings.ToLower(h.timeFilter.Label()))
	}
	if h.groupViewMode != session.GroupViewNormal {
		parts = append(parts, strings.ToLower(h.groupViewMode.Label()))
	}
	if len(parts) == 0 {
		return ""
	}
	line := " showing: " + strings.Join(parts, " · ")
	if clearable {
		line += "   0 clear"
	}
	return minimalDim().MaxWidth(max(1, h.width)).Render(line)
}

// minimalBannerStyle renders update/maintenance banners as one dim line.
func minimalBannerStyle(width int) lipgloss.Style {
	return lipgloss.NewStyle().Foreground(ColorTextDim).MaxWidth(max(1, width))
}

// renderErrorMinimalUI renders a transient error as a single muted-red line.
func renderErrorMinimalUI(err error, width int) string {
	msg := strings.ReplaceAll(err.Error(), "\n", " ")
	return lipgloss.NewStyle().Foreground(ColorRed).MaxWidth(max(1, width)).Render(" " + msg)
}

// renderHelpBarMinimalUI renders the footer: a blank spacer line and one dim
// line of the handful of keys that matter. It keeps the 2-line footer budget.
func (h *Home) renderHelpBarMinimalUI() string {
	type hint struct{ key, label string }
	var hints []hint
	if h.jumpMode {
		hints = []hint{{"a-z", "jump"}, {"esc", "cancel"}}
		if h.jumpBuffer != "" {
			hints = append([]hint{{h.jumpBuffer + "…", ""}}, hints...)
		}
	} else {
		hints = []hint{
			{h.actionKey(hotkeyNewSession), "new"},
			{"↵", "open"},
			{h.actionKey(hotkeySearch), "search"},
			{h.actionKey(hotkeyHelp), "help"},
			{h.actionKey(hotkeyQuit), "quit"},
		}
	}
	parts := make([]string, 0, len(hints))
	for _, hn := range hints {
		if strings.TrimSpace(hn.key) == "" {
			continue
		}
		parts = append(parts, strings.TrimSpace(hn.key+" "+hn.label))
	}
	line := " " + strings.Join(parts, "   ")
	if cellWidth(line) > h.width {
		line = cellTruncate(line, max(0, h.width), "")
	}
	return "\n" + minimalDim().Render(line)
}

// ─── Layouts (no panel titles) ──────────────────────────────────────────────

// renderDualColumnLayoutMinimalUI is renderDualColumnLayout without the
// SESSIONS/PREVIEW titles, with a faint column rule.
func (h *Home) renderDualColumnLayoutMinimalUI(contentHeight int) string {
	leftWidth, rightWidth := h.splitPaneWidths()

	leftPanel := ensureExactHeight(h.renderSessionList(leftWidth, contentHeight), contentHeight)
	rightPanel := ensureExactHeight(h.renderPreviewPane(rightWidth, contentHeight), contentHeight)

	separatorColor := ColorBorder
	if h.draggingDivider {
		separatorColor = ColorAccent
	}
	separatorCell := lipgloss.NewStyle().Foreground(separatorColor).Render(" │ ")
	separatorLines := make([]string, max(0, contentHeight))
	for i := range separatorLines {
		separatorLines[i] = separatorCell
	}
	separator := strings.Join(separatorLines, "\n")

	leftPanel = ensureExactWidth(leftPanel, leftWidth)
	rightPanel = ensureExactWidth(rightPanel, rightWidth)

	mainContent := lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, separator, rightPanel)
	if lipgloss.Width(mainContent) > h.width {
		mainContent = lipgloss.NewStyle().MaxWidth(h.width).Render(mainContent)
	}
	return mainContent
}

// renderStackedLayoutMinimalUI is renderStackedLayout without panel titles; a
// blank line separates the list from the preview.
func (h *Home) renderStackedLayoutMinimalUI(totalHeight int) string {
	listHeight := h.stackedListHeight(totalHeight)
	previewHeight := totalHeight - listHeight - 1
	if previewHeight < 3 {
		previewHeight = 3
	}
	list := ensureExactHeight(h.renderSessionList(h.width, listHeight), listHeight)
	preview := ensureExactHeight(h.renderPreviewPane(h.width, previewHeight), previewHeight)
	return list + "\n\n" + preview
}

// renderSingleColumnLayoutMinimalUI is renderSingleColumnLayout without the title.
func (h *Home) renderSingleColumnLayoutMinimalUI(totalHeight int) string {
	return ensureExactHeight(h.renderSessionList(h.width, totalHeight), totalHeight)
}

// ─── List rows ──────────────────────────────────────────────────────────────

// renderItemMinimalUI renders group and session rows in the minimal style and
// reports whether it handled the item; other row kinds (creating placeholders,
// windows, remotes, dividers) fall through to the upstream renderers.
func (h *Home) renderItemMinimalUI(
	b *strings.Builder,
	item session.Item,
	selected bool,
	groupStats map[string]groupRenderStats,
	snapshot map[string]sessionRenderState,
	listWidth int,
) bool {
	switch {
	case item.Type == session.ItemTypeGroup && item.Group != nil:
		h.renderGroupItemMinimalUI(b, item, selected, groupStats, listWidth)
		return true
	case item.Type == session.ItemTypeSession && item.CreatingID == "" && item.Session != nil:
		h.renderSessionItemMinimalUI(b, item, selected, snapshot, listWidth)
		return true
	}
	return false
}

// renderSessionListEmptyMinimalUI is the empty session list: calm text, no
// icon and no border.
func (h *Home) renderSessionListEmptyMinimalUI(width, height int) string {
	if h.groupScope != "" {
		var hints []string
		if key := h.actionKey(hotkeyNewSession); key != "" {
			hints = append(hints, key+" new session")
		}
		return renderEmptyStateMinimalUI(EmptyStateConfig{
			Title:    "nothing in " + h.groupScopeDisplayName(),
			Subtitle: "this group is empty",
			Hints:    hints,
		}, width, height)
	}
	var hints []string
	if key := h.actionKey(hotkeyNewSession); key != "" {
		hints = append(hints, key+" new session")
	}
	if key := h.actionKey(hotkeyImport); key != "" {
		hints = append(hints, key+" import tmux sessions")
	}
	if key := h.actionKey(hotkeyCreateGroup); key != "" {
		hints = append(hints, key+" new group")
	}
	return renderEmptyStateMinimalUI(EmptyStateConfig{
		Title:    "no sessions yet",
		Subtitle: "create or import one to get started",
		Hints:    hints,
	}, width, height)
}

// renderGroupItemMinimalUI renders a group header: a dim `›` only when
// collapsed, the dim name as typed, and a dim session count.
func (h *Home) renderGroupItemMinimalUI(
	b *strings.Builder,
	item session.Item,
	selected bool,
	groupStats map[string]groupRenderStats,
	listWidth int,
) {
	group := item.Group
	chevron := "  "
	if !group.Expanded {
		chevron = "› "
	}
	nameColor := ColorTextDim
	if selected {
		nameColor = ColorText
	}
	count := fmt.Sprintf(" %d", groupStats[group.Path].sessionCount)
	prefix := " " + strings.Repeat("  ", max(0, item.Level)) + chevron
	name := fitMinimalTitle(group.Name, cellWidth(prefix)+cellWidth(count)+1, listWidth)

	b.WriteString(renderMinimalRow([]minimalSegment{
		{text: prefix, color: ColorTextDim},
		{text: name, color: nameColor},
		{text: count, color: ColorTextDim},
	}, nil, listWidth, selected))
	b.WriteString("\n")
}

// renderSessionItemMinimalUI renders a session row: indentation by level, one
// colored status dot, the title, and only the location hints that change what
// the session is (ssh host, multi-repo). Reads labels from the render snapshot
// so the row stays lock-free (#1753).
func (h *Home) renderSessionItemMinimalUI(
	b *strings.Builder,
	item session.Item,
	selected bool,
	snapshot map[string]sessionRenderState,
	listWidth int,
) {
	inst := item.Session
	state, ok := snapshot[inst.ID]
	if !ok {
		state = h.getSessionRenderState(inst)
	}

	dot, dotColor := minimalStatusDot(state.status, state.substate, inst.IsArchived())
	titleColor := ColorText
	if !selected && (state.status == session.StatusStopped || inst.IsArchived()) {
		titleColor = ColorTextDim
	}

	var extras []string
	if inst.IsSSH() && inst.SSHHost != "" {
		extras = append(extras, inst.SSHHost)
	}
	if inst.IsMultiRepo() {
		extras = append(extras, fmt.Sprintf("multi-repo: %d", len(inst.AllProjectPaths())))
	}
	extra := ""
	if len(extras) > 0 {
		extra = "  " + strings.Join(extras, " · ")
	}

	var right *minimalSegment
	if h.showSessionTimestamps {
		var hookStatus *session.HookStatus
		if h.hookWatcher != nil {
			hookStatus = h.hookWatcher.GetHookStatus(inst.ID)
		}
		confirmedTs, confirmedObserved := inst.LastObservedActivity()
		ts := sessionActivityTime(inst.CreatedAt, inst.LastStartedAt, inst.LastActivityAt(), inst.LastAccessedAt, confirmedTs, confirmedObserved, hookStatus)
		right = &minimalSegment{text: formatRelativeTime(ts) + " ", color: ColorTextDim}
	}

	prefix := " " + strings.Repeat("  ", max(0, item.Level))
	title, _ := sessionDisplayLabelsFromState(state)
	fixed := cellWidth(prefix) + 2 + cellWidth(extra) + 1
	title = fitMinimalTitle(title, fixed, listWidth)

	b.WriteString(renderMinimalRow([]minimalSegment{
		{text: prefix, color: ColorTextDim},
		{text: dot, color: dotColor},
		{text: " ", color: ColorText},
		{text: title, color: titleColor},
		{text: extra, color: ColorTextDim},
	}, right, listWidth, selected))
	b.WriteString("\n")
}

// ─── Preview pane ───────────────────────────────────────────────────────────

// renderPreviewHeaderMinimalUI replaces the preview header (title, status
// badge, path, activity, tool/group chips) with a title, one dim meta line
// and a dim path.
func (h *Home) renderPreviewHeaderMinimalUI(selected *session.Instance, status session.Status, activity string, width int) string {
	var b strings.Builder
	lineWidth := max(1, width-2)

	title := cellTruncate(selected.Title, lineWidth, "…")
	b.WriteString(lipgloss.NewStyle().Foreground(ColorText).Bold(true).Render(title))
	b.WriteString("\n")

	meta := []string{minimalStatusWord(status)}
	if selected.Tool != "" {
		meta = append(meta, selected.Tool)
	}
	if selected.GroupPath != "" {
		meta = append(meta, selected.GroupPath)
	}
	if status != session.StatusRunning && activity != "" && activity != "unknown" {
		meta = append(meta, activity)
	}
	b.WriteString(minimalDim().Render(cellTruncate(strings.Join(meta, " · "), lineWidth, "…")))
	b.WriteString("\n")

	if selected.AuthHeldCached() {
		b.WriteString(authHoldBannerLines(width))
	}

	b.WriteString(minimalDim().Render(truncatePath(minimalHomePath(selected.ProjectPath), lineWidth)))
	b.WriteString("\n")
	return b.String()
}

// renderSectionDividerMinimalUI replaces `─── Label ───` with a blank line and
// a dim lowercase label.
func renderSectionDividerMinimalUI(label string) string {
	if label == "" {
		return ""
	}
	return "\n" + minimalDim().Render(strings.ToLower(label))
}

// renderNotRunningMinimalUI replaces the stopped and error panels with two
// lines: what happened, and the keys that fix it.
func (h *Home) renderNotRunningMinimalUI(b *strings.Builder, status session.Status, height int) string {
	if status == session.StatusStopped {
		b.WriteString(minimalDim().Render("stopped"))
	} else {
		b.WriteString(lipgloss.NewStyle().Foreground(ColorRed).Render("not running"))
	}
	b.WriteString("\n")

	var keys []string
	if key := h.actionKey(hotkeyRestart); key != "" {
		keys = append(keys, key+" restart")
	}
	if key := h.actionKey(hotkeyDelete); key != "" {
		keys = append(keys, key+" delete")
	}
	if len(keys) > 0 {
		b.WriteString(minimalDim().Render(strings.Join(keys, " · ")))
	}
	return ensureExactHeight(b.String(), height)
}

// renderGroupPreviewMinimalUI renders the group preview: name, a dim summary,
// and the sessions with the same dots as the list.
func (h *Home) renderGroupPreviewMinimalUI(group *session.Group, width, height int) string {
	var b strings.Builder
	lineWidth := max(1, width-2)
	dim := minimalDim()

	b.WriteString(lipgloss.NewStyle().Foreground(ColorText).Bold(true).Render(cellTruncate(group.Name, lineWidth, "…")))
	b.WriteString("\n")

	counts := map[session.Status]int{}
	for _, sess := range group.Sessions {
		counts[sess.Status]++
	}
	noun := "sessions"
	if len(group.Sessions) == 1 {
		noun = "session"
	}
	summary := []string{fmt.Sprintf("%d %s", len(group.Sessions), noun)}
	for _, st := range []session.Status{session.StatusRunning, session.StatusWaiting, session.StatusError, session.StatusStopped} {
		if counts[st] > 0 {
			summary = append(summary, fmt.Sprintf("%d %s", counts[st], minimalStatusWord(st)))
		}
	}
	b.WriteString(dim.Render(cellTruncate(strings.Join(summary, " · "), lineWidth, "…")))
	b.WriteString("\n\n")

	if repoInfo := h.getGroupWorktreeInfo(group); repoInfo != nil {
		b.WriteString(dim.Render(truncatePath(minimalHomePath(repoInfo.repoRoot), lineWidth)))
		b.WriteString("\n")
		for _, br := range repoInfo.branches {
			line := br.branch
			if br.dirtyChecked && br.isDirty {
				line += " · dirty"
			}
			b.WriteString(dim.Render(cellTruncate(line, lineWidth, "…")))
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}

	maxShow := max(3, height-8)
	for i, sess := range group.Sessions {
		if i >= maxShow {
			b.WriteString(dim.Render(fmt.Sprintf("+%d more", len(group.Sessions)-i)))
			b.WriteString("\n")
			break
		}
		dot, color := minimalStatusDot(sess.Status, "", false)
		b.WriteString(lipgloss.NewStyle().Foreground(color).Render(dot))
		b.WriteString(" ")
		b.WriteString(lipgloss.NewStyle().Foreground(ColorText).Render(cellTruncate(sess.Title, max(1, lineWidth-2), "…")))
		b.WriteString("\n")
	}

	var hints []string
	if key := h.actionKey(hotkeyRename); key != "" {
		hints = append(hints, key+" rename")
	}
	if key := h.actionKey(hotkeyDelete); key != "" {
		hints = append(hints, key+" delete")
	}
	if len(hints) > 0 {
		b.WriteString("\n")
		b.WriteString(dim.Render(cellTruncate(strings.Join(hints, " · "), lineWidth, "…")))
	}
	return b.String()
}

// renderEmptyStateMinimalUI renders an empty state as calm text: no icon, no
// border, no bullets.
func renderEmptyStateMinimalUI(config EmptyStateConfig, width, height int) string {
	lineWidth := max(1, width-2)
	fit := func(s string) string { return cellTruncate(s, lineWidth, "…") }
	dim := minimalDim()

	var lines []string
	lines = append(lines, "", " "+lipgloss.NewStyle().Foreground(ColorText).Render(fit(config.Title)))
	if config.Subtitle != "" {
		lines = append(lines, " "+dim.Render(fit(config.Subtitle)))
	}
	if len(config.Hints) > 0 {
		lines = append(lines, "")
		for _, hint := range config.Hints {
			lines = append(lines, " "+dim.Render(fit(hint)))
		}
	}
	return ensureExactHeight(strings.Join(lines, "\n"), height)
}
