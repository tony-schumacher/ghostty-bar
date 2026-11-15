# Changelog

## 0.3.0

- Agent activity: a dim second line under a Claude Code tab shows background subagents and dynamic
  workflows running in that session (`⚙ review-pr · Verify · 3 running`, `⚙ 2 agents`), in the window
  and in the menu. Read-only from Claude Code's local session files (`~/.claude` or `$CLAUDE_CONFIG_DIR`),
  found through the pid of each tab's foreground process; nothing shows when the files are missing.
- A renamed Claude Code tab (title without a status glyph) takes working/idle from its session file, so
  it gets the normal status and unread tracking. A title glyph still wins.
- `--dump-agents` prints every tab with its Claude Code session and agent activity as JSON.
- Demo mode shows a sample workflow and two background agents.
- Setting "Group by window" (default on): turn off to list all Ghostty tabs without "Window N" headers.
- The `‹` marker and bold title now mark only the tab you are actually in (selected tab of Ghostty's front window), not the selected tab of every window.

## 0.2.0

- External sources: list agent sessions from tmux, other machines or bots next to the Ghostty tabs.
  Configure commands in `~/.config/ghosttybar/sources.json`; each prints a small JSON list of items
  (`busy`, `idle`, `waiting`, `plain`). Each source is its own group with unread tracking, filter,
  ⌃⌥J, notifications and the menu bar count. A failing source shows as offline with its last items dimmed.
- `examples/tmux-source.sh`: Claude Code sessions in tmux, local or over ssh (shared connection, no
  dependencies).
- Demo mode shows a sample external source.

## 0.1.0

First public release.

- Menu bar list of all Ghostty tabs across windows, grouped by window; click to jump to a tab.
- Claude Code status from the tab title: working, unread (finished or rang the bell while you
  weren't looking), read, plain shell.
- Optional floating window with an All | Unread filter, adjustable transparency and blur,
  always-on-top.
- Global hotkey ⌃⌥J for the next unread tab (can be turned off).
- Optional macOS notification when a tab finishes.
- Launch at Login.
- `--demo` mode with sample tabs, no Ghostty needed.
- Universal binary (Apple silicon + Intel), macOS 14+.
