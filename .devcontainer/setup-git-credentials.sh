#!/usr/bin/env bash
# Give the container a persistent GitHub credential.
#
# VS Code installs a credential helper that shells out to a PER-SESSION script in
# /tmp and proxies back to the host over the REMOTE_CONTAINERS_IPC socket. It
# works for anything launched from an integrated terminal, but any process whose
# environment lacks that variable (a background refresh, a re-exec'd subprocess,
# `docker exec`) gets a 401/authentication failure instead.
#
# So configure a `store` helper as a FALLBACK, using the token already in .env.
# `gh auth login --with-token` + `gh auth setup-git` is the other option if you'd
# rather drive git credentials through the gh CLI instead of a raw token file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Parse a key out of .env without sourcing it: tokens contain characters a shell
# would interpret. Strips \r so a CRLF .env cannot corrupt the value.
read_env_file() {
	local key="$1"
	[ -f "$ENV_FILE" ] || return 1
	grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | head -1 | sed -E "s/^[[:space:]]*${key}=//" | tr -d '\r'
}

# Environment first, treating empty as unset, then the file: a host variable
# that resolves to empty would otherwise shadow a perfectly good .env value.
resolve() {
	local key="$1" val
	val="${!key:-}"
	[ -n "$val" ] || val="$(read_env_file "$key" || true)"
	printf '%s' "${val//$'\r'/}"
}

TOKEN="$(resolve GITHUB_TOKEN)"

if [ -z "$TOKEN" ]; then
	echo "NOTE: no GITHUB_TOKEN set - git will rely on the VS Code session" >&2
	echo "      credential helper alone, which is unavailable to background" >&2
	echo "      processes (Claude Code plugin refresh, docker exec)." >&2
	exit 0
fi

# ~/.config/git/config, NOT ~/.gitconfig: VS Code runs
# `git config --global --replace-all credential.helper ...` on every connect,
# which would silently drop this. Git reads the XDG path too and VS Code never
# touches it, so the fallback survives reconnects. It sits *after* VS Code's
# helper in git's lookup order, so the session helper still wins when it works.
mkdir -p "$HOME/.config/git"
git config --file "$HOME/.config/git/config" --replace-all credential.helper store

# Truncate rather than append so re-running cannot accumulate stale tokens.
# GitHub accepts the PAT as the username with no password over HTTPS.
printf 'https://%s@github.com\n' "$TOKEN" >"$HOME/.git-credentials"
chmod 600 "$HOME/.git-credentials"

echo "Configured a persistent github.com credential (fallback beneath VS Code's helper)."
