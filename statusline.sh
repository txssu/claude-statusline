#!/bin/sh
# Claude Code status line, two rows: git branch + sync (ahead/behind) + dirty
# flag, open MR and the session's average output tokens per second on top;
# subscription rate-limit usage below.
# The quotas render compactly - a single bar glyph - and only escalate to a
# percentage and a reset countdown when the reading warrants attention.
# Re-run periodically via the statusLine.refreshInterval setting so external
# branch/state changes show up even when the session is idle.

input=$(cat)
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')

# Outside a repo only the git-derived segments drop out; the quotas still render.
if [ -n "$dir" ] && git -C "$dir" --no-optional-locks rev-parse --git-dir >/dev/null 2>&1; then
    in_git=1
    branch=$(git -C "$dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
else
    in_git=""
fi

now=$(date +%s 2>/dev/null || echo 0)

m=$(printf '\033[1;38;5;213m')
g=$(printf '\033[1;38;5;84m')
y=$(printf '\033[1;38;5;221m')
rd=$(printf '\033[1;38;5;203m')
# Labels: light blue instead of dim (dim is unreadable on some themes).
dm=$(printf '\033[38;5;117m')
# Secondary detail (countdowns) and the segment separator sit back a step so
# the eye lands on labels and values first.
sc=$(printf '\033[38;5;245m')
sep=$(printf '\033[38;5;240m')
b=$(printf '\033[1;38;5;255m')
rs=$(printf '\033[0m')

# The status line is two rows: repo state and speed on top, quota usage below.
line1=""
line2=""

# Append a segment to one of the two rows, inserting the separator only
# between segments.
add() {
    case "$1" in
        1) [ -n "$line1" ] && line1="$line1 ${sep}·${rs} "
           line1="$line1$2" ;;
        2) [ -n "$line2" ] && line2="$line2 ${sep}·${rs} "
           line2="$line2$2" ;;
    esac
}

# Traffic-light colour for a usage percentage: green < 50, yellow < 80, red above.
pct_color() {
    case "$1" in
        ''|*[!0-9]*) printf '%s' "$b"; return ;;
    esac
    if [ "$1" -ge 80 ]; then
        printf '%s' "$rd"
    elif [ "$1" -ge 50 ]; then
        printf '%s' "$y"
    else
        printf '%s' "$g"
    fi
}

# Time left until a Unix timestamp, trimmed to the two most significant units.
fmt_left() {
    ts=${1%%.*}
    case "$ts" in
        ''|*[!0-9]*) return ;;
    esac
    left=$((ts - now))
    if [ "$left" -le 0 ]; then
        printf 'now'
    elif [ "$left" -ge 86400 ]; then
        printf '%dd%dh' $((left / 86400)) $((left % 86400 / 3600))
    elif [ "$left" -ge 3600 ]; then
        printf '%dh%dm' $((left / 3600)) $((left % 3600 / 60))
    else
        printf '%dm' $((left / 60))
    fi
}

# Above this share of a quota the bar glyph gives way to the exact number.
alarm_pct=70

# One glyph per eighth of the quota, so its height reads as the fraction used.
bar() {
    case $((($1 * 8 + 99) / 100)) in
        0|1) printf '\342\226\201' ;;
        2) printf '\342\226\202' ;;
        3) printf '\342\226\203' ;;
        4) printf '\342\226\204' ;;
        5) printf '\342\226\205' ;;
        6) printf '\342\226\206' ;;
        7) printf '\342\226\207' ;;
        *) printf '\342\226\210' ;;
    esac
}

# Context-window fill as a short bar. The three bands do not split the bar
# between them - each one repaints the whole of it in turn: green fills it by
# 25%, yellow then overwrites that green from the left and owns the bar by 50%,
# and red does the same to the yellow over the rest of the window. So past 25%
# the bar always reads full and only the colour boundary moves.
ctx_cells=12
ctxbar() {
    if [ "$1" -le 25 ]; then
        under=""; under_n=0
        over=$g;  over_n=$((($1 * ctx_cells + 12) / 25))
    elif [ "$1" -le 50 ]; then
        under=$g; under_n=$ctx_cells
        over=$y;  over_n=$(((($1 - 25) * ctx_cells + 12) / 25))
    else
        under=$y; under_n=$ctx_cells
        over=$rd; over_n=$(((($1 - 50) * ctx_cells + 25) / 50))
    fi
    [ "$over_n" -gt "$ctx_cells" ] && over_n=$ctx_cells

    i=0
    while [ "$i" -lt "$ctx_cells" ]; do
        if [ "$i" -lt "$over_n" ]; then
            printf '%s\342\226\210' "$over"
        elif [ "$i" -lt "$under_n" ]; then
            printf '%s\342\226\210' "$under"
        else
            printf '%s\342\226\221' "$sep"
        fi
        i=$((i + 1))
    done
    printf '%s' "$rs"
}

# Render one quota segment: label plus a reading that grows as the situation
# demands. Normally the percentage collapses to a bar glyph; past alarm_pct it
# spells itself out. The reset countdown joins in only when it changes what you
# would do - when the burn runs ahead of the window's even pace, or the window
# is in its final stretch.
#
#   $1 label   $2 percentage   $3 reset timestamp (Unix)
#   $4 window length in seconds
#   $5 slices the window is budgeted in (7 days for a week, 5 hours for 5h):
#      the whole slice's share counts as spent-on-pace from its first minute,
#      so day one tolerates 1/7 of the week rather than an hour-by-hour ration
#   $6 slices at the tail of the window during which the countdown always shows
#   $7 optional prefix for the value (marks a stale reading)
quota() {
    if [ -z "$2" ]; then
        add 2 "${dm}$1${rs} ${sc}$(printf '\342\226\221')${rs}"
        return
    fi
    pct=$(printf '%.0f' "$2" 2>/dev/null) || { add 2 "${dm}$1${rs} ${sc}$(printf '\342\226\221')${rs}"; return; }

    if [ "$pct" -ge "$alarm_pct" ]; then
        val="${pct}%"
    else
        val=$(bar "$pct")
    fi
    seg="${dm}$1${rs} $(pct_color "$pct")${7}${val}${rs}"

    reset=${3%%.*}
    case "$reset" in
        ''|*[!0-9]*) add 2 "$seg"; return ;;
    esac
    window=$4
    slices=$5
    rem=$((reset - now))
    [ "$rem" -lt 0 ] && rem=0
    elapsed=$((window - rem))
    [ "$elapsed" -lt 0 ] && elapsed=0
    # The slice we are in, counted from one: its full share is the allowance.
    unit=$((elapsed * slices / window + 1))
    [ "$unit" -gt "$slices" ] && unit=$slices
    if [ "$rem" -le $((window * $6 / slices)) ] || [ "$pct" -gt $((unit * 100 / slices)) ]; then
        seg="$seg ${sc}($(fmt_left "$reset"))${rs}"
    fi
    add 2 "$seg"
}

# Shared cache for readings too slow to take on every render (network calls).
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$cache_dir" 2>/dev/null

# True when a cache file is missing or older than the given TTL in seconds.
cache_stale() {
    [ -f "$1" ] || return 0
    mtime=$(stat -c %Y "$1" 2>/dev/null || echo 0)
    [ $((now - mtime)) -ge "$2" ]
}

if [ -n "$in_git" ]; then
    # Sync status against upstream
    si=$(git -C "$dir" --no-optional-locks rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
    if [ -n "$si" ]; then
        bh=$(echo "$si" | awk '{print $1}')
        ah=$(echo "$si" | awk '{print $2}')
        if [ "$bh" = 0 ] && [ "$ah" = 0 ]; then
            sync="${g}ok${rs}"
        elif [ "$bh" = 0 ]; then
            sync="${y}+${ah}${rs}"
        elif [ "$ah" = 0 ]; then
            sync="${y}-${bh}${rs}"
        else
            sync="${y}+${ah}-${bh}${rs}"
        fi
    else
        sync="${sc}local${rs}"
    fi

    # Dirty flag
    if [ -n "$(git -C "$dir" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        st=" ${y}*${rs}"
    else
        st=""
    fi

    add 1 "${m}${branch}${rs} ${sync}${st}"
else
    add 1 "${sc}local${rs}"
fi

# MR link (OSC 8 hyperlink) for the current branch, resolved via `glab`.
# The Claude Code status-line JSON has no PR/MR field for GitLab, so we query
# GitLab directly. The lookup is a network call, so results are cached per
# repo+branch and refreshed in the background to keep the prompt instant.
if [ -n "$in_git" ] && command -v glab >/dev/null 2>&1; then
    key=$(printf '%s\n%s' "$dir" "$branch" | md5sum 2>/dev/null | awk '{print $1}')
    cache_file="$cache_dir/mr-$key"

    if [ -n "$key" ] && cache_stale "$cache_file" 300; then
        # Mark fresh first so concurrent renders don't all spawn a refresh.
        touch "$cache_file" 2>/dev/null
        (
            found=$(cd "$dir" 2>/dev/null && glab mr list --source-branch "$branch" -F json 2>/dev/null \
                    | jq -r '.[] | select(.state=="opened") | "\(.iid)\t\(.web_url)"' | head -1)
            printf '%s' "$found" > "$cache_file"
        ) >/dev/null 2>&1 &
    fi

    if [ -s "$cache_file" ]; then
        pr_num=$(cut -f1 "$cache_file")
        pr_url=$(cut -f2 "$cache_file")
        if [ -n "$pr_num" ] && [ -n "$pr_url" ]; then
            osc8_open=$(printf '\033]8;;%s\033\\' "$pr_url")
            osc8_close=$(printf '\033]8;;\033\\')
            add 1 "${dm}MR${rs} ${g}${osc8_open}!${pr_num}${osc8_close}${rs}"
        fi
    fi
fi

# Claude.ai subscription rate-limit usage (5-hour session / 7-day weekly).
# `resets_at` arrives as a Unix timestamp and is shown as time remaining.
quota 5h \
    "$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')" \
    "$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')" \
    18000 5 1
quota 7d \
    "$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')" \
    "$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')" \
    604800 7 2

# Per-model weekly window (Fable). The status-line JSON projects only
# five_hour/seven_day, so the model-scoped limit comes from the same OAuth usage
# endpoint Claude Code itself queries, reusing its stored credentials. That is a
# network call, so the reading is cached and refreshed in the background to keep
# the prompt instant.
usage_cache="$cache_dir/usage"
creds="$HOME/.claude/.credentials.json"

if [ -r "$creds" ] && command -v curl >/dev/null 2>&1 && cache_stale "$usage_cache" 60; then
    # Mark fresh first so concurrent renders don't all spawn a refresh.
    touch "$usage_cache" 2>/dev/null
    (
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
        [ -z "$token" ] && exit 0

        # Headers go through a private file rather than the command line, so the
        # token never shows up in the process list.
        umask 077
        hdr=$(mktemp "${TMPDIR:-/tmp}/claude-statusline-hdr.XXXXXX") || exit 0
        printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\nUser-Agent: claude-code/2.1.0\n' \
            "$token" > "$hdr"
        body=$(curl -s --max-time 10 -H @"$hdr" \
                    https://api.anthropic.com/api/oauth/usage 2>/dev/null)
        rm -f "$hdr"

        row=$(printf '%s' "$body" | jq -r '
            [(.limits // [])[]
             | select(.kind == "weekly_scoped"
                      and ((.scope.model.display_name // "") | ascii_downcase) == "fable"
                      and (.percent | type) == "number")][0]
            | select(. != null)
            | "\(.percent)\t\(.resets_at // "")"' 2>/dev/null)
        [ -z "$row" ] && exit 0

        reset=$(printf '%s' "$row" | cut -f2)
        [ -n "$reset" ] && reset=$(date -d "$reset" +%s 2>/dev/null)
        # The fetch time is stored in the file rather than inferred from its
        # mtime, which the stampede-guard touch above rewrites even on failure.
        printf '%s\t%s\t%s' "$(printf '%s' "$row" | cut -f1)" "$reset" "$(date +%s)" \
            > "$hdr.out" && mv -f "$hdr.out" "$usage_cache"
    ) >/dev/null 2>&1 &
fi

fable=""
fable_reset=""
fable_mark=""
if [ -s "$usage_cache" ]; then
    fable=$(cut -f1 "$usage_cache")
    fable_reset=$(cut -f2 "$usage_cache")
    # A reading that outlived several refresh attempts means the endpoint has
    # been unreachable for a while; keep showing it, but flag it as stale.
    fetched=$(cut -f3 "$usage_cache")
    case "$fetched" in
        ''|*[!0-9]*) fable_mark="~" ;;
        *) [ $((now - fetched)) -ge 600 ] && fable_mark="~" ;;
    esac
fi
if [ -z "$fable" ]; then
    # No live reading yet (first render, or the endpoint is unreachable): fall
    # back to the cache Claude Code keeps in ~/.claude.json, which only refreshes
    # when Claude Code decides to. A `~` marks the value as possibly stale.
    row=$(jq -r '.cachedUsageUtilization.utilization.limits[]?
                 | select(.scope.model.display_name == "Fable")
                 | "\(.percent)\t\(.resets_at // "")"' \
              "$HOME/.claude.json" 2>/dev/null | head -1)
    fable=$(printf '%s' "$row" | cut -f1)
    fable_reset=$(printf '%s' "$row" | cut -f2)
    [ -n "$fable_reset" ] && fable_reset=$(date -d "$fable_reset" +%s 2>/dev/null)
    [ -n "$fable" ] && fable_mark="~"
fi
case "$fable" in
    ''|*[!0-9.]*) fable="" ;;
esac
quota Fable "$fable" "$fable_reset" 604800 7 2 "$fable_mark"

# How full the context window is, as the bar above. The percentage arrives
# null until the first API response; treated as 0 so the bar always renders.
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
ctx=$(printf '%.0f' "$ctx" 2>/dev/null) || ctx=0
case "$ctx" in
    *[!0-9]*) ctx=0 ;;
esac
[ "$ctx" -gt 100 ] && ctx=100
add 1 "${dm}ctx${rs} $(ctxbar "$ctx")"

# A missing row collapses instead of leaving a blank line behind.
if [ -n "$line1" ] && [ -n "$line2" ]; then
    printf '%s\n%s' "$line1" "$line2"
else
    printf '%s' "$line1$line2"
fi
