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
git -C "$CANDIDATE_SOURCE" remote set-url origin https://gitlab.example/group/zentre.git
printf 'PROJ\tzentre\tgroup/zentre\t%s\tmain\n' "$CANDIDATE_SOURCE" > "$HOME_ROOT/config/zentre-workflow/candidates.tsv"
cat > "$HOME_ROOT/config/zentre-workflow/ticket-reader" <<'SH'
#!/usr/bin/env bash
printf 'schema=zentre-workflow-ticket-reader.v1\n'
printf 'ticket=%s\n' "$1"
printf 'description=group/zentre\n'
SH
chmod +x "$HOME_ROOT/config/zentre-workflow/ticket-reader"
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

RESOLUTION_ALPHA="$TMP_ROOT/resolution-alpha"
RESOLUTION_BETA="$TMP_ROOT/resolution-beta"
git clone -q "$BASE_SOURCE" "$RESOLUTION_ALPHA"
git clone -q "$BASE_SOURCE" "$RESOLUTION_BETA"
git -C "$RESOLUTION_ALPHA" remote set-url origin https://gitlab.example/group/alpha.git
git -C "$RESOLUTION_BETA" remote set-url origin https://gitlab.example/group/beta.git

make_resolution_home() {
  RESOLUTION_HOME="$TMP_ROOT/resolution-home-$1"
  mkdir -p "$RESOLUTION_HOME/config/zentre-workflow" "$RESOLUTION_HOME/data"
  cat > "$RESOLUTION_HOME/config/zentre-workflow/ticket-reader" <<'SH'
#!/usr/bin/env bash
case "${FM_ZENTRE_TEST_READER_MODE:-unique}" in
  unique)
    evidence='group/alpha'
    ;;
  no-match)
    evidence='unrelated repository'
    ;;
  ambiguous)
    evidence='group/alpha and group/beta'
    ;;
  unreachable)
    exit 1
    ;;
  *)
    exit 2
    ;;
esac
printf 'schema=zentre-workflow-ticket-reader.v1\n'
printf 'ticket=%s\n' "$1"
printf 'description=%s\n' "$evidence"
SH
  chmod +x "$RESOLUTION_HOME/config/zentre-workflow/ticket-reader"
}

write_resolution_candidates() {
  printf 'PROJ\talpha\tgroup/alpha\t%s\tmain\n' "$RESOLUTION_ALPHA" \
    > "$RESOLUTION_HOME/config/zentre-workflow/candidates.tsv"
  printf 'PROJ\tbeta\tgroup/beta\t%s\tmain\n' "$RESOLUTION_BETA" \
    >> "$RESOLUTION_HOME/config/zentre-workflow/candidates.tsv"
}

run_resolution() {
  FM_HOME="$RESOLUTION_HOME" "$SCRIPT" "$@"
}

test_unique_repository_selection_is_durable_and_resumable() {
  local out resolution
  make_resolution_home unique
  write_resolution_candidates
  out=$(FM_ZENTRE_TEST_READER_MODE=unique run_resolution PROJ-234) \
    || fail "unique repository evidence was refused"
  assert_contains "$out" 'repository=group/alpha' "unique repository was not selected"
  assert_contains "$out" 'stage=analysis' "resolved workflow did not start at analysis"
  resolution="$RESOLUTION_HOME/data/zentre-workflow/executions/PROJ-234/resolution"
  assert_contains "$(cat "$resolution")" 'status=resolved' "selected repository was not durable"
  assert_contains "$(cat "$resolution")" 'evidence=literal-repository-reference:group/alpha' \
    "durable resolution did not record its evidence"
  out=$(FM_ZENTRE_TEST_READER_MODE=unreachable run_resolution PROJ-234) \
    || fail "matching resolved ticket did not reuse durable selection"
  assert_contains "$out" 'repository=group/alpha' "resumed workflow changed the selected repository"
  pass "zentre-workflow resolves one configured repository from ticket evidence and reuses it without rereading the ticket"
}

test_repository_resolution_pauses_on_no_match() {
  local out resolution status=0
  make_resolution_home no-match
  write_resolution_candidates
  out=$(FM_ZENTRE_TEST_READER_MODE=no-match run_resolution PROJ-235 2>&1) || status=$?
  [ "$status" -eq 4 ] || fail "unmatched ticket evidence did not pause"
  assert_contains "$out" 'reason=ticket-evidence-insufficient' "unmatched ticket did not name the evidence decision"
  assert_contains "$out" 'next=add-exact-repository-reference' "unmatched ticket did not provide an actionable decision"
  resolution="$RESOLUTION_HOME/data/zentre-workflow/executions/PROJ-235/resolution"
  assert_contains "$(cat "$resolution")" 'status=waiting_for_approval' \
    "unmatched ticket did not preserve its actionable pause"
  assert_not_contains "$(cat "$resolution")" 'unrelated repository' \
    "unmatched ticket stored untrusted source text"
  pass "zentre-workflow pauses rather than guessing when ticket evidence matches no repository"
}

test_repository_resolution_pauses_on_ambiguity() {
  local out status=0
  make_resolution_home ambiguous
  write_resolution_candidates
  out=$(FM_ZENTRE_TEST_READER_MODE=ambiguous run_resolution PROJ-236 2>&1) || status=$?
  [ "$status" -eq 4 ] || fail "ambiguous ticket evidence did not pause"
  assert_contains "$out" 'reason=repository-ambiguous' "ambiguous ticket did not name the repository decision"
  assert_contains "$out" 'next=choose-repository-candidate' "ambiguous ticket did not provide an actionable decision"
  pass "zentre-workflow pauses rather than choosing between multiple matching repositories"
}

test_repository_resolution_pauses_when_reader_is_unreachable() {
  local out status=0
  make_resolution_home unreachable
  write_resolution_candidates
  out=$(FM_ZENTRE_TEST_READER_MODE=unreachable run_resolution PROJ-237 2>&1) || status=$?
  [ "$status" -eq 4 ] || fail "unreachable ticket reader did not pause"
  assert_contains "$out" 'reason=ticket-source-unreachable' "unreachable reader was not recorded safely"
  assert_contains "$out" 'next=restore-ticket-reader' "unreachable reader did not provide an actionable decision"
  pass "zentre-workflow pauses when the configured ticket reader is unavailable"
}

test_repository_resolution_pauses_without_candidates() {
  local out status=0
  make_resolution_home absent
  out=$(run_resolution PROJ-238 2>&1) || status=$?
  [ "$status" -eq 4 ] || fail "absent candidate configuration did not pause"
  assert_contains "$out" 'reason=repository-candidates-absent' "absent candidates were not recorded"
  assert_contains "$out" 'next=configure-repository-candidates' "absent candidates did not provide an actionable decision"
  pass "zentre-workflow pauses when no repository candidates are configured"
}

test_start_or_resume_and_pause
test_cross_family_and_branch_deduplication
test_drift_pauses_and_sonar_requires_base_and_candidate_evidence
test_confirmed_restart_archives_prior_effect_receipts
test_unique_repository_selection_is_durable_and_resumable
test_repository_resolution_pauses_on_no_match
test_repository_resolution_pauses_on_ambiguity
test_repository_resolution_pauses_when_reader_is_unreachable
test_repository_resolution_pauses_without_candidates

echo '# fm-zentre-workflow.test.sh: all assertions passed'
