#!/usr/bin/env bash
set -euo pipefail

# Bump the patch version in pubspec.yaml, commit, and push.
# Usage: ./bump_version.sh [--push]

cd "$(dirname "$0")"

current=$(grep '^version:' pubspec.yaml | sed 's/version: *//')
major="${current%%.*}"
rest="${current#*.}"
minor="${rest%%.*}"
patch="${rest#*.}"
patch="${patch%%+*}"  # strip build number

new_patch=$((patch + 1))
new_ver="${major}.${minor}.${new_patch}+1"

# macOS vs Linux sed
if [[ "$(uname)" == "Darwin" ]]; then
  sed -i '' "s/^version:.*/version: $new_ver/" pubspec.yaml
else
  sed -i "s/^version:.*/version: $new_ver/" pubspec.yaml
fi

echo "${current} → ${new_ver}"

git add .
git commit -m "chore: bump version ${current} → ${new_ver}"

if [[ "${1:-}" == "--push" ]]; then
  git push origin main
fi
