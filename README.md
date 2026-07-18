# wake

A **self-hosted, scale-to-zero embedding runner**. It spins up a cheap (2-core is
plenty) box on demand, runs a **local** embedding model, pulls every secret from
**Doppler**, and tears down. It is designed so that **nothing in the embed path can
be rate-limited.**

## Why nothing here is rate-limited

Rate limits are **per API service, not per machine.** This spine avoids all three
that usually bite:

| Limit | Who it hits | How `wake` avoids it |
| --- | --- | --- |
| GitHub REST/GraphQL **5,000/hr per user PAT** | your `gh`, GitKraken, GitLens, ruflo — all sharing one bucket | the embed job never calls the GitHub API; secrets come from Doppler |
| GitHub **`GITHUB_TOKEN` 1,000/hr per repo** | code inside an Actions job | separate bucket from your PAT; the job barely touches it (checkout only) |
| Model-provider embedding quota | anything calling a *hosted* embeddings API | the model runs **locally** on the runner's storage — zero external calls |

A self-hosted runner's job-polling channel is a long-poll and is negligible. So the
only way to reintroduce a limit is to point `EMBED_MODEL` at a *hosted* endpoint
(see below).

## Layout

```
.claude/settings.json      SessionStart hook: hydrate all Doppler secrets into the
                           session env (works in claude.ai/code cloud sessions + local)
.github/workflows/embed.yml  the embed job — self-hosted, ephemeral, hardened, Doppler-injected
scripts/runner-bootstrap.sh  bring up an ephemeral runner on any 2-core Linux box
scripts/embed_run.sh         job entrypoint (doppler run -- python embed/serve.py)
scripts/cloud-setup.sh       paste into the claude.ai/code env "Setup script" field
embed/serve.py               local-first embedder with a hosted fallback
embed/requirements.txt       model deps (cached on the runner's storage)
```

## How it works (Codespaces path — the primary spine)

1. **`WAKE_TARGETS`** (a repo secret, backed by Doppler) holds the comma-separated
   Codespace name(s) that run the embed model. Placeholder today: `wake-runner` —
   rotate it to the real name from `gh codespace list --json name` (a Codespace's
   name is an auto-generated slug, not a label you pick).
2. **`.github/workflows/wake.yml`** (dispatch-only, on free public-repo hosted
   minutes) starts any stopped target Codespace via the GitHub API using `GH_PAT`.
   Trigger it: Actions tab → **wake** → Run workflow, or `gh workflow run wake.yml`.
3. The Codespace boots from **`.devcontainer/devcontainer.json`** (2-core), installs
   Doppler + embed deps, and reads a `DOPPLER_TOKEN` **Codespaces secret**. The
   SessionStart hook hydrates every other secret. Run the embed with
   `doppler run -- bash scripts/embed_run.sh`.
4. When idle, the Codespace **auto-suspends** (Settings → Codespaces → idle timeout) —
   that's the "timed shutdown," and it costs nothing while stopped. Education/Pro
   core-hours cover it.

Required secrets: `WAKE_TARGETS` and `GH_PAT` (needs **codespace** scope) as repo
secrets — both set — plus a `DOPPLER_TOKEN` Codespaces secret for the box.

### Alternative: self-hosted runner on any free 2-core box

If you'd rather not use Codespaces, `scripts/runner-bootstrap.sh` brings up an
**ephemeral** GitHub Actions runner (Oracle Always Free / Azure for Students / GCP /
home hardware) that runs `.github/workflows/embed.yml`:

```bash
git clone https://github.com/Synodic-AI/wake.git && cd wake
export REPO=Synodic-AI/wake
export REG_TOKEN=$(gh api repos/$REPO/actions/runners/registration-token -q .token)
export DOPPLER_SERVICE_TOKEN=dp.st.dev.xxxxx     # read-only, box-local Doppler auth
./scripts/runner-bootstrap.sh --shutdown-after   # spin up -> run one job -> power off
```

Same Doppler backplane; `--shutdown-after` gives the same scale-to-zero behavior.

## Doppler (the secret backplane)

Secrets live in Doppler project `synodic-ai` (`dev`/`stg`/`prd`), **not** in GitHub —
that is what keeps GitHub's API out of the hot path. Two ways the runner authenticates:

- **Box-local (recommended):** `DOPPLER_SERVICE_TOKEN` on the box → `doppler configure`.
  No repo secret exists, so nothing can leak from the public repo.
- **Repo secret (optional, for GitHub-hosted fallback):** add one secret `DOPPLER_TOKEN`;
  the workflow reads it. Prefer a Doppler config scoped to only the embed secrets.

`EMBED_MODEL` (in Doppler) selects the model. Currently `pplx-embed-context-V1-.06`.
`serve.py` resolves it: a **local path** → fully offline; else `$EMBED_ENDPOINT` +
`$EMBED_API_KEY` → hosted (rate-limited); else a Hugging Face id. To stay unthrottled,
put the weights on the runner's storage and set `EMBED_MODEL` to that path.

## Cloud sessions (claude.ai/code) — "operate as a normal session"

1. Add a cloud **environment** with env var `DOPPLER_TOKEN=dp.st.dev.…` and set the
   **Setup script** to the contents of `scripts/cloud-setup.sh`.
2. **Network access → Custom**, keep defaults, add `api.doppler.com` and `cli.doppler.com`.
3. The `.claude/settings.json` SessionStart hook then hydrates every Doppler secret
   into each session — fresh per session, never baked into the cached image.

## Security — READ THIS (public repo + self-hosted runner)

Running a self-hosted runner on a **public** repo is the single most dangerous Actions
config: a stranger's fork PR could execute code on your hardware and steal your
secrets. This repo is hardened against it:

- **No `pull_request` trigger**, plus an `if: fork != true` guard — fork code never runs.
- **Ephemeral** runners — fresh per job, no state bleed.
- **Box-local Doppler** — no secret sits in the public repo.

Also do this once in the GitHub UI: **Settings → Actions → General → Fork pull request
workflows → "Require approval for all outside collaborators."** If the repo doesn't
actually need to be public, making it private removes the whole class of risk.
