#!/bin/sh
# GhosttyBar external source: Claude Code sessions running in tmux, on this Mac or on another machine.
#
#   tmux-source.sh                  # local tmux server
#   tmux-source.sh user@host        # tmux on another machine, over ssh
#   tmux-source.sh --all [user@host]  # also list panes that don't run Claude Code (as "plain")
#   tmux-source.sh -L name [user@host] # a tmux server started with `tmux -L name`
#
# Prints GhosttyBar's source JSON on stdout and always exits 0 with valid JSON; problems go into "error".
# State comes from the pane title, which Claude Code sets: ◐ ◑ ◒ ◓ or a braille spinner = busy,
# ✳ ✻ ✽ ✶ ✢ = idle. A window whose bell flag is set (tmux: monitor-bell) counts as "waiting".
#
# Remote: needs key-based ssh login (BatchMode, no password prompts). The first run opens a shared
# ssh connection (ControlMaster) that stays up for 10 minutes, so polling every few seconds reuses it
# instead of doing a new ssh handshake each time.
#
# No dependencies beyond sh, awk, tmux (and ssh for remote).

all=0
host=""
socket=""
while [ $# -gt 0 ]; do
    case "$1" in
        --all) all=1 ;;
        -L) shift; socket="$1" ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) host="$1" ;;
    esac
    shift
done

json_error() {
    # $1: message (quotes and backslashes escaped, control characters dropped)
    msg=$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-200)
    printf '{"items": [], "error": "%s"}\n' "$msg"
    exit 0
}

# One line per pane. Printable separator: tmux escapes control characters in its output. The title is
# the last field, so a title that contains the separator still comes through whole.
SEP='@#@'
FMT="#{pane_id}${SEP}#{session_name}${SEP}#{window_index}${SEP}#{pane_index}${SEP}#{window_bell_flag}${SEP}#{pane_current_path}${SEP}#{pane_title}"
# Non-interactive shells (launchd, ssh commands) often lack Homebrew in PATH.
case "$socket" in *[!A-Za-z0-9_.-]*) json_error "invalid -L socket name" ;; esac
TMUX_CMD="PATH=\"\$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux ${socket:+-L $socket }list-panes -a -F '$FMT'"

if [ -n "$host" ]; then
    mkdir -p "$HOME/.ssh" 2>/dev/null
    out=$(ssh -T -o BatchMode=yes -o ConnectTimeout=3 \
              -o ControlMaster=auto -o ControlPersist=10m -o "ControlPath=$HOME/.ssh/ghosttybar-%C" \
              -o ServerAliveInterval=5 -o ServerAliveCountMax=1 \
              "$host" "$TMUX_CMD" 2>&1 </dev/null)
    status=$?
else
    out=$(sh -c "$TMUX_CMD" 2>&1 </dev/null)
    status=$?
fi

if [ "$status" -ne 0 ]; then
    case "$out" in
        *"no server running"*|*"error connecting to"*|*"No such file or directory"*"tmux-"*)
            printf '{"items": [], "error": null}\n'; exit 0 ;;   # tmux not started: nothing to show
    esac
    if [ "$status" -eq 255 ] && [ -n "$host" ]; then json_error "ssh: $(printf '%s' "$out" | tail -n 1)"; fi
    json_error "$(printf '%s' "$out" | tail -n 1)"
fi

# Byte-wise in the C locale, so the glyph checks don't depend on the user's locale.
printf '%s\n' "$out" | LC_ALL=C awk -v FS="$SEP" -v all="$all" '
function esc(s,    r) {
    gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, "", s)
    return s
}
function base(p,    n, a) { n = split(p, a, "/"); return (n > 0 && a[n] != "") ? a[n] : p }
BEGIN { n = 0; printf "{\"items\": [" }
NF >= 7 {
    id = $1; sess = $2; win = $3; pane = $4; bell = $5; path = $6
    title = $7; for (i = 8; i <= NF; i++) title = title FS $i
    state = ""
    g = substr(title, 1, 3)
    # ◐ ◑ ◒ ◓ (U+25D0-25D3) and braille spinners (U+2800-28FF: E2 A0-A3 xx) = busy
    if (g == "\342\227\220" || g == "\342\227\221" || g == "\342\227\222" || g == "\342\227\223" ||
        (substr(title, 1, 1) == "\342" && index("\240\241\242\243", substr(title, 2, 1)) > 0)) state = "busy"
    # ✳ ✻ ✽ ✶ ✢ = idle
    else if (g == "\342\234\263" || g == "\342\234\273" || g == "\342\234\275" || g == "\342\234\266" ||
             g == "\342\234\242") state = "idle"
    if (state != "") {
        title = substr(title, 4)
        if (substr(title, 1, 3) == "\357\270\217") title = substr(title, 4)   # variation selector
        sub(/^[ \t]+/, "", title)
        if (title == "") title = "Claude"
        if (state == "idle" && bell == "1") state = "waiting"
    } else if (all == "1") {
        state = "plain"
        if (title == "") title = sess ":" win "." pane
    } else next
    sub(/[ \t]+$/, "", title)
    subt = sess ":" win "." pane " · " base(path)
    printf "%s{\"id\": \"%s\", \"title\": \"%s\", \"state\": \"%s\", \"subtitle\": \"%s\"}",
        (n++ ? ", " : ""), esc(id), esc(title), state, esc(subt)
}
END { printf "], \"error\": null}\n" }
'
