#!/usr/bin/env bash
# tests/fm-zentre-workflow-sonar.test.sh - narrow sonar-gate bridge safety rules.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-zentre-workflow-sonar.sh"
TMP_ROOT=$(fm_test_tmproot fm-zentre-workflow-sonar-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SOURCE="$TMP_ROOT/source"
REPORT="$TMP_ROOT/reports/sonar.txt"
mkdir -p "$SOURCE"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name test
printf 'base\n' > "$SOURCE/source.txt"
git -C "$SOURCE" add source.txt
git -C "$SOURCE" commit -qm base
SHA=$(git -C "$SOURCE" rev-parse HEAD)

cat > "$FAKEBIN/sonar-gate" <<'SH'
#!/usr/bin/env bash
case "$1" in
  enabled) exit "${FM_TEST_ENABLED_STATUS:-0}" ;;
  setup) exit "${FM_TEST_SETUP_STATUS:-0}" ;;
  check) printf 'gate result\n'; exit "${FM_TEST_CHECK_STATUS:-0}" ;;
  *) exit 91 ;;
esac
SH
chmod +x "$FAKEBIN/sonar-gate"

run_sonar() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" --source-dir "$SOURCE" --expected-sha "$SHA" --report "$REPORT" "$@"
}

test_baseline_and_candidate_results() {
  local status=0
  FM_TEST_CHECK_STATUS=30 run_sonar --phase baseline || status=$?
  [ "$status" -eq 30 ] || fail "baseline did not preserve sonar-gate baseline status"
  [ -f "$REPORT" ] || fail "baseline report was not retained"
  grep -Fqx 'phase=baseline' "$REPORT" || fail "report did not retain phase evidence"
  status=0
  FM_TEST_CHECK_STATUS=30 run_sonar --phase candidate >/dev/null 2>&1 || status=$?
  [ "$status" -eq 3 ] || fail "candidate baseline was accepted"
  status=0
  FM_TEST_CHECK_STATUS=0 run_sonar --phase candidate || status=$?
  [ "$status" -eq 0 ] || fail "candidate pass was refused"
  pass "zentre-workflow Sonar bridge distinguishes a baseline from a candidate pass and persists reports"
}

test_disposable_and_revision_refuse() {
  local status=0
  run_sonar --phase baseline --mode disposable >/dev/null 2>&1 || status=$?
  [ "$status" -eq 3 ] || fail "unsupported disposable Sonar mode did not refuse"
  status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" --phase baseline --source-dir "$SOURCE" --expected-sha deadbeef --report "$REPORT" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 3 ] || fail "wrong source revision did not refuse before scanning"
  pass "zentre-workflow Sonar bridge refuses unsupported disposable lifecycle and mismatched source revisions"
}

test_baseline_and_candidate_results
test_disposable_and_revision_refuse

echo '# fm-zentre-workflow-sonar.test.sh: all assertions passed'
