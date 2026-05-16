# claude-bootstrap

One-command setup for the [claude-contexts](https://github.com/vireoagents/claude-contexts) launcher.

This repo is **public on purpose** — it holds nothing sensitive. The actual
context map + overlays live in the private `claude-contexts` repo, which this
script clones using the PAT you provide.

## Usage (on a clean machine)

Prereqs: `git` and the `claude` CLI already installed. Everything else is
handled by the script.

```bash
GH_PAT=<paste-fine-grained-pat> bash <(curl -fsSL \
  https://raw.githubusercontent.com/vireoagents/bootstrap/main/bootstrap.sh)
source ~/.bashrc
cc /?
```

That's it. One paste, one command.

## PAT scope required

A fine-grained PAT with **Contents: Read** on:
- `vireoagents/claude-contexts` (for the launcher itself)
- each project repo listed in `claude-contexts/manifest.json`

As of now that's: `AgentApply`, `job-scraper`, `claude-contexts`.

For Read+Write (so you can push from the machine too), set Contents to
**Read and write** on the same repos.

## What the script does

1. Installs `jq` if missing (apt / brew / dnf / yum)
2. Writes `~/.git-credentials` with the PAT
3. Clones `vireoagents/claude-contexts` → `~/claude-contexts`
4. Reads `manifest.json` and clones every listed project repo to its `root`
5. Runs `claude-contexts/install.sh` (symlinks + bashrc wire-up)

Idempotent — rerun any time to add newly-listed repos.

## Overrides (optional)

- `CONTEXTS_REPO` — override which private repo to clone (default `vireoagents/claude-contexts`)
- `CONTEXTS_DIR`  — override local path (default `~/claude-contexts`)
