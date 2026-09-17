# claude-statusline

A two-row status line for [Claude Code](https://claude.com/claude-code). Top row: git branch, sync with upstream, dirty flag, the open GitLab MR and a context-window bar. Bottom row: subscription quotas — 5h, 7d and the weekly Fable limit.

```
main ok * · MR !42 · ctx ████████░░░░
5h ▃ · 7d 74% (2d3h) · Fable ▂
```

A quota is a single bar glyph until it needs attention: past 70% it turns into a number, and the reset countdown appears when usage runs ahead of the window's even pace.

## Install

Linux with `jq`, `git` and `curl`. With `glab` installed and logged in, the MR segment appears.

```sh
git clone https://github.com/txssu/claude-statusline.git
claude-statusline/install.sh
```

The installer symlinks `statusline.sh` to `~/.claude/statusline-command.sh` and sets `statusLine` in `~/.claude/settings.json`. A status line already at that path is moved to `statusline-command.sh.bak.<timestamp>`. Updating is `git pull`; the checkout has to stay where it was installed from.

## What it touches

The Fable quota is not in the status-line JSON, so the script reads the OAuth token from `~/.claude/.credentials.json` and queries `api.anthropic.com/api/oauth/usage` at most once a minute, in the background. A reading older than ten minutes is prefixed with `~`.

Cached readings live in `${XDG_CACHE_HOME:-~/.cache}/claude-statusline`.

## License

MIT
