# shellcheck shell=bash
# Shared task-branch naming for firstmate delivery.
# Usage: . bin/fm-branch-lib.sh
#
# A task branch is `<prefix>/<task-id>`. AGENTS.md section 7 owns the contract
# (which prefix means what, and who decides it); this library is the single
# implementation of it, so generators and readers cannot drift apart.
#
# Produced prefixes are a closed set: fix, feat, patch. The legacy `fm` prefix is
# accepted on READ only, so branches created before the scheme changed keep
# working; nothing here ever produces it.
#
# No side effects on source. set -u / set -e safe.

# Prefixes this fleet creates, and the wider set it still reads.
FM_BRANCH_PREFIXES="fix feat patch"
FM_BRANCH_READ_PREFIXES="fix feat patch fm"
# Used when a caller supplies no prefix and the task id carries no signal: the
# smallest claim a branch can make, never the legacy prefix.
FM_BRANCH_DEFAULT_PREFIX="patch"

# True when <prefix> is one this fleet is allowed to create.
fm_branch_prefix_valid() {
  local candidate=$1 p
  for p in $FM_BRANCH_PREFIXES; do
    [ "$candidate" = "$p" ] && return 0
  done
  return 1
}

# Mechanical prefix for <task-id>: a task id already opening with one of the
# produced prefixes names its own kind, otherwise fall back to the default.
fm_branch_prefix_for_id() {
  local id=$1 p
  for p in $FM_BRANCH_PREFIXES; do
    case "$id" in
      "$p"-*) printf '%s\n' "$p"; return 0 ;;
    esac
  done
  printf '%s\n' "$FM_BRANCH_DEFAULT_PREFIX"
}

fm_branch_name() {
  printf '%s/%s\n' "$1" "$2"
}

# Every branch name that could legitimately hold <task-id>'s work, new scheme
# first and the legacy prefix last. For error messages and read-side probing.
fm_branch_candidates() {
  local id=$1 p
  for p in $FM_BRANCH_READ_PREFIXES; do
    printf '%s/%s\n' "$p" "$id"
  done
}

# Print the one existing local branch holding <task-id>'s work in the repo at
# <dir>. Returns 1 when none exists and 2 when several do, because guessing
# between two real branches would review or merge the wrong work.
fm_branch_resolve() {
  local dir=$1 id=$2 candidate found=""
  while IFS= read -r candidate; do
    git -C "$dir" rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null 2>&1 || continue
    if [ -n "$found" ]; then
      echo "error: task $id has multiple branches in $dir ($found and $candidate); resolve the duplicate before continuing" >&2
      return 2
    fi
    found=$candidate
  done <<EOF
$(fm_branch_candidates "$id")
EOF
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Print the branch holding <task-id>'s work in the repo at <dir>, or fail after
# naming every branch name that would have been accepted.
fm_branch_require() {
  local dir=$1 id=$2 branch rc=0
  branch=$(fm_branch_resolve "$dir" "$id") || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "error: no branch for task $id in $dir; expected one of $(fm_branch_candidates "$id" | tr '\n' ' ')" >&2
  fi
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$branch"
}
