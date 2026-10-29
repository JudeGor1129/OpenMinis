#!/usr/bin/env bash
# Push ONLY the toolchain-build tree as a tiny, parentless commit.
#
# Why: this fork's main history is large and GitHub rejects the pack with
# HTTP 400 ("send-pack: unexpected disconnect"). The workflow push trigger only
# needs the toolchain files to exist on the branch, so we build a standalone
# tree with a temporary index (leaving the working tree and current branch
# untouched) and push that single commit as a new ref.
set -uo pipefail

R="/var/mobile/Twork/Workspaces/JudeGor/OpenMinis-source-review/OpenMinis-main"
TOKEN_FILE="/var/mobile/Twork/Workspaces/JudeGor/github token.txt"
BRANCH="${1:-toolchain-ci}"

cd "$R" || exit 1
TOKEN="$(cat "$TOKEN_FILE" | tr -d '\r\n')"
[ -n "$TOKEN" ] || { echo "no token"; exit 1; }

G="git -c safe.directory=*"

export GIT_INDEX_FILE=/tmp/tc-push.index
rm -f "$GIT_INDEX_FILE"

# Empty tree, then add just what the CI workflow needs.
$G read-tree --empty || exit 1
$G add toolchain-build .github/workflows/toolchain.yml >/dev/null 2>&1 || {
  echo "FAIL: git add"; exit 1;
}

FILES=$($G ls-files | wc -l | tr -d ' ')
TREE=$($G write-tree) || { echo "FAIL write-tree"; exit 1; }
echo "tree $TREE with $FILES files"

COMMIT=$(printf '%s\n' \
  "toolchain: in-process clang+LLVM+ld64 build for arm64e" \
  "" \
  "Standalone tree so the CI pack stays small. Adds a self-contained build of" \
  "clang, LLVM and Apple ld64 as iOS static libraries, plus the in-process" \
  "bridge and a byte-level B-key verifier." \
  "" \
  "arm64e correctness depends on deps/patches: without them a toolchain still" \
  "links 'successfully' but emits arm64 with A-key PAC." \
  | $G commit-tree "$TREE") || { echo "FAIL commit-tree"; exit 1; }

echo "commit $COMMIT"
$G log --oneline -1 "$COMMIT"

URL="https://JudeGor1129:${TOKEN}@github.com/JudeGor1129/OpenMinis.git"
echo "pushing $COMMIT -> refs/heads/$BRANCH"
timeout 280 $G push "$URL" "$COMMIT:refs/heads/$BRANCH" 2>&1 \
  | sed 's/JudeGor1129:[^@]*@/JudeGor1129:***@/g'
rc=${PIPESTATUS[0]}
echo "push exit=$rc"
exit $rc
