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

# Default ship-branch prefix in the `<prefix>/` form the brief, promote, and
# spawn scripts concatenate with a task id (`$BRANCH_PREFIX$ID`).
fm_branch_default_prefix_for_id() {
  printf '%s/\n' "$(fm_branch_prefix_for_id "$1")"
}

# Normalize an explicit --branch-prefix: a bare produced prefix (fix, feat,
# patch) gains its `/`; any other value is a project-registered free-form prefix
# and is kept as given.
fm_branch_normalize_prefix() {
  if fm_branch_prefix_valid "$1"; then
    printf '%s/\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Print the ship branch recorded in a task meta file (`branch=`), if any. The
# recorded value is immutable and wins over every derived name.
fm_branch_recorded() {
  local meta=$1
  [ -f "$meta" ] || return 0
  grep '^branch=' "$meta" 2>/dev/null | head -n 1 | cut -d= -f2- || true
}

# Print the one existing local branch holding <task-id>'s work in the repo at
# <dir>. Order: the branch recorded in <meta> (optional 3rd arg) when present,
# then the prefix scheme (new prefixes first, legacy `fm/` last). Returns 1 when
# none exists, 2 when several prefix-scheme branches do (guessing between two real
# branches would review or merge the wrong work), and 3 when the recorded branch
# is not a valid ref name.
fm_branch_resolve() {
  local dir=$1 id=$2 meta=${3:-} candidate found="" recorded
  recorded=$(fm_branch_recorded "$meta")
  if [ -n "$recorded" ]; then
    if ! git check-ref-format --branch "$recorded" >/dev/null 2>&1; then
      echo "error: task $id has an invalid recorded ship branch '$recorded'" >&2
      return 3
    fi
    git -C "$dir" rev-parse --verify --quiet "refs/heads/$recorded" >/dev/null 2>&1 || return 1
    printf '%s\n' "$recorded"
    return 0
  fi
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

# Print the branch holding <task-id>'s work in the repo at <dir> (optional
# <meta> as in fm_branch_resolve), or fail naming what would have been accepted.
fm_branch_require() {
  local dir=$1 id=$2 meta=${3:-} branch rc=0 recorded
  branch=$(fm_branch_resolve "$dir" "$id" "$meta") || rc=$?
  if [ "$rc" -eq 1 ]; then
    recorded=$(fm_branch_recorded "$meta")
    if [ -n "$recorded" ]; then
      echo "error: branch $recorded does not exist in $dir" >&2
    else
      echo "error: no branch for task $id in $dir; expected one of $(fm_branch_candidates "$id" | tr '\n' ' ')" >&2
    fi
  fi
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$branch"
}
