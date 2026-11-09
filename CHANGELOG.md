# Changelog

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
