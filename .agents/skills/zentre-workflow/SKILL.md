---
name: zentre-workflow
description: Use when a YouTrack ticket needs start-or-resume Firstmate delivery through GitLab, independent cross-family reviews, SonarQube validation, durable reports, or a resumable ticket workflow.
metadata:
  internal: true
---

# zentre-workflow

Use `bin/fm-zentre-workflow.sh` as the durable workflow record.
It coordinates existing Firstmate delegation, model selection, GitLab, report, and Sonar interfaces rather than replacing them.

Configure private ticket resolution with [`docs/configuration.md`](../../../docs/configuration.md#zentre-workflow-ticket-resolution-configzentre-workflow).
That section owns the candidate schema, reader protocol, credential boundary, untrusted-input boundary, durable evidence, and decision cases.

Create `config/zentre-workflow/review-families.tsv` too.
Each tab-separated row maps one configured dispatch profile to an explicit review-isolation family.
Do not derive that family from a harness name.

Run `bin/fm-zentre-workflow.sh PROJ-123` to create or resume the active execution.
Once a matching ticket has resolved, a resume validates the same configured candidate and metadata before reusing it without rereading the ticket source.
Read its `next=` field, then delegate that stage through the ordinary task lifecycle.
Use the existing dispatch resolver and dispatch profiles for model and effort choice.
The reviewer profile supplied to `--complete spec-review` and `--complete code-review` must resolve to a different configured family than the author profile.

Before every GitLab branch, merge-request, report-upload, YouTrack-comment, or Sonar action, record a write-ahead intent:

```sh
bin/fm-zentre-workflow.sh PROJ-123 --begin-operation merge-request stable-input-id
```

If it prints `status=reconcile`, look up the remote effect before making another call.
After locating or completing exactly that effect, record its immutable reference with `--reconcile-operation` or `--finish-operation`.
Never repeat a remote effect merely because a local checkpoint is incomplete.

For Sonar, first follow `sonar-policy`.
Run the existing `sonar-gate enabled`, `setup`, and `check` interfaces through `bin/fm-zentre-workflow-sonar.sh` in the isolated project copy.
In disposable validation, materialize a separate clean source at the recorded base revision, prove it with `--source-dir`, create and finish a `sonar-baseline` operation for its report, then do the same for `sonar-candidate` at the candidate revision.
Re-establish the base source before every remediation candidate because the installed Community Build uses the previous analysis as New Code baseline.
Persist each report before any cleanup.
Never claim exit 30 as a pass, let a failed candidate become the baseline, or delete a temporary Sonar resource without explicit authorization.
The installed `sonar-gate` currently has no temporary-project interface, so `--mode disposable` refuses safely until a narrow adapter is added beside that existing integration.

`--reconcile-inputs` pauses on ticket, configuration, base, or candidate drift.
Do not force-push, overwrite remote work, or regenerate approved artifacts until the resulting decision is recorded.
`--pause`, `--cancel`, and explicitly confirmed `--restart` retain all state and history.
