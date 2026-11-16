# shellcheck shell=bash
# Shared task-branch naming for firstmate delivery.
# Usage: . bin/fm-branch-lib.sh
#
# A new task branch is `<type>/<slug>`. AGENTS.md section 7 owns the decision;
# this library owns the accepted types, slug derivation, and validation.
#
# The nine conventional prefixes are accepted for writes. Historical `fix`,
# `feat`, `patch`, and `fm` branches remain discoverable for existing tasks.
#
# No side effects on source. set -u / set -e safe.

# Prefixes this fleet creates, and the wider set it still reads.
FM_BRANCH_PREFIXES="feature bugfix hotfix release chore refactor docs test ci"
FM_BRANCH_READ_PREFIXES="feature bugfix hotfix release chore refactor docs test ci fix feat patch fm"
FM_BRANCH_DEFAULT_TYPE="chore"

# True when <prefix> is one this fleet is allowed to create.
fm_branch_type_valid() {
  local candidate=$1 p
  for p in $FM_BRANCH_PREFIXES; do
    [ "$candidate" = "$p" ] && return 0
  done
  return 1
}

# Validate the convention, including the documented maximum of 59 characters.
fm_branch_valid() {
  local branch=$1
  [ "${#branch}" -lt 60 ] || return 1
  case "$branch" in *'..'*|*.lock) return 1 ;; esac
  printf '%s\n' "$branch" | LC_ALL=C grep -Eq '^(feature|bugfix|hotfix|release|chore|refactor|docs|test|ci)/[a-z0-9][a-z0-9/-]*$' \
    && git check-ref-format --branch "$branch" >/dev/null 2>&1
}

# Normalize arbitrary task ids to lowercase kebab-case.
fm_branch_slug() {
  local value
  value=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
  printf '%s\n' "$value"
}

# Derive `<type>/<slug>` and fit the whole ref under 60 characters. Ticket IDs
# are validated before lowercasing and occupy the first slug component.
fm_branch_derive() {
  local id=$1 type=${2:-$FM_BRANCH_DEFAULT_TYPE} ticket=${3:-} slug ticket_prefix="" max_slug
  fm_branch_type_valid "$type" || {
    echo "error: branch type must be one of $FM_BRANCH_PREFIXES (got '$type')" >&2
    return 1
  }
  if [ -n "$ticket" ]; then
    case "$ticket" in
      *[!A-Za-z0-9-]*|[!A-Za-z]*-*)
        echo "error: ticket id must look like ZA-812 (got '$ticket')" >&2
        return 1 ;;
    esac
    printf '%s\n' "$ticket" | LC_ALL=C grep -Eq '^[A-Za-z][A-Za-z0-9]*-[0-9]+$' || {
      echo "error: ticket id must look like ZA-812 (got '$ticket')" >&2
      return 1
    }
    ticket_prefix="$(fm_branch_slug "$ticket")-"
  fi
  slug=$(fm_branch_slug "$id")
  [ -n "$slug" ] || { echo "error: task id cannot produce a branch slug" >&2; return 1; }
  max_slug=$((59 - ${#type} - 1))
  if [ "${#ticket_prefix}" -ge "$max_slug" ]; then
    echo "error: ticket id leaves no room for a task slug in a branch under 60 characters" >&2
    return 1
  fi
  slug="$ticket_prefix$slug"
  if [ "${#slug}" -gt "$max_slug" ]; then
    slug=${slug:0:max_slug}
    slug=${slug%-}
  fi
  [ -n "$slug" ] || { echo "error: branch slug is empty after truncation" >&2; return 1; }
  printf '%s/%s\n' "$type" "$slug"
}

# Resolve a caller-selected type or registered type-prefix override, then
# derive and validate the complete branch name.
fm_branch_resolve_name() {
  local id=$1 type=${2:-$FM_BRANCH_DEFAULT_TYPE} ticket=${3:-} prefix=${4:-} selected
  if [ -n "$prefix" ]; then
    selected=${prefix%/}
    fm_branch_type_valid "$selected" || {
      echo "error: --branch-prefix must be one of the supported branch types with an optional trailing slash (got '$prefix')" >&2
      return 1
    }
    type=$selected
  fi
  fm_branch_derive "$id" "$type" "$ticket" || return 1
}

# Every branch name that could legitimately hold <task-id>'s work, new scheme
# first and the legacy prefix last. For error messages and read-side probing.
fm_branch_candidates() {
  local id=$1 p slug
  slug=$(fm_branch_slug "$id")
  for p in $FM_BRANCH_PREFIXES; do
    printf '%s/%s\n' "$p" "$slug"
  done
  # Legacy task branches used the literal task id.
  for p in $FM_BRANCH_READ_PREFIXES; do
    case "$p" in fix|feat|patch|fm) printf '%s/%s\n' "$p" "$id" ;; esac
  done
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
