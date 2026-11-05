#!/bin/sh
# Bump VERSION. Prints the new version.
#   usage: bump-version.sh [major|minor|patch]   (default: patch)
set -eu
cd "$(dirname "$0")/.."

type="${1:-patch}"
current="$(cat VERSION)"
major="${current%%.*}"
rest="${current#*.}"
minor="${rest%%.*}"
patch="${rest#*.}"

case "$type" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac

version="${major}.${minor}.${patch}"
printf '%s\n' "$version" > VERSION
echo "$version"
