#!/bin/bash
# Regenerate libcamera-rgbir/debayer_cpu.patch from the working build tree.
#
# WHY THIS EXISTS
#
# Our changes to debayer_cpu live in ~/.cache/libcamera-build/, which is not a
# git repo and is not backed up. The patch in this repo is the only record, and
# it goes stale the moment anyone edits the build tree - which has now happened
# twice in two days. A fresh clone then silently builds a libcamera missing
# whatever was added since, with every source file present and correct in git, so
# nothing looks wrong.
#
# Run this after editing debayer_cpu in the build tree. Run --check in doubt; it
# exits non-zero if the committed patch no longer reproduces the build.
#
#   tools/refresh-debayer-patch.sh           regenerate and verify
#   tools/refresh-debayer-patch.sh --check    report drift, change nothing

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
PATCHFILE="$REPO/libcamera-rgbir/debayer_cpu.patch"
BUILD="${LIBCAMERA_SRC:-$HOME/.cache/libcamera-build/libcamera-src}/src/libcamera/software_isp"
UPSTREAM="${LIBCAMERA_UPSTREAM:-$REPO/../libcamera-upstream}"
BASE="${LIBCAMERA_BASE:-v0.7.0}"
FILES=(debayer_cpu.h debayer_cpu.cpp)

[ -d "$BUILD" ]         || { echo "ERROR: no build tree at $BUILD" >&2; exit 1; }
[ -d "$UPSTREAM/.git" ] || { echo "ERROR: no libcamera clone at $UPSTREAM" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/orig" "$tmp/verify"
for f in "${FILES[@]}"; do
    git -C "$UPSTREAM" show "$BASE:src/libcamera/software_isp/$f" > "$tmp/orig/$f" 2>/dev/null || {
        echo "ERROR: $BASE has no src/libcamera/software_isp/$f" >&2; exit 1; }
done

new="$tmp/new.patch"
: > "$new"
for f in "${FILES[@]}"; do
    diff -u --label "a/src/libcamera/software_isp/$f" \
            --label "b/src/libcamera/software_isp/$f" \
            "$tmp/orig/$f" "$BUILD/$f" >> "$new" || true
done

# Prove the patch reproduces the build tree before trusting it. A patch that
# applies but produces something else is worse than no patch.
cp "$tmp/orig"/* "$tmp/verify/"
if ! patch -s -p4 -d "$tmp/verify" < "$new"; then
    echo "ERROR: the generated patch does not apply to $BASE" >&2; exit 1
fi
for f in "${FILES[@]}"; do
    cmp -s "$tmp/verify/$f" "$BUILD/$f" || {
        echo "ERROR: patch does not reproduce $f - is the build tree based on $BASE?" >&2
        exit 1; }
done

# Compare with the ---/+++ header timestamps stripped. diff(1) stamps those with
# the file mtime, so an unchanged patch regenerated at a different moment looks
# like drift, and a check that cries wolf gets ignored. Generated patches here
# carry no timestamps for the same reason.
norm() { sed -E 's/^(---|\+\+\+)([^\t]*)\t.*/\1\2/' "$1"; }

if [ "${1:-}" = "--check" ]; then
    if diff -q <(norm "$new") <(norm "$PATCHFILE") >/dev/null 2>&1; then
        echo "  in sync with the build tree"
        exit 0
    fi
    echo "  DRIFT: the committed patch does not match the build tree"
    diff -u "$PATCHFILE" "$new" | grep -cE '^[+-]' | xargs echo "  differing lines:"
    echo "  run tools/refresh-debayer-patch.sh to update it"
    exit 1
fi

if diff -q <(norm "$new") <(norm "$PATCHFILE") >/dev/null 2>&1; then
    echo "  already up to date ($(grep -c '^+' "$PATCHFILE") added lines)"
else
    cp "$new" "$PATCHFILE"
    echo "  regenerated: $(grep -c '^+' "$PATCHFILE") added lines, verified against $BASE"
fi
