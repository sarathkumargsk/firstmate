#!/usr/bin/env bash
# Tests for branch derivation, validation, and legacy branch reads.
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

test_derivation_validation_and_override() {
  local n
  n=$(fm_branch_resolve_name 'TASK ID-With__Punctuation')
  [ "$n" = chore/task-id-with-punctuation ] || fail "no-type default or normalization failed: '$n'"
  n=$(fm_branch_resolve_name task-482 bugfix ZA-812)
  [ "$n" = bugfix/za-812-task-482 ] || fail "ticket placement failed: '$n'"
  n=$(fm_branch_resolve_name task-482 chore ZA-812 bugfix/)
  [ "$n" = bugfix/za-812-task-482 ] || fail "registry type override failed: '$n'"
  n=$(fm_branch_resolve_name "$(printf 'x%.0s' {1..90})" feature)
  [ "${#n}" -eq 59 ] || fail "branch should truncate to 59 chars, got ${#n}"
  fm_branch_valid "$n" || fail "derived branch should pass validation"
  for n in fm/task chore/has..dots chore/end.lock chore/Upper "chore/$(printf 'x%.0s' {1..54})"; do
    ! fm_branch_valid "$n" || fail "invalid branch should be refused: $n"
  done
  ! fm_branch_resolve_name task unsupported >/dev/null 2>&1 || fail "unknown type was accepted"
  ! fm_branch_resolve_name task chore 'bad ticket' >/dev/null 2>&1 || fail "malformed ticket was accepted"
  pass "fm-branch-lib derives, truncates, overrides, and validates convention branch names"
}

test_resolve_finds_new_scheme_branch() {
  local repo out
  repo=$(make_repo resolve-new)
  git -C "$repo" branch feature/task-a
  out=$(fm_branch_resolve "$repo" task-a) || fail "resolve should find feature/task-a"
  [ "$out" = feature/task-a ] || fail "resolve returned '$out'"
  pass "fm-branch-lib resolves a convention branch"
}

test_resolve_still_finds_legacy_branch() {
  local repo out
  repo=$(make_repo resolve-legacy)
  git -C "$repo" branch fm/task-b
  out=$(fm_branch_resolve "$repo" task-b) || fail "resolve must still find legacy fm/ branch"
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
  git -C "$repo" branch feature/task-d
  out=$(fm_branch_resolve "$repo" task-d 2>&1) || rc=$?
  expect_code 2 "$rc" "resolve with a legacy and a new branch for one task"
  assert_contains "$out" 'multiple branches' "ambiguity must be named, not guessed between"
  pass "fm-branch-lib refuses to guess between two task branches"
}

test_recorded_branch_wins() {
  local repo meta out
  repo=$(make_repo recorded)
  git -C "$repo" branch fm/task-e
  meta="$TMP_ROOT/task.meta"
  printf 'branch=docs/task-e\n' > "$meta"
  git -C "$repo" branch docs/task-e
  out=$(fm_branch_resolve "$repo" task-e "$meta") || fail "recorded branch should resolve"
  [ "$out" = docs/task-e ] || fail "recorded branch lost to candidate scan: '$out'"
  pass "fm-branch-lib preserves recorded branch identity"
}

test_derivation_validation_and_override
test_resolve_finds_new_scheme_branch
test_resolve_still_finds_legacy_branch
test_resolve_reports_absence_without_output
test_resolve_refuses_two_candidates
test_recorded_branch_wins

echo "# fm-branch-lib.test.sh: all assertions passed"
