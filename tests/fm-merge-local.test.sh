#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh branch discovery: the approved local landing
# must find the ready branch under the current naming scheme, must still land an
# in-flight legacy `fm/` branch, and must refuse rather than pick when a task has
# both.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# A project on main with one ready commit on <branch>, and a local-only task meta.
make_case() {
  local name=$1 branch=$2 case_dir proj
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state"
  touch "$case_dir/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  git -C "$proj" branch -m main 2>/dev/null || true
  git -C "$proj" checkout -q -b "$branch"
  printf 'ready\n' > "$proj/ready.txt"
  git -C "$proj" add ready.txt
  git -C "$proj" commit -qm "ready work"
  git -C "$proj" checkout -q main
  fm_write_meta "$case_dir/state/task-m1.meta" \
    "project=$proj" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

test_lands_new_scheme_branch() {
  local case_dir out
  case_dir=$(make_case new-scheme feat/task-m1)
  out=$(run_merge_local "$case_dir" task-m1 2>&1) || fail "new-scheme: merge should succeed: $out"
  assert_contains "$out" 'merged feat/task-m1 into local main' "new-scheme: should land the feat/ branch"
  [ -f "$case_dir/project/ready.txt" ] || fail "new-scheme: main should carry the ready work"
  pass "fm-merge-local lands a new-scheme task branch"
}

test_lands_legacy_branch() {
  local case_dir out
  case_dir=$(make_case legacy fm/task-m1)
  out=$(run_merge_local "$case_dir" task-m1 2>&1) || fail "legacy: merge should succeed: $out"
  assert_contains "$out" 'merged fm/task-m1 into local main' "legacy: an in-flight fm/ branch must still land"
  [ -f "$case_dir/project/ready.txt" ] || fail "legacy: main should carry the ready work"
  pass "fm-merge-local still lands an in-flight legacy fm/ branch"
}

test_missing_branch_names_accepted_shapes() {
  local case_dir out rc=0
  case_dir=$(make_case missing feat/unrelated-branch)
  out=$(run_merge_local "$case_dir" task-m1 2>&1) || rc=$?
  expect_code 1 "$rc" "missing: merge must refuse"
  assert_contains "$out" 'feat/task-m1' "missing: error should name the new-scheme candidates"
  assert_contains "$out" 'fm/task-m1' "missing: error should name the legacy candidate"
  pass "fm-merge-local refuses and names every accepted branch when none exists"
}

test_two_candidates_are_refused() {
  local case_dir out rc=0
  case_dir=$(make_case ambiguous feat/task-m1)
  git -C "$case_dir/project" branch fm/task-m1
  out=$(run_merge_local "$case_dir" task-m1 2>&1) || rc=$?
  expect_code 1 "$rc" "ambiguous: merge must refuse"
  assert_contains "$out" 'multiple branches' "ambiguous: the duplicate must be named"
  assert_not_contains "$out" 'merged ' "ambiguous: nothing may be landed"
  pass "fm-merge-local refuses a task with both a new-scheme and a legacy branch"
}

test_lands_new_scheme_branch
test_lands_legacy_branch
test_missing_branch_names_accepted_shapes
test_two_candidates_are_refused
