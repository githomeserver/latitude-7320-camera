#!/bin/bash
# Copy the camera project's memory notes into the repo, and build an index.
#
# WHY THIS EXISTS
#
# Claude's notes live in ~/.claude/projects/<derived-path>/memory/, outside this
# repo, mixed in with notes for unrelated things - a router, a tablet, a clock.
# Moving the project to another machine therefore either loses the notes or drags
# along everything else.
#
# This copies just the camera ones in, so `git clone` brings them. It is a script
# rather than a one-off copy because a stale duplicate is worse than none: this
# project has already been bitten by notes that described a configuration nobody
# was running any more. Re-run it whenever the notes change.
#
# The canonical copy stays where Claude writes it. This is a mirror.
#
#   tools/sync-memory.sh            copy in, rebuild the index
#   tools/sync-memory.sh --check    report drift, change nothing (exit 1 if any)

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
DEST="$REPO/memory"
SRC="${MEMORY_SRC:-$HOME/.claude/projects/-home-sahan-Claude-Code/memory}"

# Which notes belong to this project. Explicit prefixes, not "everything", so a
# note about something else cannot drift in unnoticed.
PREFIXES=(ov5678- latitude-7320- int3472- readme-progress-)

[ -d "$SRC" ] || { echo "ERROR: no memory directory at $SRC" >&2
                   echo "       set MEMORY_SRC if the project path differs" >&2; exit 1; }

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

mapfile -t files < <(
    for p in "${PREFIXES[@]}"; do
        for f in "$SRC/$p"*.md; do [ -e "$f" ] && basename "$f"; done
    done | sort -u
)
[ "${#files[@]}" -gt 0 ] || { echo "ERROR: no project notes matched in $SRC" >&2; exit 1; }

if [ "$check_only" -eq 1 ]; then
    drift=0
    for f in "${files[@]}"; do
        if ! cmp -s "$SRC/$f" "$DEST/$f"; then echo "  differs: $f"; drift=1; fi
    done
    shopt -s nullglob
    for f in "$DEST"/*.md; do
        b=$(basename "$f")
        [ "$b" = "README.md" ] && continue
        printf '%s\n' "${files[@]}" | grep -qx "$b" || { echo "  stale in repo: $b"; drift=1; }
    done
    [ "$drift" -eq 0 ] && echo "  in sync (${#files[@]} notes)"
    exit "$drift"
fi

mkdir -p "$DEST"
# nullglob: an empty destination must expand to nothing, not to the literal
# "*.md", which the removal loop below would report as a stale file.
shopt -s nullglob
for f in "$DEST"/*.md; do
    b=$(basename "$f")
    [ "$b" = "README.md" ] && continue
    printf '%s\n' "${files[@]}" | grep -qx "$b" || { rm -f "$f"; echo "  removed stale $b"; }
done
for f in "${files[@]}"; do
    install -m644 "$SRC/$f" "$DEST/$f"
    echo "  $f"
done

# Index built from each note's own description, so it cannot disagree with them.
{
    echo "# Camera project notes"
    echo
    echo "Mirrored from Claude's memory directory by \`tools/sync-memory.sh\`."
    echo "To use them on another machine, copy these into that machine's"
    echo "\`~/.claude/projects/<derived-path>/memory/\` - the path is derived from"
    echo "the project's working directory, so keep the project at \`~/Claude Code\`."
    echo
    for f in "${files[@]}"; do
        d=$(sed -n 's/^description: *//p' "$DEST/$f" | head -1 | sed 's/^"//; s/"$//')
        echo "- [\`$f\`]($f) — $d"
    done
} > "$DEST/README.md"
echo "  index: $DEST/README.md"
