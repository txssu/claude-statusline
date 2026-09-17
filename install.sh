#!/bin/sh
# Point Claude Code at the statusline.sh of this checkout: symlink it into
# ~/.claude and register it in settings.json. Safe to re-run.
set -eu

repo=$(cd "$(dirname "$0")" && pwd)
claude_dir="$HOME/.claude"
target="$claude_dir/statusline-command.sh"
settings="$claude_dir/settings.json"

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

mkdir -p "$claude_dir"

# A regular file here is someone's previous status line; keep it.
if [ -e "$target" ] && [ ! -L "$target" ]; then
    backup="$target.bak.$(date +%s)"
    mv "$target" "$backup"
    echo "backed up $target -> $backup"
fi
ln -sfn "$repo/statusline.sh" "$target"
echo "linked $target -> $repo/statusline.sh"

[ -s "$settings" ] || echo '{}' > "$settings"
tmp=$(mktemp "$settings.XXXXXX")
jq --arg cmd "sh $target" \
   '.statusLine = {type: "command", command: $cmd, refreshInterval: 2}' \
   "$settings" > "$tmp"
mv "$tmp" "$settings"
echo "registered statusLine in $settings"
