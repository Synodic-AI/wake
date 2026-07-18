#!/usr/bin/env bash
# Paste this into the claude.ai/code environment "Setup script" field so cloud
# sessions get the Doppler CLI. Secrets themselves are hydrated per session by the
# SessionStart hook in .claude/settings.json (kept out of the cached image).
set -euo pipefail
command -v doppler >/dev/null 2>&1 || (curl -Ls --tlsv1.2 --proto "=https" https://cli.doppler.com/install.sh | sh)
