#!/usr/bin/env bash
# fm-zentre-workflow.sh - durable start-or-resume state for a ticket delivery workflow.
#
# Usage:
#   fm-zentre-workflow.sh <TICKET> [--status|--resume|--pause|--cancel]
#   fm-zentre-workflow.sh <TICKET> --restart --confirm-restart
#   fm-zentre-workflow.sh <TICKET> --complete <stage> [stage evidence]
#   fm-zentre-workflow.sh <TICKET> --begin-operation <name> <id>
#   fm-zentre-workflow.sh <TICKET> --finish-operation <name> <id> <reference>
#   fm-zentre-workflow.sh <TICKET> --reconcile-operation <name> <id> <reference>
#   fm-zentre-workflow.sh <TICKET> --reconcile-inputs --ticket-digest <digest> \
#       --base-sha <sha> --candidate-sha <sha> --config-digest <digest>
#   Sonar stage completion also needs --source-dir <clean-source-at-recorded-revision>.
#
# Configuration is private, under $FM_HOME/config/zentre-workflow/candidates.tsv.
# Each non-comment row is tab-separated:
#   <ticket-prefix> <project-name> <gitlab-project> <project-directory> <target-branch>
# Multiple candidates may share a ticket prefix.
#
# $FM_HOME/config/zentre-workflow/ticket-reader is a private executable adapter.
# It receives the canonical ticket identifier as its only argument and writes this
# bounded, line-oriented protocol to stdout:
#   schema=zentre-workflow-ticket-reader.v1
#   ticket=PROJ-123
#   title=<single-line untrusted text>
#   description=<single-line untrusted text>
#   comment=<single-line untrusted text>
#   attachment=<single-line untrusted text>
# title and description are optional once each; comment and attachment may repeat.
# The adapter obtains credentials itself and must never emit them.
#
# The command reads ticket evidence only through the private adapter.
# It does not create branches, spawn agents, call GitLab, or invoke SonarQube itself.
# Those operations stay with Firstmate's established agent, model-routing, glab, and
# sonar-gate interfaces. It supplies their durable workflow identity, stage order,
# input evidence, and write-ahead operation records.
# A caller records an operation intent before an external call and its reference
# after success. A repeated intent asks the caller to reconcile rather than repeat
# a possibly successful remote effect.
#
# State lives in $FM_HOME/data/zentre-workflow/executions/. A shared filesystem
# FM_HOME with atomic rename and locking makes it available to another session or
# host. State is
# schema-versioned key/value data, parsed without sourcing and atomically replaced.
# The command never stores secrets. A Sonar completion requires a preserved report,
# a base revision equal to the recorded branch base, and a candidate revision; it
# records baseline and candidate operations separately so a failed candidate cannot
# become a claimed baseline. Temporary Sonar cleanup is intentionally not automated:
# callers must obtain authorization and record it as a separate delivery operation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_FILE="$CONFIG/zentre-workflow/candidates.tsv"
ROOT="$DATA/zentre-workflow/executions"
STATE="$DATA/zentre-workflow"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'fm-zentre-workflow: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'fm-zentre-workflow: refused: %s\n' "$*" >&2; exit 3; }
usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" >&2; exit 2; }

safe_value() {
  case "$1" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|*[[:cntrl:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

safe_text() {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*|*[[:cntrl:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

safe_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

digest_value() {
  case "$1" in
    ''|*[!A-Fa-f0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

ticket_value() {
  [[ "$1" =~ ^[A-Z0-9]+-[1-9][0-9]*$ ]]
}

repository_value() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)+$ ]]
}

branch_value() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}

hash_file() {
  local digest
  digest=$(shasum -a 256 "$1" 2>/dev/null) || die "could not digest private workflow input"
  digest=${digest%% *}
  digest_value "$digest" || die "could not digest private workflow input"
  printf '%s' "$digest"
}

hash_candidate() {
  local digest
  digest=$(printf 'prefix=%s\nproject=%s\nrepository=%s\ndirectory=%s\ntarget=%s\n' \
    "$1" "$2" "$3" "$4" "$5" | shasum -a 256 2>/dev/null) \
    || die "could not digest repository candidate"
  digest=${digest%% *}
  digest_value "$digest" || die "could not digest repository candidate"
  printf '%s' "$digest"
}

hash_metadata() {
  local digest
  digest=$(printf 'repository=%s\nroot=%s\norigin=%s\ntarget=%s\n' \
    "$1" "$2" "$3" "$4" | shasum -a 256 2>/dev/null) \
    || die "could not digest repository metadata"
  digest=${digest%% *}
  digest_value "$digest" || die "could not digest repository metadata"
  printf '%s' "$digest"
}

resolution_get() { # <key>
  local want=$1 key value count=0 result=
  [ -f "$RESOLUTION_FILE" ] && [ ! -L "$RESOLUTION_FILE" ] || return 1
  while IFS='=' read -r key value; do
    [ "$key" = "$want" ] || continue
    count=$((count + 1))
    result=$value
  done < "$RESOLUTION_FILE"
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$result"
}

resolution_read() {
  local key value
  for key in version ticket status reason project repository project_dir target_branch \
    ticket_digest candidate_digest metadata_digest evidence updated_at; do
    value=$(resolution_get "$key") \
      || die "corrupt repository resolution: missing or duplicate $key in $RESOLUTION_FILE"
    safe_text "$value" || die "corrupt repository resolution: unsafe $key in $RESOLUTION_FILE"
    case "$key" in
      version) RESOLUTION_VERSION=$value ;;
      ticket) RESOLUTION_TICKET=$value ;;
      status) RESOLUTION_STATUS=$value ;;
      reason) RESOLUTION_REASON=$value ;;
      project) RESOLUTION_PROJECT=$value ;;
      repository) RESOLUTION_REPOSITORY=$value ;;
      project_dir) RESOLUTION_PROJECT_DIR=$value ;;
      target_branch) RESOLUTION_TARGET_BRANCH=$value ;;
      ticket_digest) RESOLUTION_TICKET_DIGEST=$value ;;
      candidate_digest) RESOLUTION_CANDIDATE_DIGEST=$value ;;
      metadata_digest) RESOLUTION_METADATA_DIGEST=$value ;;
      evidence) RESOLUTION_EVIDENCE=$value ;;
      updated_at) RESOLUTION_UPDATED_AT=$value ;;
    esac
  done
  [ "$RESOLUTION_VERSION" = 1 ] || die "unsupported repository resolution version $RESOLUTION_VERSION"
  [ "$RESOLUTION_TICKET" = "$TICKET" ] \
    || die "repository resolution does not match ticket"
  case "$RESOLUTION_STATUS" in resolved|waiting_for_approval) ;; *) die "corrupt repository resolution status" ;; esac
  if [ "$RESOLUTION_STATUS" = resolved ]; then
    [ "$RESOLUTION_REASON" = resolved ] && safe_name "$RESOLUTION_PROJECT" \
      && repository_value "$RESOLUTION_REPOSITORY" && safe_value "$RESOLUTION_PROJECT_DIR" \
      && branch_value "$RESOLUTION_TARGET_BRANCH" && digest_value "$RESOLUTION_TICKET_DIGEST" \
      && digest_value "$RESOLUTION_CANDIDATE_DIGEST" && digest_value "$RESOLUTION_METADATA_DIGEST" \
      && [ -n "$RESOLUTION_EVIDENCE" ] \
      || die "corrupt resolved repository selection"
  fi
}

resolution_write() {
  local tmp now
  now=$(date +%s) || die "could not read time"
  tmp=$(umask 077; mktemp "$TICKET_ROOT/.resolution.XXXXXX") \
    || die "could not create repository resolution replacement"
  {
    printf 'version=1\n'
    printf 'ticket=%s\n' "$TICKET"
    printf 'status=%s\n' "$RESOLUTION_STATUS"
    printf 'reason=%s\n' "$RESOLUTION_REASON"
    printf 'project=%s\n' "$RESOLUTION_PROJECT"
    printf 'repository=%s\n' "$RESOLUTION_REPOSITORY"
    printf 'project_dir=%s\n' "$RESOLUTION_PROJECT_DIR"
    printf 'target_branch=%s\n' "$RESOLUTION_TARGET_BRANCH"
    printf 'ticket_digest=%s\n' "$RESOLUTION_TICKET_DIGEST"
    printf 'candidate_digest=%s\n' "$RESOLUTION_CANDIDATE_DIGEST"
    printf 'metadata_digest=%s\n' "$RESOLUTION_METADATA_DIGEST"
    printf 'evidence=%s\n' "$RESOLUTION_EVIDENCE"
    printf 'updated_at=%s\n' "$now"
  } > "$tmp" || { rm -f "$tmp"; die "could not write repository resolution replacement"; }
  mv -f "$tmp" "$RESOLUTION_FILE" \
    || { rm -f "$tmp"; die "could not publish repository resolution"; }
  RESOLUTION_UPDATED_AT=$now
}

resolution_next() {
  case "$RESOLUTION_REASON" in
    repository-candidates-absent) printf 'next=configure-repository-candidates\n' ;;
    ticket-source-unreachable) printf 'next=restore-ticket-reader\n' ;;
    ticket-evidence-insufficient) printf 'next=add-exact-repository-reference\n' ;;
    repository-ambiguous) printf 'next=choose-repository-candidate\n' ;;
    repository-metadata-mismatch) printf 'next=repair-repository-metadata\n' ;;
    repository-resolution-drift) printf 'next=confirm-repository-resolution\n' ;;
    *) printf 'next=none\n' ;;
  esac
}

emit_resolution() {
  printf 'ticket=%s\nrepository=%s\nproject=%s\n' \
    "$TICKET" "$RESOLUTION_REPOSITORY" "$RESOLUTION_PROJECT"
  printf 'state=%s\nreason=%s\nevidence=%s\n' \
    "$RESOLUTION_STATUS" "$RESOLUTION_REASON" "$RESOLUTION_EVIDENCE"
  resolution_next
}

resolution_wait() { # <reason>
  RESOLUTION_STATUS=waiting_for_approval
  RESOLUTION_REASON=$1
  RESOLUTION_PROJECT=''
  RESOLUTION_REPOSITORY=''
  RESOLUTION_PROJECT_DIR=''
  RESOLUTION_TARGET_BRANCH=''
  RESOLUTION_CANDIDATE_DIGEST=''
  RESOLUTION_METADATA_DIGEST=''
  RESOLUTION_EVIDENCE=''
  resolution_write
  emit_resolution
  return 4
}

load_candidates() {
  local prefix row_prefix row_project row_repo row_dir row_target extra digest
  CANDIDATE_COUNT=0
  CANDIDATE_PROJECT=()
  CANDIDATE_REPOSITORY=()
  CANDIDATE_DIRECTORY=()
  CANDIDATE_TARGET=()
  CANDIDATE_DIGEST=()
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] \
    || { resolution_wait repository-candidates-absent; return $?; }
  prefix=${TICKET%%-*}
  while IFS=$'\t' read -r row_prefix row_project row_repo row_dir row_target extra; do
    case "$row_prefix" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] || die "invalid repository candidate row for $row_prefix"
    [ -n "$row_project" ] && [ -n "$row_repo" ] && [ -n "$row_dir" ] && [ -n "$row_target" ] \
      || die "incomplete repository candidate for $row_prefix"
    if ! safe_name "$row_prefix" || ! safe_name "$row_project" || ! repository_value "$row_repo" \
      || ! safe_value "$row_dir" || ! branch_value "$row_target" || [[ "$row_dir" != /* ]]; then
      die "unsafe repository candidate for $row_prefix"
    fi
    [ "$row_prefix" = "$prefix" ] || continue
    digest=$(hash_candidate "$row_prefix" "$row_project" "$row_repo" "$row_dir" "$row_target")
    CANDIDATE_PROJECT[CANDIDATE_COUNT]=$row_project
    CANDIDATE_REPOSITORY[CANDIDATE_COUNT]=$row_repo
    CANDIDATE_DIRECTORY[CANDIDATE_COUNT]=$row_dir
    CANDIDATE_TARGET[CANDIDATE_COUNT]=$row_target
    CANDIDATE_DIGEST[CANDIDATE_COUNT]=$digest
    CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
  done < "$CONFIG_FILE"
  [ "$CANDIDATE_COUNT" -gt 0 ] || { resolution_wait repository-candidates-absent; return $?; }
}

repository_from_remote() { # <untrusted remote URL>
  local remote=$1 path
  safe_text "$remote" || return 1
  case "$remote" in
    git@*:*) path=${remote#*:} ;;
    ssh://*|http://*|https://*)
      path=${remote#*://}
      case "$path" in */*) path=${path#*/} ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  repository_value "$path" || return 1
  printf '%s' "$path"
}

candidate_metadata() { # <repository> <directory> <target>
  local repository=$1 directory=$2 target=$3 root configured_root remote origin
  [ -d "$directory" ] || return 1
  configured_root=$(cd "$directory" && pwd -P) || return 1
  safe_value "$configured_root" || return 1
  root=$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null) || return 1
  safe_value "$root" || return 1
  [ "$root" = "$configured_root" ] || return 1
  remote=$(git -C "$directory" remote get-url origin 2>/dev/null) || return 1
  origin=$(repository_from_remote "$remote") || return 1
  [ "$origin" = "$repository" ] || return 1
  CANDIDATE_METADATA_DIGEST=$(hash_metadata "$repository" "$root" "$origin" "$target")
}

ticket_evidence_has_repository() { # <evidence-file> <repository>
  local evidence_file=$1 repository=$2
  LC_ALL=C awk -v repository="$repository" '
    function is_repository_char(character) {
      return character ~ /^[[:alnum:]_.\/-]$/
    }
    function contains_exact(value, before, after, position, remainder) {
      remainder = value
      while ((position = index(remainder, repository)) > 0) {
        before = (position == 1 ? "" : substr(remainder, position - 1, 1))
        after = substr(remainder, position + length(repository), 1)
        if ((before == "" || !is_repository_char(before)) \
            && (after == "" || !is_repository_char(after))) {
          return 1
        }
        remainder = substr(remainder, position + length(repository))
      }
      return 0
    }
    contains_exact($0) { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$evidence_file" \
    || LC_ALL=C awk -v repository="${repository}.git" '
      function is_repository_char(character) {
        return character ~ /^[[:alnum:]_.\/-]$/
      }
      function contains_exact(value, before, after, position, remainder) {
        remainder = value
        while ((position = index(remainder, repository)) > 0) {
          before = (position == 1 ? "" : substr(remainder, position - 1, 1))
          after = substr(remainder, position + length(repository), 1)
          if ((before == "" || !is_repository_char(before)) \
              && (after == "" || !is_repository_char(after))) {
            return 1
          }
          remainder = substr(remainder, position + length(repository))
        }
        return 0
      }
      contains_exact($0) { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$evidence_file"
}

read_ticket_evidence() {
  local reader reader_output line key value seen_schema=0 seen_ticket=0 reader_valid=1
  reader="$CONFIG/zentre-workflow/ticket-reader"
  [ -f "$reader" ] && [ ! -L "$reader" ] && [ -x "$reader" ] || return 1
  reader_output=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-zentre-ticket-reader.XXXXXX") \
    || die "could not read ticket"
  READER_EVIDENCE_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-zentre-ticket-evidence.XXXXXX") \
    || { rm -f "$reader_output"; die "could not prepare ticket evidence"; }
  if ! (ulimit -f 128; "$reader" "$TICKET" > "$reader_output" 2>/dev/null); then
    rm -f "$reader_output" "$READER_EVIDENCE_FILE"
    return 1
  fi
  [ "$(wc -c < "$reader_output" | tr -d ' ')" -le 65536 ] \
    || { rm -f "$reader_output" "$READER_EVIDENCE_FILE"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    if [ "$key" = "$line" ] || ! safe_text "$value"; then
      reader_valid=0
      break
    fi
    case "$key" in
      schema)
        if [ "$seen_schema" -ne 0 ] || [ "$value" != zentre-workflow-ticket-reader.v1 ]; then
          reader_valid=0
          break
        fi
        seen_schema=1
        ;;
      ticket)
        if [ "$seen_ticket" -ne 0 ] || [ "$value" != "$TICKET" ]; then
          reader_valid=0
          break
        fi
        seen_ticket=1
        ;;
      title|description|comment|attachment)
        if ! printf '%s\n' "$value" >> "$READER_EVIDENCE_FILE"; then
          reader_valid=0
          break
        fi
        ;;
      *) reader_valid=0; break ;;
    esac
  done < "$reader_output"
  if [ "$reader_valid" -ne 1 ]; then
    rm -f "$reader_output" "$READER_EVIDENCE_FILE"
    return 1
  fi
  READER_TICKET_DIGEST=$(hash_file "$reader_output")
  rm -f "$reader_output"
  [ "$seen_schema" -eq 1 ] && [ "$seen_ticket" -eq 1 ] \
    || { rm -f "$READER_EVIDENCE_FILE"; return 1; }
}

reuse_resolved_project() {
  local index=0 metadata_status
  [ -e "$RESOLUTION_FILE" ] || return 1
  resolution_read
  [ "$RESOLUTION_STATUS" = resolved ] || return 1
  [ "$RESOLUTION_REASON" = resolved ] || die "corrupt repository resolution reason"
  while [ "$index" -lt "$CANDIDATE_COUNT" ]; do
    if [ "${CANDIDATE_PROJECT[$index]}" = "$RESOLUTION_PROJECT" ] \
      && [ "${CANDIDATE_REPOSITORY[$index]}" = "$RESOLUTION_REPOSITORY" ] \
      && [ "${CANDIDATE_DIRECTORY[$index]}" = "$RESOLUTION_PROJECT_DIR" ] \
      && [ "${CANDIDATE_TARGET[$index]}" = "$RESOLUTION_TARGET_BRANCH" ] \
      && [ "${CANDIDATE_DIGEST[$index]}" = "$RESOLUTION_CANDIDATE_DIGEST" ]; then
      CANDIDATE_METADATA_DIGEST=''
      candidate_metadata "${CANDIDATE_REPOSITORY[$index]}" \
        "${CANDIDATE_DIRECTORY[$index]}" "${CANDIDATE_TARGET[$index]}"
      metadata_status=$?
      if [ "$metadata_status" -ne 0 ] \
        || [ "$CANDIDATE_METADATA_DIGEST" != "$RESOLUTION_METADATA_DIGEST" ]; then
        resolution_wait repository-resolution-drift
        return $?
      fi
      PROJECT=${CANDIDATE_PROJECT[$index]}
      REPOSITORY=${CANDIDATE_REPOSITORY[$index]}
      PROJECT_DIR=${CANDIDATE_DIRECTORY[$index]}
      TARGET_BRANCH=${CANDIDATE_TARGET[$index]}
      return 0
    fi
    index=$((index + 1))
  done
  resolution_wait repository-resolution-drift
}

resolve_project() {
  local index=0 selected_count=0 selected_index=-1 metadata_mismatch=0 reuse_status
  [ ! -L "$RESOLUTION_FILE" ] || die "repository resolution must not be a symlink"
  load_candidates || return $?
  reuse_resolved_project
  reuse_status=$?
  if [ "$reuse_status" -eq 0 ]; then
    return 0
  fi
  case "$reuse_status" in
    1) ;;
    *) return "$reuse_status" ;;
  esac
  if ! read_ticket_evidence; then
    resolution_wait ticket-source-unreachable
    return $?
  fi
  while [ "$index" -lt "$CANDIDATE_COUNT" ]; do
    if ticket_evidence_has_repository "$READER_EVIDENCE_FILE" "${CANDIDATE_REPOSITORY[$index]}"; then
      if candidate_metadata "${CANDIDATE_REPOSITORY[$index]}" \
        "${CANDIDATE_DIRECTORY[$index]}" "${CANDIDATE_TARGET[$index]}"; then
        selected_index=$index
        selected_count=$((selected_count + 1))
      else
        metadata_mismatch=1
      fi
    fi
    index=$((index + 1))
  done
  rm -f "$READER_EVIDENCE_FILE"
  case "$selected_count" in
    0)
      if [ "$metadata_mismatch" -eq 1 ]; then
        resolution_wait repository-metadata-mismatch
      else
        resolution_wait ticket-evidence-insufficient
      fi
      return $?
      ;;
    1)
      PROJECT=${CANDIDATE_PROJECT[$selected_index]}
      REPOSITORY=${CANDIDATE_REPOSITORY[$selected_index]}
      PROJECT_DIR=${CANDIDATE_DIRECTORY[$selected_index]}
      TARGET_BRANCH=${CANDIDATE_TARGET[$selected_index]}
      candidate_metadata "$REPOSITORY" "$PROJECT_DIR" "$TARGET_BRANCH" \
        || die "repository metadata changed during resolution"
      RESOLUTION_STATUS=resolved
      RESOLUTION_REASON=resolved
      RESOLUTION_PROJECT=$PROJECT
      RESOLUTION_REPOSITORY=$REPOSITORY
      RESOLUTION_PROJECT_DIR=$PROJECT_DIR
      RESOLUTION_TARGET_BRANCH=$TARGET_BRANCH
      RESOLUTION_TICKET_DIGEST=$READER_TICKET_DIGEST
      RESOLUTION_CANDIDATE_DIGEST=${CANDIDATE_DIGEST[$selected_index]}
      RESOLUTION_METADATA_DIGEST=$CANDIDATE_METADATA_DIGEST
      RESOLUTION_EVIDENCE="literal-repository-reference:$REPOSITORY"
      resolution_write
      ;;
    *)
      resolution_wait repository-ambiguous
      return $?
      ;;
  esac
}

review_family() { # <configured-profile>
  local profile=$1 row_profile row_family extra found=0 family=''
  local file="$CONFIG/zentre-workflow/review-families.tsv"
  safe_name "$profile" || die "review profile must be a safe identifier"
  [ -f "$file" ] && [ ! -L "$file" ] \
    || die "review family mapping is required at $file"
  while IFS=$'\t' read -r row_profile row_family extra; do
    case "$row_profile" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] || die "invalid review family mapping row for $row_profile"
    [ "$row_profile" = "$profile" ] || continue
    safe_name "$row_family" || die "unsafe review family for profile $profile"
    found=$((found + 1))
    family=$row_family
  done < "$file"
  [ "$found" -eq 1 ] || die "review profile $profile must have exactly one configured family"
  printf '%s' "$family"
}

state_get() { # <key>
  local want=$1 key value count=0 result=
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 1
  while IFS='=' read -r key value; do
    [ "$key" = "$want" ] || continue
    count=$((count + 1))
    result=$value
  done < "$STATE_FILE"
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$result"
}

state_read() {
  local key value
  for key in version execution_id ticket project repository project_dir target_branch stage status \
    ticket_digest base_sha candidate_sha config_digest branch analysis_artifact specification_artifact \
    implementation_artifact sonar_baseline_report sonar_candidate_report spec_author_profile \
    spec_reviewer_profile code_author_profile code_reviewer_profile spec_iteration code_iteration \
    sonar_iteration resolution_ticket_digest resolution_candidate_digest \
    resolution_metadata_digest resolution_evidence reason updated_at; do
    value=$(state_get "$key") || die "corrupt state: missing or duplicate $key in $STATE_FILE"
    safe_text "$value" || die "corrupt state: unsafe $key in $STATE_FILE"
    case "$key" in
      version) VERSION=$value ;; execution_id) EXECUTION_ID=$value ;; ticket) STATE_TICKET=$value ;;
      project) STATE_PROJECT=$value ;; repository) STATE_REPOSITORY=$value ;;
      project_dir) STATE_PROJECT_DIR=$value ;; target_branch) STATE_TARGET_BRANCH=$value ;;
      stage) STAGE=$value ;; status) RUN_STATUS=$value ;; ticket_digest) TICKET_DIGEST=$value ;;
      base_sha) BASE_SHA=$value ;; candidate_sha) CANDIDATE_SHA=$value ;;
      config_digest) CONFIG_DIGEST=$value ;; spec_iteration) SPEC_ITERATION=$value ;;
      code_iteration) CODE_ITERATION=$value ;; sonar_iteration) SONAR_ITERATION=$value ;;
      branch) BRANCH_NAME=$value ;; analysis_artifact) ANALYSIS_ARTIFACT=$value ;;
      specification_artifact) SPECIFICATION_ARTIFACT=$value ;;
      implementation_artifact) IMPLEMENTATION_ARTIFACT=$value ;;
      sonar_baseline_report) SONAR_BASELINE_REPORT=$value ;;
      sonar_candidate_report) SONAR_CANDIDATE_REPORT=$value ;;
      spec_author_profile) SPEC_AUTHOR_PROFILE=$value ;;
      spec_reviewer_profile) SPEC_REVIEWER_PROFILE=$value ;;
      code_author_profile) CODE_AUTHOR_PROFILE=$value ;;
      code_reviewer_profile) CODE_REVIEWER_PROFILE=$value ;;
      resolution_ticket_digest) STATE_RESOLUTION_TICKET_DIGEST=$value ;;
      resolution_candidate_digest) STATE_RESOLUTION_CANDIDATE_DIGEST=$value ;;
      resolution_metadata_digest) STATE_RESOLUTION_METADATA_DIGEST=$value ;;
      resolution_evidence) STATE_RESOLUTION_EVIDENCE=$value ;;
      reason) WAIT_REASON=$value ;;
      updated_at) UPDATED_AT=$value ;;
    esac
  done
  [ "$VERSION" = 2 ] || die "unsupported state version $VERSION"
  [ "$STATE_TICKET" = "$TICKET" ] && [ "$STATE_PROJECT" = "$PROJECT" ] \
    && [ "$STATE_REPOSITORY" = "$REPOSITORY" ] \
    && [ "$STATE_PROJECT_DIR" = "$PROJECT_DIR" ] \
    && [ "$STATE_TARGET_BRANCH" = "$TARGET_BRANCH" ] \
    || die "state identity does not match resolved repository"
  [ "$STATE_RESOLUTION_TICKET_DIGEST" = "$RESOLUTION_TICKET_DIGEST" ] \
    && [ "$STATE_RESOLUTION_CANDIDATE_DIGEST" = "$RESOLUTION_CANDIDATE_DIGEST" ] \
    && [ "$STATE_RESOLUTION_METADATA_DIGEST" = "$RESOLUTION_METADATA_DIGEST" ] \
    && [ "$STATE_RESOLUTION_EVIDENCE" = "$RESOLUTION_EVIDENCE" ] \
    || die "state repository resolution does not match durable resolution"
}

state_write() {
  local tmp now
  now=$(date +%s) || die "could not read time"
  tmp=$(umask 077; mktemp "$RUN_DIR/.state.XXXXXX") || die "could not create state replacement"
  {
    printf 'version=2\n'
    printf 'execution_id=%s\n' "$EXECUTION_ID"
    printf 'ticket=%s\n' "$TICKET"
    printf 'project=%s\n' "$PROJECT"
    printf 'repository=%s\n' "$REPOSITORY"
    printf 'project_dir=%s\n' "$PROJECT_DIR"
    printf 'target_branch=%s\n' "$TARGET_BRANCH"
    printf 'stage=%s\n' "$STAGE"
    printf 'status=%s\n' "$RUN_STATUS"
    printf 'ticket_digest=%s\n' "$TICKET_DIGEST"
    printf 'base_sha=%s\n' "$BASE_SHA"
    printf 'candidate_sha=%s\n' "$CANDIDATE_SHA"
    printf 'config_digest=%s\n' "$CONFIG_DIGEST"
    printf 'branch=%s\n' "$BRANCH_NAME"
    printf 'analysis_artifact=%s\n' "$ANALYSIS_ARTIFACT"
    printf 'specification_artifact=%s\n' "$SPECIFICATION_ARTIFACT"
    printf 'implementation_artifact=%s\n' "$IMPLEMENTATION_ARTIFACT"
    printf 'sonar_baseline_report=%s\n' "$SONAR_BASELINE_REPORT"
    printf 'sonar_candidate_report=%s\n' "$SONAR_CANDIDATE_REPORT"
    printf 'spec_author_profile=%s\n' "$SPEC_AUTHOR_PROFILE"
    printf 'spec_reviewer_profile=%s\n' "$SPEC_REVIEWER_PROFILE"
    printf 'code_author_profile=%s\n' "$CODE_AUTHOR_PROFILE"
    printf 'code_reviewer_profile=%s\n' "$CODE_REVIEWER_PROFILE"
    printf 'resolution_ticket_digest=%s\n' "$RESOLUTION_TICKET_DIGEST"
    printf 'resolution_candidate_digest=%s\n' "$RESOLUTION_CANDIDATE_DIGEST"
    printf 'resolution_metadata_digest=%s\n' "$RESOLUTION_METADATA_DIGEST"
    printf 'resolution_evidence=%s\n' "$RESOLUTION_EVIDENCE"
    printf 'reason=%s\n' "$WAIT_REASON"
    printf 'spec_iteration=%s\n' "$SPEC_ITERATION"
    printf 'code_iteration=%s\n' "$CODE_ITERATION"
    printf 'sonar_iteration=%s\n' "$SONAR_ITERATION"
    printf 'updated_at=%s\n' "$now"
  } > "$tmp" || { rm -f "$tmp"; die "could not write state replacement"; }
  mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; die "could not publish state"; }
  UPDATED_AT=$now
}

append_history() { # <event> [detail]
  local event=$1 detail=${2:-} now
  now=$(date +%s) || die "could not read time"
  safe_text "$detail" || die "unsafe history detail"
  printf '%s\t%s\t%s\t%s\n' "$now" "$EXECUTION_ID" "$event" "$detail" >> "$HISTORY_FILE" \
    || die "could not append history"
}

op_file() { printf '%s/operations/%s.state' "$RUN_DIR" "$1"; }

read_operation() { # <name>
  local file=$1 key value status='' id='' reference=''
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS='=' read -r key value; do
    safe_text "$value" || return 1
    case "$key" in status) status=$value ;; id) id=$value ;; reference) reference=$value ;; *) return 1 ;; esac
  done < "$file"
  [ -n "$status" ] && [ -n "$id" ] || return 1
  OP_STATUS=$status OP_ID=$id OP_REFERENCE=$reference
}

write_operation() { # <name> <status> <id> <reference>
  local name=$1 status=$2 id=$3 reference=$4 file tmp
  if ! safe_name "$name" || ! safe_value "$status" || ! safe_value "$id" \
    || ! safe_text "$reference"; then
    die "unsafe operation record"
  fi
  file=$(op_file "$name")
  tmp=$(umask 077; mktemp "$RUN_DIR/operations/.${name}.XXXXXX") \
    || die "could not create operation record"
  printf 'status=%s\nid=%s\nreference=%s\n' "$status" "$id" "$reference" > "$tmp" \
    || { rm -f "$tmp"; die "could not write operation record"; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; die "could not publish operation record"; }
}

operation_is_done() { # <name>
  local file
  file=$(op_file "$1")
  read_operation "$file" && [ "$OP_STATUS" = 'done' ]
}

next_action() {
  case "$RUN_STATUS" in
    paused|cancelled|waiting_for_approval)
      printf 'next=none\n'
      return 0
      ;;
  esac
  case "$STAGE" in
    analysis) printf 'next=delegate-ticket-analysis\n' ;;
    branch) printf 'next=reconcile-or-create-branch\n' ;;
    specification) printf 'next=delegate-specification\n' ;;
    spec-review) printf 'next=delegate-independent-spec-review\n' ;;
    implementation) printf 'next=delegate-implementation-or-remediation\n' ;;
    code-review) printf 'next=delegate-independent-code-review\n' ;;
    sonar-baseline) printf 'next=run-existing-sonar-gate-at-recorded-base\n' ;;
    sonar-candidate) printf 'next=run-existing-sonar-gate-at-candidate\n' ;;
    delivery) printf 'next=publish-reports-create-or-reconcile-mr-update-ticket\n' ;;
    complete) printf 'next=none\n' ;;
    *) die "corrupt state: unknown stage $STAGE" ;;
  esac
}

emit_status() {
  printf 'execution_id=%s\n' "$EXECUTION_ID"
  printf 'ticket=%s\nrepository=%s\nproject=%s\n' "$TICKET" "$REPOSITORY" "$PROJECT"
  printf 'stage=%s\nstate=%s\nreason=%s\n' "$STAGE" "$RUN_STATUS" "$WAIT_REASON"
  printf 'base_sha=%s\ncandidate_sha=%s\n' "$BASE_SHA" "$CANDIDATE_SHA"
  printf 'spec_iteration=%s\ncode_iteration=%s\nsonar_iteration=%s\n' \
    "$SPEC_ITERATION" "$CODE_ITERATION" "$SONAR_ITERATION"
  next_action
}

create_state() {
  local now token
  mkdir -p "$RUN_DIR/operations" || die "could not create execution directory"
  umask 077
  token=$(mktemp "$RUN_DIR/.execution.XXXXXX") || die "could not allocate execution identity"
  rm -f "$token" || die "could not release execution identity allocation"
  EXECUTION_ID="${TICKET}-$(date +%Y%m%d%H%M%S)-${token##*.}"
  STAGE=analysis RUN_STATUS=running TICKET_DIGEST='' BASE_SHA='' CANDIDATE_SHA='' CONFIG_DIGEST=''
  BRANCH_NAME='' ANALYSIS_ARTIFACT='' SPECIFICATION_ARTIFACT='' IMPLEMENTATION_ARTIFACT=''
  SONAR_BASELINE_REPORT='' SONAR_CANDIDATE_REPORT='' SPEC_AUTHOR_PROFILE='' SPEC_REVIEWER_PROFILE=''
  CODE_AUTHOR_PROFILE='' CODE_REVIEWER_PROFILE=''
  WAIT_REASON=''
  SPEC_ITERATION=0 CODE_ITERATION=0 SONAR_ITERATION=0
  state_write
  now=$UPDATED_AT
  append_history created "start-or-resume"
}

release_lock() { fm_lock_release "$LOCK_DIR" || true; }

acquire_lock() {
  LOCK_DIR="$RUN_DIR/.lock"
  if ! fm_lock_try_acquire "$LOCK_DIR"; then
    refuse "another runner owns $TICKET for $REPOSITORY"
  fi
  trap release_lock EXIT INT TERM
}

require_running() {
  [ "$RUN_STATUS" = running ] || refuse "execution is $RUN_STATUS; use --resume after an authorized decision"
}

require_stage() {
  [ "$STAGE" = "$1" ] || refuse "expected stage $1, found $STAGE"
}

require_digest() { digest_value "$1" || die "$2 must be a non-empty hexadecimal digest"; }
require_sha() { digest_value "$1" || die "$2 must be a non-empty hexadecimal revision"; }

verify_source_revision() { # <source-dir> <expected-sha>
  local source=$1 expected=$2 observed
  [ -n "$source" ] || die "Sonar completion needs --source-dir"
  safe_value "$source" || die "unsafe Sonar source directory"
  [ -d "$source" ] || refuse "Sonar source directory is unavailable: $source"
  observed=$(git -C "$source" rev-parse HEAD 2>/dev/null) \
    || refuse "Sonar source directory is not a readable Git revision: $source"
  [ "$observed" = "$expected" ] \
    || refuse "Sonar source revision does not match the recorded workflow revision"
}

complete_stage() {
  local now artifact author reviewer result author_family reviewer_family
  require_running
  case "$COMPLETE_STAGE" in
    analysis)
      require_stage analysis
      require_digest "$INPUT_DIGEST" '--input-digest'
      require_digest "$CONFIG_INPUT_DIGEST" '--config-digest'
      [ -n "$ARTIFACT" ] || die "analysis completion needs --artifact"
      safe_value "$ARTIFACT" || die "unsafe artifact reference"
      TICKET_DIGEST=$INPUT_DIGEST CONFIG_DIGEST=$CONFIG_INPUT_DIGEST ANALYSIS_ARTIFACT=$ARTIFACT STAGE=branch
      ;;
    branch)
      require_stage branch
      require_sha "$BASE_INPUT_SHA" '--base-sha'
      [ -n "$BRANCH" ] || die "branch completion needs --branch"
      safe_value "$BRANCH" || die "unsafe branch"
      operation_is_done branch || refuse "branch completion requires a completed branch operation"
      BRANCH_NAME=$BRANCH BASE_SHA=$BASE_INPUT_SHA CANDIDATE_SHA=$BASE_INPUT_SHA STAGE=specification
      ;;
    specification)
      require_stage specification
      [ -n "$ARTIFACT" ] || die "specification completion needs --artifact"
      safe_value "$ARTIFACT" || die "unsafe artifact reference"
      SPECIFICATION_ARTIFACT=$ARTIFACT STAGE=spec-review
      ;;
    spec-review)
      require_stage spec-review
      author=$AUTHOR_PROFILE reviewer=$REVIEWER_PROFILE result=$RESULT
      author_family=$(review_family "$author") reviewer_family=$(review_family "$reviewer")
      [ "$author_family" != "$reviewer_family" ] || refuse "a specification author cannot approve its own work"
      case "$result" in approved|changes) ;; *) die "specification review needs --result approved|changes" ;; esac
      SPEC_AUTHOR_PROFILE=$author SPEC_REVIEWER_PROFILE=$reviewer
      SPEC_ITERATION=$((SPEC_ITERATION + 1))
      if [ "$result" = approved ]; then
        STAGE=implementation
      elif [ "$SPEC_ITERATION" -ge 3 ]; then
        RUN_STATUS=waiting_for_approval
        WAIT_REASON=spec-review-limit
      else
        STAGE=specification
      fi
      ;;
    implementation)
      require_stage implementation
      require_sha "$CANDIDATE_INPUT_SHA" '--candidate-sha'
      [ -n "$ARTIFACT" ] || die "implementation completion needs --artifact"
      safe_value "$ARTIFACT" || die "unsafe artifact reference"
      CANDIDATE_SHA=$CANDIDATE_INPUT_SHA IMPLEMENTATION_ARTIFACT=$ARTIFACT STAGE=code-review
      ;;
    code-review)
      require_stage code-review
      author=$AUTHOR_PROFILE reviewer=$REVIEWER_PROFILE result=$RESULT
      author_family=$(review_family "$author") reviewer_family=$(review_family "$reviewer")
      [ "$author_family" != "$reviewer_family" ] || refuse "an implementation author cannot approve its own work"
      case "$result" in approved|changes) ;; *) die "code review needs --result approved|changes" ;; esac
      CODE_AUTHOR_PROFILE=$author CODE_REVIEWER_PROFILE=$reviewer
      CODE_ITERATION=$((CODE_ITERATION + 1))
      if [ "$result" = approved ]; then
        STAGE=sonar-baseline
      elif [ "$CODE_ITERATION" -ge 3 ]; then
        RUN_STATUS=waiting_for_approval
        WAIT_REASON=code-review-limit
      else
        STAGE=implementation
      fi
      ;;
    sonar-baseline)
      require_stage sonar-baseline
      require_sha "$BASE_INPUT_SHA" '--base-sha'
      [ "$BASE_INPUT_SHA" = "$BASE_SHA" ] || refuse "Sonar baseline must use recorded base revision"
      verify_source_revision "$SONAR_SOURCE_DIR" "$BASE_SHA"
      [ -n "$ARTIFACT" ] || die "Sonar baseline completion needs --artifact report"
      operation_is_done sonar-baseline || refuse "Sonar baseline requires a completed sonar-baseline operation"
      SONAR_BASELINE_REPORT=$ARTIFACT STAGE=sonar-candidate
      ;;
    sonar-candidate)
      require_stage sonar-candidate
      require_sha "$CANDIDATE_INPUT_SHA" '--candidate-sha'
      [ "$CANDIDATE_INPUT_SHA" = "$CANDIDATE_SHA" ] || refuse "Sonar candidate must use recorded candidate revision"
      verify_source_revision "$SONAR_SOURCE_DIR" "$CANDIDATE_SHA"
      [ -n "$ARTIFACT" ] || die "Sonar candidate completion needs --artifact report"
      operation_is_done sonar-candidate || refuse "Sonar candidate requires a completed sonar-candidate operation"
      case "$RESULT" in pass|fix) ;; *) die "Sonar candidate needs --result pass|fix" ;; esac
      SONAR_ITERATION=$((SONAR_ITERATION + 1))
      SONAR_CANDIDATE_REPORT=$ARTIFACT
      if [ "$RESULT" = pass ]; then
        STAGE=delivery
      elif [ "$SONAR_ITERATION" -ge 4 ]; then
        RUN_STATUS=waiting_for_approval
        WAIT_REASON=sonar-remediation-limit
      else
        STAGE=implementation
      fi
      ;;
    delivery)
      require_stage delivery
      if ! operation_is_done report || ! operation_is_done merge-request \
        || ! operation_is_done ticket-update; then
        refuse "delivery requires completed report, merge-request, and ticket-update operations"
      fi
      STAGE=complete RUN_STATUS=completed
      ;;
    *) die "unknown stage $COMPLETE_STAGE" ;;
  esac
  state_write
  now=$UPDATED_AT
  append_history completed "$COMPLETE_STAGE"
  emit_status
}

TICKET=${1:-}
[ -n "$TICKET" ] || usage
shift || true
ticket_value "$TICKET" || die "ticket must use canonical uppercase form such as PROJ-123"

MODE=start COMPLETE_STAGE='' OPERATION='' OPERATION_ID='' OPERATION_REFERENCE=''
INPUT_DIGEST='' CONFIG_INPUT_DIGEST='' BASE_INPUT_SHA='' CANDIDATE_INPUT_SHA='' ARTIFACT='' BRANCH='' SONAR_SOURCE_DIR=''
AUTHOR_PROFILE='' REVIEWER_PROFILE='' RESULT='' ACCEPT_DRIFT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status) MODE=status; shift ;;
    --resume) MODE=resume; shift ;;
    --pause) MODE=pause; shift ;;
    --cancel) MODE=cancel; shift ;;
    --restart) MODE=restart; shift ;;
    --confirm-restart) ACCEPT_DRIFT=1; shift ;;
    --complete) COMPLETE_STAGE=${2:-}; MODE=complete; shift 2 ;;
    --begin-operation) OPERATION=${2:-}; OPERATION_ID=${3:-}; MODE=begin-operation; shift 3 ;;
    --finish-operation) OPERATION=${2:-}; OPERATION_ID=${3:-}; OPERATION_REFERENCE=${4:-}; MODE=finish-operation; shift 4 ;;
    --reconcile-operation) OPERATION=${2:-}; OPERATION_ID=${3:-}; OPERATION_REFERENCE=${4:-}; MODE=reconcile-operation; shift 4 ;;
    --reconcile-inputs) MODE=reconcile-inputs; shift ;;
    --ticket-digest|--input-digest) INPUT_DIGEST=${2:-}; shift 2 ;;
    --config-digest) CONFIG_INPUT_DIGEST=${2:-}; shift 2 ;;
    --base-sha) BASE_INPUT_SHA=${2:-}; shift 2 ;;
    --candidate-sha) CANDIDATE_INPUT_SHA=${2:-}; shift 2 ;;
    --artifact) ARTIFACT=${2:-}; shift 2 ;;
    --branch) BRANCH=${2:-}; shift 2 ;;
    --source-dir) SONAR_SOURCE_DIR=${2:-}; shift 2 ;;
    --author-profile) AUTHOR_PROFILE=${2:-}; shift 2 ;;
    --reviewer-profile) REVIEWER_PROFILE=${2:-}; shift 2 ;;
    --result) RESULT=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument $1" ;;
  esac
done

TICKET_ROOT="$ROOT/$TICKET"
RESOLUTION_FILE="$TICKET_ROOT/resolution"
RESOLUTION_LOCK="$TICKET_ROOT/.resolution-lock"
RESOLUTION_VERSION='' RESOLUTION_STATUS='' RESOLUTION_REASON=''
RESOLUTION_TICKET='' RESOLUTION_PROJECT='' RESOLUTION_REPOSITORY=''
RESOLUTION_PROJECT_DIR='' RESOLUTION_TARGET_BRANCH=''
RESOLUTION_TICKET_DIGEST='' RESOLUTION_CANDIDATE_DIGEST=''
RESOLUTION_METADATA_DIGEST='' RESOLUTION_EVIDENCE='' RESOLUTION_UPDATED_AT=''
READER_TICKET_DIGEST='' READER_EVIDENCE_FILE='' CANDIDATE_METADATA_DIGEST=''

mkdir -p "$TICKET_ROOT" || die "could not create workflow state root"
if ! fm_lock_try_acquire "$RESOLUTION_LOCK"; then
  refuse "another runner is resolving $TICKET"
fi
trap 'fm_lock_release "$RESOLUTION_LOCK" || true' EXIT INT TERM
resolve_project
resolution_status=$?
fm_lock_release "$RESOLUTION_LOCK" || true
trap - EXIT INT TERM
[ "$resolution_status" -eq 0 ] || exit "$resolution_status"

RUN_KEY=$(printf '%s' "$REPOSITORY" | shasum -a 256 | awk '{print substr($1, 1, 16)}')
RUN_DIR="$TICKET_ROOT/$RUN_KEY"
STATE_FILE="$RUN_DIR/state"
HISTORY_FILE="$RUN_DIR/history.tsv"
[ -e "$RUN_DIR" ] || mkdir -p "$RUN_DIR" || die "could not create execution directory"
acquire_lock

[ ! -L "$STATE_FILE" ] || die "state file must not be a symlink"
if [ ! -e "$STATE_FILE" ]; then
  case "$MODE" in start|resume) create_state ;; *) refuse "no execution exists for $TICKET" ;; esac
else
  state_read
fi

case "$MODE" in
  start|status)
    emit_status
    ;;
  resume)
    case "$RUN_STATUS" in paused|waiting_for_approval) RUN_STATUS=running; WAIT_REASON=''; state_write; append_history resumed "" ;; cancelled|completed) refuse "execution is $RUN_STATUS; use explicitly confirmed --restart" ;; esac
    emit_status
    ;;
  pause)
    require_running
    RUN_STATUS=paused; WAIT_REASON=paused-by-operator; state_write; append_history paused ""
    emit_status
    ;;
  cancel)
    [ "$RUN_STATUS" = completed ] && refuse "completed execution cannot be cancelled"
    RUN_STATUS=cancelled; WAIT_REASON=cancelled-by-operator; state_write; append_history cancelled ""
    emit_status
    ;;
  restart)
    [ "$ACCEPT_DRIFT" -eq 1 ] || refuse "restart needs --confirm-restart and retains the prior execution history"
    mv "$STATE_FILE" "$RUN_DIR/state.$EXECUTION_ID.archived" || die "could not archive prior state"
    mv "$RUN_DIR/operations" "$RUN_DIR/operations.$EXECUTION_ID.archived" \
      || die "could not archive prior external-operation receipts"
    create_state
    emit_status
    ;;
  begin-operation)
    if ! safe_name "$OPERATION" || ! safe_value "$OPERATION_ID"; then
      die "operation needs a safe name and id"
    fi
    if read_operation "$(op_file "$OPERATION")"; then
      [ "$OP_ID" = "$OPERATION_ID" ] || refuse "operation $OPERATION already belongs to a different effect"
      case "$OP_STATUS" in done) printf 'operation=%s\nstatus=done\nreference=%s\n' "$OPERATION" "$OP_REFERENCE" ;; intent) printf 'operation=%s\nstatus=reconcile\n' "$OPERATION" ;; *) die "corrupt operation $OPERATION" ;; esac
    else
      write_operation "$OPERATION" intent "$OPERATION_ID" ""
      append_history operation-intent "$OPERATION:$OPERATION_ID"
      printf 'operation=%s\nstatus=new\n' "$OPERATION"
    fi
    ;;
  finish-operation|reconcile-operation)
    if ! safe_name "$OPERATION" || ! safe_value "$OPERATION_ID" || ! safe_value "$OPERATION_REFERENCE"; then
      die "operation needs safe name, id, and reference"
    fi
    read_operation "$(op_file "$OPERATION")" || refuse "operation $OPERATION has no intent to finish"
    [ "$OP_ID" = "$OPERATION_ID" ] || refuse "operation $OPERATION belongs to a different effect"
    if [ "$OP_STATUS" = 'done' ]; then
      [ "$OP_REFERENCE" = "$OPERATION_REFERENCE" ] || refuse "operation $OPERATION already has a different reference"
    else
      write_operation "$OPERATION" 'done' "$OPERATION_ID" "$OPERATION_REFERENCE"
      append_history operation-done "$OPERATION:$OPERATION_ID"
    fi
    printf 'operation=%s\nstatus=done\nreference=%s\n' "$OPERATION" "$OPERATION_REFERENCE"
    ;;
  reconcile-inputs)
    require_digest "$INPUT_DIGEST" '--ticket-digest'
    require_digest "$CONFIG_INPUT_DIGEST" '--config-digest'
    require_sha "$BASE_INPUT_SHA" '--base-sha'
    require_sha "$CANDIDATE_INPUT_SHA" '--candidate-sha'
    if [ "$INPUT_DIGEST" != "$TICKET_DIGEST" ] || [ "$CONFIG_INPUT_DIGEST" != "$CONFIG_DIGEST" ] \
      || [ "$BASE_INPUT_SHA" != "$BASE_SHA" ] || [ "$CANDIDATE_INPUT_SHA" != "$CANDIDATE_SHA" ]; then
      RUN_STATUS=waiting_for_approval
      WAIT_REASON=input-drift
      state_write
      append_history input-drift "reconciliation paused"
      emit_status
      exit 4
    fi
    printf 'reconciled=valid\n'
    ;;
  complete) complete_stage ;;
esac
