#!/usr/bin/env bash
# claude-bootstrap — one-shot setup for the claude-contexts launcher
#
# Usage:
#   GH_PAT=<fine-grained-pat> bash <(curl -fsSL \
#     https://raw.githubusercontent.com/develop-vireo/bootstrap/main/bootstrap.sh)
#
# Flags:
#   --dry-run / --diff-only   show proposed changes as diffs, write nothing
#   --force                   don't prompt on credential replacement
#   -h / --help               this help
#
# Environment:
#   GH_PAT           fine-grained PAT (required)
#   CONTEXTS_REPO    default: develop-vireo/claude-contexts
#   CONTEXTS_DIR     default: $HOME/claude-contexts
#
# Idempotent. Never silently overwrites existing PATs or repos with mismatched
# origins.

set -euo pipefail

# --- Flag parsing -------------------------------------------------------------
DRY_RUN=0
FORCE=0

usage() {
  grep -E '^# ' "$0" | sed 's/^# \{0,1\}//' | head -30
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|--diff-only) DRY_RUN=1 ;;
    --force)               FORCE=1 ;;
    -h|--help)             usage; exit 0 ;;
    *)                     echo "unknown flag: $1 (use --help)"; exit 1 ;;
  esac
  shift
done

[ "$DRY_RUN" = 1 ] && echo "[bootstrap] DRY-RUN — no writes, no clones, no network mutation"

: "${GH_PAT:?Set GH_PAT to a fine-grained PAT with read access to develop-vireo/claude-contexts plus the project repos it lists}"

CONTEXTS_REPO="${CONTEXTS_REPO:-develop-vireo/claude-contexts}"
CONTEXTS_DIR="${CONTEXTS_DIR:-$HOME/claude-contexts}"

# --- Summary tracking ---------------------------------------------------------
CREATED=()
MODIFIED=()
SKIPPED=()
WARNED=()

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '[bootstrap] %s\n' "$*"; }

prefix20() { printf '%s' "${1:0:20}"; }

# --- 1. Prereqs ---------------------------------------------------------------
have git || { echo "ERROR: git required"; exit 1; }

if ! have jq; then
  if [ "$DRY_RUN" = 1 ]; then
    say "would install jq (not found)"
    WARNED+=("jq missing; dry-run cannot exercise manifest parsing")
  else
    say "installing jq…"
    if   have apt-get; then sudo apt-get update -qq && sudo apt-get install -y -qq jq
    elif have brew;    then brew install jq
    elif have dnf;     then sudo dnf install -y jq
    elif have yum;     then sudo yum install -y jq
    else echo "ERROR: install jq manually, then rerun"; exit 1
    fi
    MODIFIED+=("system:jq installed")
  fi
fi

# --- 2. Credential handling (safe replace) ------------------------------------
CREDS="$HOME/.git-credentials"
NEW_LINE="https://${GH_PAT}@github.com"

handle_credentials() {
  if [ ! -f "$CREDS" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      say "would create $CREDS (PAT $(prefix20 "$GH_PAT")…)"
    else
      umask 077
      printf '%s\n' "$NEW_LINE" > "$CREDS"
      chmod 600 "$CREDS"
      CREATED+=("$CREDS")
    fi
    return
  fi

  local existing
  existing=$(grep '@github.com' "$CREDS" 2>/dev/null | head -1 || true)

  if [ "$existing" = "$NEW_LINE" ]; then
    say "$CREDS already has this PAT, unchanged"
    SKIPPED+=("$CREDS (same PAT)")
    return
  fi

  local old_pat_prefix new_pat_prefix
  old_pat_prefix=$(printf '%s' "$existing" | sed -E 's|https://([^@]{0,20}).*|\1|')
  new_pat_prefix=$(prefix20 "$GH_PAT")

  say "WARNING: $CREDS exists with a DIFFERENT PAT"
  say "  existing prefix: ${old_pat_prefix}…"
  say "  new prefix:      ${new_pat_prefix}…"

  if [ "$DRY_RUN" = 1 ]; then
    say "would back up existing to ${CREDS}.bak.<ts> and replace"
    return
  fi

  if [ "$FORCE" = 0 ]; then
    if [ -t 0 ]; then
      read -r -p "[bootstrap] Replace existing PAT? [y/N] " ans
    else
      ans=""
    fi
    if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
      say "skipped (user declined or non-interactive — use --force to override)"
      SKIPPED+=("$CREDS (user declined replacement)")
      return
    fi
  fi

  local backup="${CREDS}.bak.$(date +%s)"
  cp "$CREDS" "$backup"
  printf '%s\n' "$NEW_LINE" > "$CREDS"
  chmod 600 "$CREDS"
  MODIFIED+=("$CREDS (backup: $backup)")
}

handle_credentials

# --- 3. Clone claude-contexts (private) ---------------------------------------
clone_or_update() {
  local repo="$1" dest="$2"
  local expected_url_ptn="github\\.com[/:]${repo}(\\.git)?\$"

  if [ ! -d "$dest/.git" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      say "would clone $repo → $dest"
    else
      mkdir -p "$(dirname "$dest")"
      git clone "https://${GH_PAT}@github.com/${repo}.git" "$dest"
      CREATED+=("$dest")
    fi
    return
  fi

  local actual_url
  actual_url=$(git -C "$dest" remote get-url origin 2>/dev/null || echo "")

  if ! echo "$actual_url" | grep -qE "$expected_url_ptn"; then
    say "WARN: $dest origin is '$actual_url' — manifest expects $repo"
    say "     skipping (fix manually if this is unexpected)"
    WARNED+=("$dest: origin mismatch (got $actual_url, expected $repo)")
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    say "would git pull --ff-only in $dest"
    SKIPPED+=("$dest (exists, would ff-pull)")
  else
    if git -C "$dest" pull --ff-only --quiet 2>/dev/null; then
      SKIPPED+=("$dest (already cloned, pulled)")
    else
      WARNED+=("$dest: pull --ff-only failed (diverged?)")
    fi
  fi
}

clone_or_update "$CONTEXTS_REPO" "$CONTEXTS_DIR"

# --- 4. Clone project repos listed in manifest --------------------------------
MANIFEST="$CONTEXTS_DIR/manifest.json"

if [ "$DRY_RUN" = 1 ] && [ ! -f "$MANIFEST" ]; then
  say "WARN: manifest not present locally and DRY-RUN did not fetch — skipping project repo plan"
  WARNED+=("manifest unavailable in dry-run before first real bootstrap")
elif [ ! -f "$MANIFEST" ]; then
  echo "ERROR: no manifest.json in $CONTEXTS_DIR"
  exit 1
else
  if have jq; then
    while IFS=$'\t' read -r proj repo root; do
      root_abs="${root/#\~/$HOME}"
      clone_or_update "$repo" "$root_abs"
    done < <(jq -r '.projects | to_entries[] | select(.value.repo) | "\(.key)\t\(.value.repo)\t\(.value.root)"' "$MANIFEST")
  else
    say "jq not available; skipping manifest parse"
  fi
fi

# --- 5. Wire the launcher -----------------------------------------------------
if [ -f "$CONTEXTS_DIR/install.sh" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    say "would run: $CONTEXTS_DIR/install.sh (symlinks + bashrc)"
  else
    say "running install.sh"
    bash "$CONTEXTS_DIR/install.sh" "$CONTEXTS_DIR"
    MODIFIED+=("~/.bashrc (if not already wired), ~/.claude/contexts (symlink)")
  fi
else
  WARNED+=("install.sh not found at $CONTEXTS_DIR/install.sh")
fi

# --- 6. Post-flight -----------------------------------------------------------
have claude || WARNED+=("'claude' CLI not on PATH — install Claude Code")

# --- 7. Summary ---------------------------------------------------------------
join_or_none() {
  if [ $# -eq 0 ]; then
    echo "none"
  else
    local IFS=', '
    echo "$*"
  fi
}

echo ""
echo "=== Summary${DRY_RUN:+ (DRY-RUN)} ==="
printf 'created:  %s\n' "$(join_or_none ${CREATED[@]+"${CREATED[@]}"})"
printf 'modified: %s\n' "$(join_or_none ${MODIFIED[@]+"${MODIFIED[@]}"})"
printf 'skipped:  %s\n' "$(join_or_none ${SKIPPED[@]+"${SKIPPED[@]}"})"
printf 'warned:   %s\n' "$(join_or_none ${WARNED[@]+"${WARNED[@]}"})"
echo ""

if [ "$DRY_RUN" = 1 ]; then
  say "Dry-run complete. Rerun without --dry-run to apply."
else
  cat <<'EOF'
[bootstrap] Done.

Next:
  source ~/.bashrc
  cc /?
EOF
fi
