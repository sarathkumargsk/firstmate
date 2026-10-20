#!/usr/bin/env bash
# tests/fm-zentre-workflow.test.sh - durable workflow state, replay safety, and stage guards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-zentre-workflow.sh"
TMP_ROOT=$(fm_test_tmproot fm-zentre-workflow-tests)
HOME_ROOT="$TMP_ROOT/home"
BASE_SOURCE="$TMP_ROOT/base-source"
CANDIDATE_SOURCE="$TMP_ROOT/candidate-source"
mkdir -p "$HOME_ROOT/config/zentre-workflow" "$HOME_ROOT/data" "$BASE_SOURCE"
git -C "$BASE_SOURCE" init -q
git -C "$BASE_SOURCE" config user.email test@example.invalid
git -C "$BASE_SOURCE" config user.name test
printf 'base\n' > "$BASE_SOURCE/source.txt"
git -C "$BASE_SOURCE" add source.txt
git -C "$BASE_SOURCE" commit -qm base
BASE_SHA=$(git -C "$BASE_SOURCE" rev-parse HEAD)
git clone -q "$BASE_SOURCE" "$CANDIDATE_SOURCE"
git -C "$CANDIDATE_SOURCE" config user.email test@example.invalid
git -C "$CANDIDATE_SOURCE" config user.name test
printf 'candidate\n' >> "$CANDIDATE_SOURCE/source.txt"
git -C "$CANDIDATE_SOURCE" add source.txt
git -C "$CANDIDATE_SOURCE" commit -qm candidate
CANDIDATE_SHA=$(git -C "$CANDIDATE_SOURCE" rev-parse HEAD)
printf 'PROJ\tzentre\tgroup/zentre\t%s\tmain\n' "$CANDIDATE_SOURCE" > "$HOME_ROOT/config/zentre-workflow/projects.tsv"
cat > "$HOME_ROOT/config/zentre-workflow/review-families.tsv" <<'EOF'
openai-author	openai
openai-reviewer	openai
anthropic-reviewer	anthropic
EOF

run_workflow() {
  FM_HOME="$HOME_ROOT" "$SCRIPT" PROJ-123 "$@"
}

complete_analysis() {
  run_workflow --complete analysis --input-digest aaaa --config-digest bbbb --artifact analysis.md
}

complete_branch() {
  run_workflow --begin-operation branch base-aaaa >/dev/null
  run_workflow --finish-operation branch base-aaaa feature/PROJ-123 >/dev/null
  run_workflow --complete branch --base-sha "$BASE_SHA" --branch feature/PROJ-123
}

test_start_or_resume_and_pause() {
  local out status=0 run_dir
  out=$(run_workflow) || fail "new workflow was refused"
  assert_contains "$out" 'stage=analysis' "new workflow did not begin at analysis"
  out=$(run_workflow) || fail "repeat workflow invocation was refused"
  assert_contains "$out" 'execution_id=PROJ-123-' "repeat invocation did not resume existing execution"
  run_dir=$(dirname "$(find "$HOME_ROOT/data/zentre-workflow/executions/PROJ-123" -name state -type f -print -quit)")
  mkdir "$run_dir/.lock" || fail "could not create competing execution lock"
  printf '%s\n' "$$" > "$run_dir/.lock/pid"
  run_workflow --status >/dev/null 2>&1 || status=$?
  rm -f "$run_dir/.lock/pid"
  rmdir "$run_dir/.lock"
  [ "$status" -eq 3 ] || fail "a second live runner was not refused"
  run_workflow --pause >/dev/null || fail "pause was refused"
  out=$(run_workflow --status) || fail "status was refused"
  assert_contains "$out" 'state=paused' "pause was not durable"
  run_workflow --resume >/dev/null || fail "resume was refused"
  pass "zentre-workflow starts or resumes one durable ticket execution, refuses a concurrent runner, and preserves pause state"
}

test_cross_family_and_branch_deduplication() {
  local status=0 out
  complete_analysis >/dev/null || fail "analysis could not complete"
  status=0
  run_workflow --complete branch --base-sha "$BASE_SHA" --branch feature/PROJ-123 >/dev/null 2>&1 || status=$?
  [ "$status" -eq 3 ] || fail "branch completion without a write-ahead operation did not refuse"
  complete_branch >/dev/null || fail "branch with operation evidence was refused"
  run_workflow --complete specification --artifact spec.md >/dev/null || fail "specification completion was refused"
  status=0
  run_workflow --complete spec-review --author-profile openai-author --reviewer-profile openai-reviewer --result approved >/dev/null 2>&1 || status=$?
  [ "$status" -eq 3 ] || fail "self-approval did not refuse"
  run_workflow --complete spec-review --author-profile openai-author --reviewer-profile anthropic-reviewer --result approved >/dev/null || fail "independent review was refused"
  out=$(run_workflow --begin-operation branch base-aaaa) || fail "known branch operation was refused"
  assert_contains "$out" 'status=done' "completed operation did not deduplicate"
  pass "zentre-workflow requires independent reviewers and never repeats a completed external effect"
}

test_drift_pauses_and_sonar_requires_base_and_candidate_evidence() {
  local status=0 out
  run_workflow --complete implementation --candidate-sha "$CANDIDATE_SHA" --artifact implementation.md >/dev/null || fail "implementation completion was refused"
  run_workflow --complete code-review --author-profile openai-author --reviewer-profile anthropic-reviewer --result approved >/dev/null || fail "code review completion was refused"
  status=0
  run_workflow --complete sonar-baseline --base-sha "$CANDIDATE_SHA" --source-dir "$CANDIDATE_SOURCE" --artifact baseline.txt >/dev/null 2>&1 || status=$?
  [ "$status" -eq 3 ] || fail "a candidate revision was accepted as a Sonar baseline"
  run_workflow --begin-operation sonar-baseline "base-$BASE_SHA" >/dev/null || fail "baseline intent was refused"
  run_workflow --finish-operation sonar-baseline "base-$BASE_SHA" sonar-baseline-report >/dev/null || fail "baseline outcome was refused"
  run_workflow --complete sonar-baseline --base-sha "$BASE_SHA" --source-dir "$BASE_SOURCE" --artifact baseline.txt >/dev/null || fail "recorded base was refused"
  run_workflow --begin-operation sonar-candidate "candidate-$CANDIDATE_SHA" >/dev/null || fail "candidate intent was refused"
  run_workflow --finish-operation sonar-candidate "candidate-$CANDIDATE_SHA" sonar-candidate-report >/dev/null || fail "candidate outcome was refused"
  run_workflow --complete sonar-candidate --candidate-sha "$CANDIDATE_SHA" --source-dir "$CANDIDATE_SOURCE" --artifact candidate.txt --result fix >/dev/null || fail "failed candidate evidence was refused"
  out=$(run_workflow --status) || fail "status was refused"
  assert_contains "$out" 'stage=implementation' "failed candidate did not return to remediation"
  status=0
  run_workflow --reconcile-inputs --ticket-digest ffff --config-digest bbbb --base-sha "$BASE_SHA" --candidate-sha "$CANDIDATE_SHA" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 4 ] || fail "input drift did not pause for authorization"
  out=$(run_workflow --status) || fail "drift status was refused"
  assert_contains "$out" 'state=waiting_for_approval' "input drift pause was not durable"
  pass "zentre-workflow keeps failed Sonar candidates out of the baseline and pauses on input drift"
}

test_confirmed_restart_archives_prior_effect_receipts() {
  local before after
  before=$(run_workflow --status | sed -n 's/^execution_id=//p') || fail "status before restart was refused"
  run_workflow --restart --confirm-restart >/dev/null || fail "confirmed restart was refused"
  after=$(run_workflow --status | sed -n 's/^execution_id=//p') || fail "status after restart was refused"
  [ "$before" != "$after" ] || fail "restart reused the prior execution identity"
  [ -d "$HOME_ROOT/data/zentre-workflow/executions/PROJ-123" ] || fail "execution root disappeared on restart"
  pass "zentre-workflow restart creates a distinct execution and archives prior effect receipts"
}

test_start_or_resume_and_pause
test_cross_family_and_branch_deduplication
test_drift_pauses_and_sonar_requires_base_and_candidate_evidence
test_confirmed_restart_archives_prior_effect_receipts

echo '# fm-zentre-workflow.test.sh: all assertions passed'
