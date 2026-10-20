#!/usr/bin/env bash
# fm-zentre-workflow-sonar.sh - narrow non-secret bridge to the installed sonar-gate interface.
#
# Usage:
#   fm-zentre-workflow-sonar.sh --phase baseline|candidate --source-dir <dir> \
#       --expected-sha <sha> --report <path> [--mode standard|disposable]
#
# This command is not a SonarQube client. It verifies that the separately
# materialized source matches the workflow checkpoint, then calls sonar-gate
# enabled, setup, and check. It persists the command output before returning
# the check result. Credentials, scanner invocation, exclusions, and quality
# gate evaluation remain exclusively owned by sonar-gate and its Vault launcher.
#
# The installed sonar-gate interface has no temporary-project key, source-ref,
# report-export, or deletion API. Therefore --mode disposable refuses rather
# than pretending ordinary project analysis is ticket-isolated. A future narrow
# sonar-gate disposable adapter must own that lifecycle. This bridge never
# deletes resources and never treats exit 30 (baseline) as candidate success.
set -u

die() { printf 'fm-zentre-workflow-sonar: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'fm-zentre-workflow-sonar: refused: %s\n' "$*" >&2; exit 3; }
usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" >&2; exit 2; }

safe_value() {
  case "$1" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|*[[:cntrl:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

PHASE='' SOURCE='' EXPECTED_SHA='' REPORT='' MODE=standard
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase) PHASE=${2:-}; shift 2 ;;
    --source-dir) SOURCE=${2:-}; shift 2 ;;
    --expected-sha) EXPECTED_SHA=${2:-}; shift 2 ;;
    --report) REPORT=${2:-}; shift 2 ;;
    --mode) MODE=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument $1" ;;
  esac
done

case "$PHASE" in baseline|candidate) ;; *) die "--phase must be baseline or candidate" ;; esac
case "$MODE" in standard|disposable) ;; *) die "--mode must be standard or disposable" ;; esac
case "$EXPECTED_SHA" in ''|*[!A-Fa-f0-9]*) die "--expected-sha must be hexadecimal" ;; esac
if ! safe_value "$SOURCE" || ! safe_value "$REPORT"; then
  die "source and report paths must be safe single-line values"
fi
[ -d "$SOURCE" ] || refuse "source directory is unavailable: $SOURCE"
[ ! -L "$REPORT" ] || refuse "report path must not be a symlink"

if [ "$MODE" = disposable ]; then
  refuse "the installed sonar-gate has no disposable-project interface; retain the execution and add a narrow sonar-gate adapter before ticket-isolated scans"
fi

observed=$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null) \
  || refuse "source directory is not a readable Git revision: $SOURCE"
[ "$observed" = "$EXPECTED_SHA" ] \
  || refuse "source revision does not match expected workflow revision"
command -v sonar-gate >/dev/null 2>&1 || die "sonar-gate is required"

report_dir=$(dirname "$REPORT")
mkdir -p "$report_dir" || die "could not create report directory"
tmp=$(umask 077; mktemp "$report_dir/.sonar.XXXXXX") || die "could not create report"
trap 'rm -f "$tmp"' EXIT INT TERM

{
  printf 'schema=zentre-workflow-sonar.v1\n'
  printf 'phase=%s\nsource=%s\nsha=%s\n' "$PHASE" "$SOURCE" "$observed"
  printf '%s\n' '--- sonar-gate enabled ---'
  sonar-gate enabled "$SOURCE"
} > "$tmp" 2>&1
enabled_status=$?
case "$enabled_status" in
  0) ;;
  10|20)
    mv -f "$tmp" "$REPORT" || die "could not preserve Sonar admission report"
    trap - EXIT INT TERM
    exit "$enabled_status"
    ;;
  *)
    mv -f "$tmp" "$REPORT" || die "could not preserve Sonar admission failure"
    trap - EXIT INT TERM
    exit 2
    ;;
esac

{
  printf '%s\n' '--- sonar-gate setup ---'
  sonar-gate setup "$SOURCE"
} >> "$tmp" 2>&1
setup_status=$?
if [ "$setup_status" -ne 0 ]; then
  mv -f "$tmp" "$REPORT" || die "could not preserve Sonar setup failure"
  trap - EXIT INT TERM
  exit 2
fi

{
  printf '%s\n' '--- sonar-gate check ---'
  sonar-gate check "$SOURCE"
} >> "$tmp" 2>&1
check_status=$?
mv -f "$tmp" "$REPORT" || die "could not preserve Sonar report"
trap - EXIT INT TERM

case "$PHASE:$check_status" in
  baseline:30) exit 30 ;;
  candidate:0) exit 0 ;;
  baseline:0) refuse "baseline must report sonar-gate exit 30, never a passing candidate gate" ;;
  candidate:30) refuse "candidate reported a baseline, not a quality-gate pass" ;;
  *:1|*:2|*:10|*:20) exit "$check_status" ;;
  *) die "sonar-gate returned unsupported status $check_status" ;;
esac
