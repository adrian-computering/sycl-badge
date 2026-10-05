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

# The worktree a branch is checked out in, or empty.
worktree_of() {
  git worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { wt = substr($0, 10) }
    $0 == "branch " ref { print wt }'
}

# Run git for <branch> where it can be changed: its own worktree if it is
# checked out somewhere, otherwise this one after switching to it.
branch_dir() {
  local wt
  wt="$(worktree_of "$1")"
  if [[ -z "$wt" ]]; then
    git switch -q "$1"
    wt="$(pwd)"
  fi
  if [[ -n "$(git -C "$wt" status --porcelain --untracked-files=no)" ]]; then
    echo "error: $1 is checked out in $wt with uncommitted changes" >&2
    exit 1
  fi
  echo "$wt"
}

check() { # check <branch> <dir>
  if [[ $BUILD == 1 ]]; then
    echo "  building and testing $1"
    (cd "$2" && "$ZIG" build >/dev/null && "$ZIG" build test >/dev/null) || {
      echo "error: build or tests failed on $1 (in $2)" >&2
      exit 1
    }
  fi
}

merge_into() { # merge_into <branch> <source>; sets $dir; returns 1 if nothing to do
  local branch="$1" source="$2"
  dir="$(branch_dir "$branch")" || exit 1
  if git -C "$dir" merge-base --is-ancestor "$source" HEAD; then
    echo "$branch: already contains $source"
    return 1
  fi
  echo "$branch: merging $source"
  if ! git -C "$dir" merge --no-ff --no-edit -m "Merge $source ($(git rev-parse --short "$source")) into $branch" "$source"; then
    echo
    echo "Conflict merging $source into $branch (in $dir)."
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
  if merge_into "$branch" "$base"; then check "$branch" "$dir"; fi
done

changed=0
merge_into main upstream/main && changed=1
for entry in "${FEATURES[@]}"; do
  merge_into main "${entry%%:*}" && changed=1
done
if [[ $changed == 1 ]]; then main_dir="$(branch_dir main)" || exit 1; check main "$main_dir"; fi

git switch -q "$start_branch"
echo
echo "Done: main and ${branches[*]} contain upstream $upstream_head."
echo "Publish with: git push origin main ${branches[*]}"
