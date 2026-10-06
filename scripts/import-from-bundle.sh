#!/usr/bin/env bash
# Import the agent-produced git bundle into github.com/joncrain/watari
set -euo pipefail
BUNDLE="${1:-watari.bundle}"
REMOTE="${2:-https://github.com/joncrain/watari.git}"
BRANCH="cursor/initial-watari-bb36"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone "$BUNDLE" "$TMP/watari"
cd "$TMP/watari"
git checkout "$BRANCH"
git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE"
git push -u origin "$BRANCH"
git push origin "$BRANCH:main" || true
echo "Pushed $BRANCH to $REMOTE"
