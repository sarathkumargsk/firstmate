#!/usr/bin/env bash
# Tests for bin/fm-branch-lib.sh: the task-branch naming contract in AGENTS.md
# section 7. The properties that matter are that the legacy `fm/` prefix is never
# PRODUCED, that it is still READ, and that a repo holding two candidate branches
# for one task is refused rather than guessed between.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-branch-lib.sh
. "$ROOT/bin/fm-branch-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-lib-tests)

make_repo() {
  local name=$1 repo
  repo="$TMP_ROOT/$name"
  fm_git_init_commit "$repo"
  printf '%s\n' "$repo"
}

test_prefix_set_excludes_legacy() {
  fm_branch_prefix_valid fix || fail "fix must be a producible prefix"
  fm_branch_prefix_valid feat || fail "feat must be a producible prefix"
  fm_branch_prefix_valid patch || fail "patch must be a producible prefix"
  ! fm_branch_prefix_valid fm || fail "fm must never be producible"
  ! fm_branch_prefix_valid chore || fail "chore is outside the closed prefix set"
  ! fm_branch_prefix_valid '' || fail "an empty prefix must be refused"
  pass "fm-branch-lib produces only fix/feat/patch and never the legacy fm prefix"
}

test_prefix_derived_from_task_id() {
  local p
  p=$(fm_branch_prefix_for_id fix-login-crash)
  [ "$p" = fix ] || fail "fix-* id should derive fix, got '$p'"
  p=$(fm_branch_prefix_for_id feat-new-thing)
  [ "$p" = feat ] || fail "feat-* id should derive feat, got '$p'"
  p=$(fm_branch_prefix_for_id patch-typo)
  [ "$p" = patch ] || fail "patch-* id should derive patch, got '$p'"
  pass "fm-branch-lib derives the prefix from a task id that already names its kind"
}

test_unsignalled_id_still_gets_a_conventional_prefix() {
  local p
  for p in something-else feature-flag fixture-cleanup fm-legacy-looking ''; do
    p=$(fm_branch_prefix_for_id "$p")
    [ "$p" != fm ] || fail "an unsignalled id must never fall back to fm"
    fm_branch_prefix_valid "$p" || fail "derived prefix '$p' is not in the produced set"
  done
  p=$(fm_branch_prefix_for_id something-else)
  [ "$p" = "$FM_BRANCH_DEFAULT_PREFIX" ] || fail "unsignalled id should take the default prefix"
  pass "fm-branch-lib gives an unsignalled task id a conventional prefix, never fm"
}

test_branch_name_shape() {
  local n
  n=$(fm_branch_name feat my-task)
  [ "$n" = feat/my-task ] || fail "branch name should be <prefix>/<id>, got '$n'"
  pass "fm-branch-lib composes <prefix>/<task-id>"
}

test_resolve_finds_new_scheme_branch() {
  local repo out
  repo=$(make_repo resolve-new)
  git -C "$repo" branch feat/task-a
  out=$(fm_branch_resolve "$repo" task-a) || fail "resolve should find feat/task-a"
  [ "$out" = feat/task-a ] || fail "resolve returned '$out'"
  pass "fm-branch-lib resolves a new-scheme task branch"
}

test_resolve_still_finds_legacy_branch() {
  local repo out
  repo=$(make_repo resolve-legacy)
  git -C "$repo" branch fm/task-b
  out=$(fm_branch_resolve "$repo" task-b) || fail "resolve must still read a legacy fm/ branch"
  [ "$out" = fm/task-b ] || fail "resolve returned '$out'"
  pass "fm-branch-lib still reads an in-flight legacy fm/ branch"
}

test_resolve_reports_absence_without_output() {
  local repo out rc=0
  repo=$(make_repo resolve-none)
  out=$(fm_branch_resolve "$repo" task-c 2>&1) || rc=$?
  expect_code 1 "$rc" "resolve with no candidate branch"
  [ -z "$out" ] || fail "resolve should stay quiet on absence, printed: $out"
  pass "fm-branch-lib reports a missing task branch without inventing one"
}

test_resolve_refuses_two_candidates() {
  local repo out rc=0
  repo=$(make_repo resolve-ambiguous)
  git -C "$repo" branch fm/task-d
  git -C "$repo" branch fix/task-d
  out=$(fm_branch_resolve "$repo" task-d 2>&1) || rc=$?
  expect_code 2 "$rc" "resolve with a legacy and a new branch for one task"
  assert_contains "$out" 'multiple branches' "ambiguity must be named, not guessed between"
  pass "fm-branch-lib refuses to guess between two branches for one task"
}

test_require_names_every_accepted_branch() {
  local repo out rc=0
  repo=$(make_repo require-none)
  out=$(fm_branch_require "$repo" task-e 2>&1) || rc=$?
  expect_code 1 "$rc" "require with no candidate branch"
  assert_contains "$out" 'fix/task-e' "require should name the new-scheme candidates"
  assert_contains "$out" 'feat/task-e' "require should name the new-scheme candidates"
  assert_contains "$out" 'patch/task-e' "require should name the new-scheme candidates"
  assert_contains "$out" 'fm/task-e' "require should name the legacy candidate too"
  pass "fm-branch-lib names every accepted branch name when none exists"
}

test_prefix_set_excludes_legacy
test_prefix_derived_from_task_id
test_unsignalled_id_still_gets_a_conventional_prefix
test_branch_name_shape
test_resolve_finds_new_scheme_branch
test_resolve_still_finds_legacy_branch
test_resolve_reports_absence_without_output
test_resolve_refuses_two_candidates
test_require_names_every_accepted_branch
