#!/usr/bin/env bash
# Entry point for the embed job. Secrets are already in the environment (injected
# by `doppler run`). This script makes ZERO GitHub API calls, so nothing here can
# be rate-limited — the only limits that could apply live inside serve.py's model
# resolver (a hosted endpoint). A local model = fully unthrottled.
set -euo pipefail

INPUT_GLOB="${1:-data/**/*.txt}"
MODEL="${EMBED_MODEL:-pplx-embed-context-V1-.06}"
OUT="${EMBED_OUT:-out/embeddings.parquet}"

# Prefer the runner's venv python if the bootstrap created one.
if [ -x "${RUNNER_WORKDIR:-$HOME/wake-runner}/venv/bin/python" ]; then
  PY="${RUNNER_WORKDIR:-$HOME/wake-runner}/venv/bin/python"
else
  PY="${PYTHON:-python3}"
fi

mkdir -p "$(dirname "$OUT")"
exec "$PY" embed/serve.py --input "$INPUT_GLOB" --model "$MODEL" --out "$OUT"
