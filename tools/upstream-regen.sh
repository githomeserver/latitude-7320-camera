#!/bin/bash
# Set the patch author and regenerate the series with Signed-off-by.
#
# The Developer's Certificate of Origin requires a real name, so this cannot be
# filled in for you. Run it once with your name:
#
#   ./upstream-regen.sh "Ada Lovelace" ada@example.org
#
# The email defaults to the address git/this machine already knows.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/../upstream"

NAME="${1:-}"
EMAIL="${2:-adee.sahan@gmail.com}"

if [ -z "$NAME" ]; then
    echo "usage: $0 \"Your Real Name\" [you@example.org]" >&2
    echo >&2
    echo "The DCO requires a real name - pseudonyms are not accepted upstream." >&2
    exit 1
fi

cd "$REPO"

BASE="$(git log --format=%H --grep='pristine linux-source' -1)"
[ -n "$BASE" ] || { echo "ERROR: baseline commit not found" >&2; exit 1; }

git config user.name "$NAME"
git config user.email "$EMAIL"

echo "== rewriting $(git rev-list --count "$BASE"..HEAD) commits as $NAME <$EMAIL> =="
git rebase --signoff --exec 'git commit --amend --no-edit --reset-author -q' "$BASE" >/dev/null

rm -f "$REPO"/*.patch
git format-patch -3 -o "$REPO" --cover-letter --subject-prefix="PATCH" -q

# git leaves the cover letter subject/blurb as placeholders; put ours back.
COVER="$(ls "$REPO"/0000-cover-letter.patch)"
python3 - "$COVER" "$HERE/../upstream/cover-letter.txt" <<'EOF'
import sys
cover, body = sys.argv[1], sys.argv[2]
text = open(cover).read()
subject, blurb = open(body).read().split("\n\n", 1)
text = text.replace("*** SUBJECT HERE ***", subject.strip())
text = text.replace("*** BLURB HERE ***", blurb.strip())
open(cover, "w").write(text)
EOF

echo
echo "== series =="
ls -1 "$REPO"/*.patch
echo
echo "Check it before sending:"
echo "  cd '$REPO' && ../kernel-src/linux-source-7.0.0/scripts/checkpatch.pl --strict 000[123]-*.patch"
