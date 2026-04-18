#!/usr/bin/env bash
# claude-bootstrap — one-shot setup for the claude-contexts launcher
#
# Usage:
#   GH_PAT=<fine-grained-pat> bash <(curl -fsSL \
#     https://raw.githubusercontent.com/develop-vireo/claude-bootstrap/main/bootstrap.sh)
#
# Requires: git. Installs: jq (if missing). Clones claude-contexts + all
# project repos listed in its manifest. Wires `cc` into ~/.bashrc.
# Idempotent — rerunning is safe.

set -euo pipefail

: "${GH_PAT:?Set GH_PAT to a fine-grained PAT with read access to develop-vireo/claude-contexts plus the project repos it lists}"

CONTEXTS_REPO="${CONTEXTS_REPO:-develop-vireo/claude-contexts}"
CONTEXTS_DIR="${CONTEXTS_DIR:-$HOME/claude-contexts}"

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '[bootstrap] %s\n' "$*"; }

# --- 1. Prereqs ---------------------------------------------------------------
have git || { echo "ERROR: git required"; exit 1; }

if ! have jq; then
  say "installing jq…"
  if have apt-get; then sudo apt-get update -qq && sudo apt-get install -y -qq jq
  elif have brew;    then brew install jq
  elif have dnf;     then sudo dnf install -y jq
  elif have yum;     then sudo yum install -y jq
  else echo "ERROR: install jq manually, then rerun"; exit 1
  fi
fi

# --- 2. Write git credentials -------------------------------------------------
say "writing ~/.git-credentials"
umask 077
printf 'https://%s@github.com\n' "$GH_PAT" > "$HOME/.git-credentials"
chmod 600 "$HOME/.git-credentials"

# --- 3. Clone claude-contexts (private) ---------------------------------------
if [ ! -d "$CONTEXTS_DIR/.git" ]; then
  say "cloning $CONTEXTS_REPO → $CONTEXTS_DIR"
  git clone "https://${GH_PAT}@github.com/${CONTEXTS_REPO}.git" "$CONTEXTS_DIR"
else
  say "claude-contexts already cloned; pulling latest"
  git -C "$CONTEXTS_DIR" pull --ff-only --quiet
fi

MANIFEST="$CONTEXTS_DIR/manifest.json"
[ -f "$MANIFEST" ] || { echo "ERROR: no manifest.json in $CONTEXTS_DIR"; exit 1; }

# --- 4. Clone project repos listed in manifest --------------------------------
jq -r '.projects | to_entries[] | select(.value.repo) | "\(.key)\t\(.value.repo)\t\(.value.root)"' \
  "$MANIFEST" | while IFS=$'\t' read -r proj repo root; do
  root_abs="${root/#\~/$HOME}"
  if [ -d "$root_abs/.git" ]; then
    say "$proj already at $root_abs"
  else
    say "cloning $repo → $root_abs"
    mkdir -p "$(dirname "$root_abs")"
    git clone "https://${GH_PAT}@github.com/${repo}.git" "$root_abs"
  fi
done

# --- 5. Wire the launcher -----------------------------------------------------
say "running install.sh"
bash "$CONTEXTS_DIR/install.sh" "$CONTEXTS_DIR"

# --- 6. Post-flight -----------------------------------------------------------
have claude || say "WARN: 'claude' CLI not on PATH — install Claude Code next"

cat <<EOF

[bootstrap] Done.

Next:
  source ~/.bashrc
  cc /?

Then, e.g.:
  cc agentapply warn
  cc talent fleet
EOF
