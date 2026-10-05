#!/usr/bin/env bash
# Merge upstream/main into every fork feature branch, then the finished ones
# into main, building and testing each branch. Stops at the first merge conflict or
# failure; fix it on that branch, commit, and run the script again.
#
# Usage: fork/sync-upstream.sh [--no-build]
#   ZIG=/path/to/zig   zig binary to use (default: zig on PATH)
set -euo pipefail

# Feature branches in merge order, as "branch" or "branch:base" when the
# branch builds on another feature (which must be listed before it).
# FEATURES are on main; IN_PROGRESS branches are kept current with upstream
# but not merged into main until they move up to FEATURES.
FEATURES=(
  feature/usb-console
  feature/cart-serial:feature/usb-console
)
IN_PROGRESS=(
  feature/net-lobby:feature/cart-serial
)

ZIG="${ZIG:-zig}"
BUILD=1
[[ "${1:-}" == "--no-build" ]] && BUILD=0

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: working tree has uncommitted changes" >&2
  exit 1
fi
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "error: a merge is in progress; finish it (git commit) or abort it first" >&2
  exit 1
fi

start_branch="$(git rev-parse --abbrev-ref HEAD)"

git fetch upstream
upstream_head="$(git rev-parse --short upstream/main)"
echo "upstream/main is $upstream_head"

check() {
  if [[ $BUILD == 1 ]]; then
    echo "  building and testing $1"
    "$ZIG" build >/dev/null
    "$ZIG" build test >/dev/null
  fi
}

merge_into() { # merge_into <branch> <source>
  local branch="$1" source="$2"
  git switch -q "$branch"
  if git merge-base --is-ancestor "$source" HEAD; then
    echo "$branch: already contains $source"
    return 1
  fi
  echo "$branch: merging $source"
  if ! git merge --no-ff --no-edit -m "Merge $source ($(git rev-parse --short "$source")) into $branch" "$source"; then
    echo
    echo "Conflict merging $source into $branch."
    echo "Resolve it, 'git commit', then run $0 again."
    exit 1
  fi
}

branches=()
for entry in "${FEATURES[@]}" "${IN_PROGRESS[@]}"; do
  branch="${entry%%:*}"
  base="${entry#*:}"
  [[ "$base" == "$entry" ]] && base=upstream/main
  branches+=("$branch")
  # The base first (upstream/main, or a feature that already contains it).
  if merge_into "$branch" "$base"; then check "$branch"; fi
done

changed=0
merge_into main upstream/main && changed=1
for entry in "${FEATURES[@]}"; do
  merge_into main "${entry%%:*}" && changed=1
done
if [[ $changed == 1 ]]; then check main; fi

git switch -q "$start_branch"
echo
echo "Done: main and ${branches[*]} contain upstream $upstream_head."
echo "Publish with: git push origin main ${branches[*]}"
