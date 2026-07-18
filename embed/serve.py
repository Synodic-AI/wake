#!/usr/bin/env python3
"""Local-first embedding runner for the `wake` self-hosted spine.

--model is resolved in this order (first match wins):
  1. A local directory / file path  -> loaded fully offline. No rate limit.
  2. $EMBED_ENDPOINT is set          -> POST to that OpenAI-compatible /embeddings
                                        endpoint with $EMBED_API_KEY. This path IS
                                        subject to that provider's rate limit.
  3. Otherwise                       -> treated as a Hugging Face model id, loaded
                                        with sentence-transformers and cached to the
                                        runner's storage (offline after first pull).

Writes {path, embedding, model} rows to a parquet (falls back to jsonl).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path


def log(*a):
    print("[embed]", *a, file=sys.stderr, flush=True)


def read_texts(pattern: str):
    files = sorted(glob.glob(pattern, recursive=True))
    if not files:
        log(f"no files matched: {pattern!r}")
    for fp in files:
        if Path(fp).is_file():
            try:
                yield fp, Path(fp).read_text(encoding="utf-8", errors="replace")
            except Exception as e:  # noqa: BLE001
                log(f"skip {fp}: {e}")


def embed_local(model_ref: str, texts: list[str]):
    from sentence_transformers import SentenceTransformer  # lazy import

    log(f"loading local/HF model: {model_ref}")
    model = SentenceTransformer(model_ref)  # local path OR HF id; cached on disk
    return model.encode(
        texts, batch_size=32, show_progress_bar=False, normalize_embeddings=True
    ).tolist()


def embed_endpoint(model_ref: str, texts: list[str], endpoint: str, api_key: str):
    import urllib.request

    log(f"POST {endpoint}  model={model_ref}  (hosted => provider rate limits apply)")
    body = json.dumps({"model": model_ref, "input": texts}).encode()
    req = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req) as r:  # noqa: S310
        data = json.load(r)
    return [d["embedding"] for d in data["data"]]


def write_rows(paths, vecs, model_ref, out):
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq

        pq.write_table(
            pa.table(
                {"path": paths, "embedding": vecs, "model": [model_ref] * len(paths)}
            ),
            out,
        )
        log(f"wrote {len(vecs)} vectors -> {out}")
    except ModuleNotFoundError:
        alt = Path(out).with_suffix(".jsonl")
        with alt.open("w") as f:
            for p, v in zip(paths, vecs):
                f.write(json.dumps({"path": p, "embedding": v, "model": model_ref}) + "\n")
        log(f"pyarrow missing; wrote {len(vecs)} vectors -> {alt}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", default="out/embeddings.parquet")
    args = ap.parse_args()

    pairs = list(read_texts(args.input))
    if not pairs:
        log("nothing to embed; exiting 0")
        return 0
    paths = [p for p, _ in pairs]
    texts = [t for _, t in pairs]

    endpoint = os.environ.get("EMBED_ENDPOINT")
    model_ref = args.model

    if Path(model_ref).exists():
        vecs = embed_local(model_ref, texts)
    elif endpoint:
        api_key = os.environ.get("EMBED_API_KEY", "")
        if not api_key:
            log("EMBED_ENDPOINT is set but EMBED_API_KEY is missing")
            return 2
        vecs = embed_endpoint(model_ref, texts, endpoint, api_key)
    else:
        # 'pplx-embed-context-V1-.06' is not a public Hugging Face id. To run fully
        # local + rate-limit-free, point --model at the weights on the runner's
        # storage; or set EMBED_ENDPOINT + EMBED_API_KEY to use a hosted resolver.
        vecs = embed_local(model_ref, texts)

    write_rows(paths, vecs, model_ref, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
