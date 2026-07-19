#!/usr/bin/env bash
# Bring up an EPHEMERAL self-hosted GitHub Actions runner for the `wake` embed
# spine on any fresh 2-core Linux box (Oracle Always Free, Azure for Students,
# GCP e2, a Codespace, or home hardware). It spins up -> runs one job -> tears
# down (and optionally powers the box off), which is the "scale to zero, free,
# no rate limits" shape.
#
# Usage (on the box):
#   export REPO=Synodic-AI/wake
#   export REG_TOKEN=$(gh api repos/$REPO/actions/runners/registration-token -q .token)
#   export DOPPLER_SERVICE_TOKEN=dp.st.dev.xxxxx      # box-local Doppler auth
#   ./scripts/runner-bootstrap.sh --shutdown-after     # omit flag to keep box up
#
set -euo pipefail

REPO="${REPO:?set REPO=owner/name (e.g. Synodic-AI/wake)}"
REG_TOKEN="${REG_TOKEN:?set REG_TOKEN (repo Actions runner registration token)}"
LABELS="${LABELS:-embed}"
NAME="${RUNNER_NAME:-wake-$(hostname)-$$}"
WORKDIR="${RUNNER_WORKDIR:-$HOME/wake-runner}"
RUNNER_VER="${RUNNER_VER:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null || echo 2.335.1)}"   # latest; pinned versions get deprecated and go deaf
SHUTDOWN_AFTER=0
[ "${1:-}" = "--shutdown-after" ] && SHUTDOWN_AFTER=1

# 1) Doppler CLI + box-local auth. With this, secrets never transit GitHub at all,
#    so there is no repo secret to leak and nothing touches your PAT rate limit.
command -v doppler >/dev/null 2>&1 || (curl -Ls --tlsv1.2 --proto "=https" https://cli.doppler.com/install.sh | sh)
if [ -n "${DOPPLER_SERVICE_TOKEN:-}" ]; then
  doppler configure set token "$DOPPLER_SERVICE_TOKEN" --scope "$WORKDIR" >/dev/null
fi

# 2) Local embed-model deps, cached on the box's storage (offline after first pull).
if [ -f embed/requirements.txt ]; then
  python3 -m venv "$WORKDIR/venv" 2>/dev/null || true
  # shellcheck disable=SC1091
  . "$WORKDIR/venv/bin/activate" && pip install -q -r embed/requirements.txt || true
  deactivate 2>/dev/null || true
fi

# 3) Download + register the Actions runner. --ephemeral => fresh per job.
mkdir -p "$WORKDIR" && cd "$WORKDIR"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) RARCH=x64 ;;
  aarch64 | arm64) RARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac
TARBALL="actions-runner-linux-${RARCH}-${RUNNER_VER}.tar.gz"
if [ ! -x ./run.sh ]; then
  curl -fsSL -o "$TARBALL" "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/${TARBALL}"
  tar xzf "$TARBALL"
fi
./config.sh --unattended --replace --ephemeral \
  --url "https://github.com/${REPO}" --token "$REG_TOKEN" \
  --name "$NAME" --labels "$LABELS" --work _work

# 4) Run exactly one job, deregister, then optionally power off (= timed shutdown).
cleanup() { ./config.sh remove --token "$REG_TOKEN" >/dev/null 2>&1 || true; }
trap cleanup EXIT
./run.sh || true
if [ "$SHUTDOWN_AFTER" = "1" ]; then
  echo "[bootstrap] job complete; powering down box"
  sudo shutdown -h now || true
fi
