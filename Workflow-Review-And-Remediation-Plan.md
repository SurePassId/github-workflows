# Stage Deployment Workflow Review and Remediation Plan

Review date: 2026-10-07

Status (2026-11-23): Stage implementation is complete. MFA, API, and SAML2 have successful Stage builds and deployments to both regions, and the user confirmed manual application validation in both regions. ServicePass is on hold for Stage and production; its live verification is intentionally skipped and is not a gate for the current rollout. Caller pin normalization is committed and pushed. The shared Stage changes remain unmerged into `main`. Production slot swaps are outside the scope of this plan.

## Scope

The plan covers all four application stage deployment callers and their shared build/deployment workflows:

- [Legacy MFA stage caller](../SurePassIdLegacyMfaServer/.github/workflows/deploy-stage.yaml)
- [API Server stage caller](../SurePassIdApiServer/.github/workflows/deploy-stage.yaml)
- [SAML2 stage caller](../SAML2_IdP/.github/workflows/deploy-stage.yaml)
- [ServicePass stage caller](../ServicePass/.github/workflows/deploy-stage.yaml)
- [Reusable .NET Framework build](.github/workflows/build-dot-net-fwk.yaml)
- [Reusable .NET 8 build](.github/workflows/build-dot-net8.yaml)
- [Reusable App Service deployment](.github/workflows/deploy-to-app-service.yaml)

Each caller builds its application once and deploys the same artifact to that application's `stage` slots in `eus2` and `wus3`. The application identifiers are `mfa`, `api`, `saml2`, and `servicepass`; Phase 3 corrected ServicePass's former MFA references (F6 and Q9). `DEPLOY_ENV=prod` selects production configuration; it does not mean the workflow targets the production slot. Preserve this distinction.

Production slot swaps for MFA, API, and SAML2, including production-promotion recovery preparation, are outside this plan and are not remaining Stage tasks or completion gates. References below to the existing validation-then-swap process describe operational context only; they do not authorize or require a production swap as part of this work.

Selected Q3 direction: Replace the branch trigger with tags named `stage-<yyyy.MM.dd-HH.mm.ss>` using UTC, for example `stage-2026.10.07-14.30.00`. Pushing a new tag builds its commit and deploys to both stage slots without an approval gate. After validation, the existing slot-swap process promotes that deployed build to production; there is no direct production deployment or rebuild. Do not deploy another candidate between validation and the swap.

Operating model: Either team member can publish changes, push a stage tag, validate the stage slots, and perform the existing swap when ready. No peer review, mandatory pull request, release sign-off, required environment reviewer, or deployment wait timer is part of this plan. The person deploying also decides whether to retry or roll back after a failure; no second person's approval is needed. Technical compatibility checks and manual validation still apply. Existing per-application concurrency may wait for an active deployment to finish; that is not an approval gate.

Reuse [the deployment-tag script](../../scripts/tag-deploy.ps1) and add one stage task per application to [the workspace tasks](../../.vscode/tasks.json). Each task runs in its application's repository: MFA Server, API Server, SAML2 Server, or ServicePass. A tag push deploys only the application in that repository, not all four applications. Existing `deploy2alpha-*`, `deploy2dev-*`, and `deploy2sandbox-*` tags remain unchanged; `stage-*` does not match the sandbox convention `deploy2*`.

This began as a static review of local files plus upstream action releases. The original published caller pins were `f181b9308c3df3776eae8de142d17a27ba8b9052`; later changes updated individual callers. Other consumers, including MFA preview, remain unchanged at `@main`. Stage environment protections were configured and verified during Phase 3. The `copy-web-env-files` source was inspected at commit `042023699388269110326b9f1df4abba8cbd2923`; its compatibility and limitations are recorded below.

### Current rollout status

All four Stage callers now reference shared commit `f2ac8072c02d20a17d295d5b373abf9c25a41c6e` for their build and both regional deployment workflows. SAML2 already referenced it; the normalization was committed and pushed for MFA (`704098b8`, `release/2026.4`), API (`7884dee`, `release/2026.4`), and ServicePass (`51a4da1`, `release/2025.3`) on 2026-11-23. The shared commit is published on `docs/stage-deployment-remediation-plan`, not merged into `main`.

| Application | Stage evidence | Current status |
| --- | --- | --- |
| MFA | [Run 44759333290](https://github.com/SurePassId/SurePassIdLegacyMfaServer/actions/runs/44759333290) succeeded on 2026-11-20, including build and both regional deployment jobs. | The run used `c3359cf`; the build and deploy workflow files are identical at `f2ac807`. |
| API | [Run 44797227441](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/44797227441) succeeded on 2026-11-20, including build and both regional deployment jobs. | The run used `94b70a6` for the modern build and `4f6623e` for deployment; those workflow files are identical at `f2ac807`. |
| SAML2 | [Run 44806046164](https://github.com/SurePassId/SAML2_IdP/actions/runs/44806046164) succeeded on 2026-11-20, including build and both regional deployment jobs. | The run used `f2ac807`. |
| ServicePass | Live verification is skipped at the user's direction. | Stage and production are on hold; the caller normalization is published but not deployed or verified as part of this update. |

The user confirmed on 2026-11-23 that manual application validation in both regions was completed. No deployment, tag push, or production swap was performed as part of this pin normalization. The ServicePass hold is operational: its existing Stage tag trigger remains configured, so do not initiate ServicePass Stage or production deployment while the hold is in effect.

## Findings

These findings describe the original reviewed state. Implementation progress is tracked in the phase checklist below.

### F1: Shared Publish Directory Can Contaminate Artifacts

Severity: High.

The build sets `_PackageTempDir` to `\published\`, overlays configuration in `/published`, and uploads `/published/**`. This drive-root directory is outside the checkout and has no explicit cleanup in the workflow.

On a persistent self-hosted runner, leftover files could enter a later artifact. If multiple runner instances share the same drive, concurrent builds could also write into the same directory. Confirm whether the MSBuild target or custom action performs any cleanup; the workflow itself does not guarantee isolation.

Recommended fix: Use an explicitly initialized, job-specific directory under `runner.temp`. Include run ID, run attempt, and job identity in its name. Pass the same absolute path to MSBuild, configuration copying, and artifact upload. The configuration-copy action accepts this destination; ensure it exists and create its `bin` subdirectory when copying `site.lic`.

`overwrite: true` replaces the remote GitHub artifact; it does not clean the local publish directory. Do not blindly delete the existing shared directory while other jobs may be using it.

### F2: Action Versions Are Behind Current Releases

Severity: Medium. Being behind the current major version does not by itself establish a runtime failure or an exploitable vulnerability.

| Workflow | Action                        | Current Reference | Latest Release Verified During Review                                     |
| -------- | ----------------------------- | ----------------- | ------------------------------------------------------------------------- |
| Build    | `actions/checkout`          | `v3`            | [v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1)          |
| Build    | `NuGet/setup-nuget`         | `v1`            | [v4.0](https://github.com/NuGet/setup-nuget/releases/tag/v4.0)             |
| Build    | `microsoft/setup-msbuild`   | `v1`            | [v3](https://github.com/microsoft/setup-msbuild/releases/tag/v3)           |
| Build    | `actions/upload-artifact`   | `v4`            | [v7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2)   |
| Deploy   | `actions/download-artifact` | `v4`            | [v8.0.2](https://github.com/actions/download-artifact/releases/tag/v8.0.2) |
| Deploy   | `azure/webapps-deploy`      | `v2`            | [v3.0.8](https://github.com/Azure/webapps-deploy/releases/tag/v3.0.8)      |

These are a dated release snapshot, not an instruction to upgrade without compatibility checks. Recheck release notes and resolve selected releases to commit SHAs during implementation.

The table above covers the originally reviewed Framework build and shared deploy actions. The newly included API build also uses `actions/checkout@v3`, `actions/setup-dotnet@v2`, and `actions/upload-artifact@v3`. Include these in the action update inventory, verify the current `setup-dotnet` release, and resolve the artifact incompatibility described in F8.

Runner automatic updates are already enabled, as confirmed by the user. No separate runner verification or maintenance task is required; investigate only if an upgraded action encounters a runner/OS compatibility error. Updating an action's Node runtime does not require upgrading the application's .NET Framework target.

Azure continues to publish `v2` maintenance releases. Its latest-release badge points to `v2.2.19` despite `v3.0.8` being available, so do not rely solely on that badge.

Verified configuration-copy action: [commit 042023699388269110326b9f1df4abba8cbd2923](https://github.com/SurePassId/copy-web-env-files/tree/042023699388269110326b9f1df4abba8cbd2923) declares `runs.using: node24`. Its source passes the supplied destination directly to Node's filesystem API, so an absolute Windows path under `runner.temp` is supported. It reads from `environment-files/<deployment-environment>` relative to the checked-out application and copies only `web.config`, `ApplicationInsights.config`, and `site.lic` (the last into `bin`). Preserve that checkout working directory and `DEPLOY_ENV=prod`.

Limitations: The action does not create destination directories or clean them. Missing source files are skipped; a missing environment directory only produces a warning. Its asynchronous copy callbacks ignore errors and can log success when copying failed, so a green action result alone does not prove configuration was copied. Initialize the destination and any required `bin` directory in the build workflow, and inspect the expected copied files during the first stage run. This is source-level compatibility verification, not a live runner test or dependency security audit. The action repository was not modified.

Recommended fix: Update the actions and test the selected releases together with recursive SSH checkout, restore, build, artifact transfer, and deployment. Leave the automatically updated runner unchanged unless an actual compatibility issue occurs.

### F3: Overlapping Runs Can Deploy Older Builds After Newer Builds

Severity: Medium.

None of the four stage callers has concurrency control. Pushes and manual dispatches can overlap and deploy to the same application's slots. Its two regions could also end up on different releases if runs interleave or one deployment fails.

Recommended fix: Add caller-level concurrency keyed to the application and target environment, covering both regional deployments. Use `cancel-in-progress: false` to avoid interrupting an active deployment. Use distinct groups if additional locking is added inside reusable workflows.

Selected policy (Q4: B): Serialize each application's stage runs without canceling active deployments. Do not add obsolete-run checks; allow deliberate redeployment of older tagged commits. Different applications may deploy independently once their targets are confirmed to be distinct. GitHub concurrency is repository-scoped, so it cannot protect a shared target across repositories; resolve the ServicePass/MFA target overlap in F6 before rollout. This serialization does not reserve a slot during manual validation before a swap.

### F4: Manual Dispatch Is Not Restricted to the Stage Branch

Severity: Medium, subject to existing environment restrictions.

The `push.branches` filter restricts push-triggered runs only. Manual dispatch can select another ref while the destination remains the production apps' stage slots. Existing GitHub environment rules might already block this; they were not inspected.

Selected fix (Q3): In all four callers, replace the `release/stage` push trigger with the tag filter `stage-*` and remove unrestricted `workflow_dispatch`. Restrict each application's two GitHub stage environments to matching tags, not branches, without required reviewers or wait timers. Existing tag-triggered runs can still be retried. Keep this trigger policy in the callers rather than hard-coding it into shared workflows used by other applications. Protect stage tags against updates and deletion while allowing both team members to create them; never move or reuse them.

### F5: Deployment Download Directory Has No Explicit Cleanup

Severity: Medium.

The deployment workflow downloads into `./deplotment-package` and deploys that directory. It does not check out or clean the workspace first. On a reused runner workspace, files absent from the new artifact could remain in the destination and be deployed.

Recommended fix: Download into an explicitly initialized, job-specific directory under `runner.temp` and use that exact path for deployment. Cleanup must be limited to the directory owned by that job.

The spelling `deplotment-package` is consistent between download and deployment and is not itself a functional bug.

### F6: ServicePass Originally Targeted MFA Slots

Severity: High; deployment blocker until the caller is corrected.

The originally reviewed ServicePass caller built `SurePassSelfServiceApp/SurePassSelfServiceApp.csproj`, but set `APP: mfa` and passed `APP_MFA_PROD_EUS2_STAGE_PUBLISHPROFILE` and `APP_MFA_PROD_WUS3_STAGE_PUBLISHPROFILE`. The shared deploy workflow therefore named the MFA apps as its targets. If those secrets contained the expected MFA profiles, a ServicePass deployment could overwrite the MFA stage slots.

Confirmed targets (Q9): Set `APP: servicepass` and deploy to the `stage` slots of `app-servicepass-prod-eus2` and `app-servicepass-prod-wus3`. The user confirmed the identifier, publish-profile secret names, and regional mapping, and supplied an image showing both apps and their stage slots.

Required fix: Correct the caller's application identifier and use the user-confirmed ServicePass stage-slot publish-profile secrets instead of the MFA references. No separate secret-verification prerequisite is required; troubleshoot publishing issues during the first stage run. Do not assume repository-level concurrency prevents this cross-repository conflict.

### F7: SAML2 and ServicePass Originally Used Legacy Output Commands

Severity: Medium.

Both originally reviewed callers used `::set-output` to pass application and build settings between jobs. Replace these legacy commands with writes to `$env:GITHUB_OUTPUT`, following the existing MFA and API callers. Verify all five outputs reach the shared workflows unchanged, except the confirmed ServicePass target correction.

### F8: API Build Has an Obsolete Artifact Upload and SDK Configuration

Severity: High for artifact delivery; SDK compatibility requires verification.

The API caller invokes the shared .NET 6 build, which uses `actions/upload-artifact@v3`; the shared deploy workflow downloads with `actions/download-artifact@v4`. Upload v3 is retired on GitHub.com and its artifact format is not compatible with download v4. Update upload and download to a compatible supported pair before deployment.

The build explicitly sets up SDK `6.0.x`, while the API project is confirmed to target `net8.0`. Update the existing [reusable .NET 8 build](.github/workflows/build-dot-net8.yaml), including its obsolete artifact upload action, and switch the API caller to it. Keep the application's target framework unchanged. The API publish path is under `DOTNET_ROOT`; give it a job-owned temporary output path consistent with the isolation plan.

### Additional Hardening and Verification Gaps

- **H1: Mutable dependencies.** Reusable workflows and `copy-web-env-files` reference `@main`; action major tags are mutable too. Pin selected revisions to full commit SHAs, with readable version comments. Either team member can update the pins after compatibility checks; no formal review is required.
- **H2: Missing-output handling.** Artifact upload omits `if-no-files-found: error`, so an empty output can produce a warning rather than fail the build at the source. Add the setting; inspect the package during the first stage run instead of adding custom file-validation logic.
- **H3: No tests or health checks in the reviewed chain.** The build goes directly to deployment, and action success is not an application health check. Accepted under Q6: C. Keep manual application validation for both stage slots before promotion; do not add automated application test or health-check gates in this scope. Other repository workflows may already provide tests; their coverage was not assessed here. Workflow and build verification in this plan still applies.

## Remediation Plan

This is the minimum implementation path. Preserve the resolved decisions, existing application target frameworks, `Release` builds, `DEPLOY_ENV=prod`, artifact naming (`app-${APP}-${SLOT}`), and the manual validation-then-swap process. No direct production deployments or automatic swaps.

Removed from the required work: formal reviews and approval gates, fleet-wide runner and consumer inventories, synthetic stale-file/concurrency/failure exercises, custom package-validation and reporting code, formal validation/rollback documents, and broader consumer rollout. Use focused configuration checks and the first stage runs instead. No new application tests or automated health checks are required.

### Phase 1: Check Blocking Prerequisites

1. [x] Check `copy-web-env-files` at `042023699388269110326b9f1df4abba8cbd2923`: declares Node 24 and supports absolute Windows publish paths. Source inspection complete; destination directories must exist, and ignored copy errors require checking the copied files during the first stage run (F2).
2. [x] ServicePass stage-slot publish-profile secret names and regional mapping confirmed by the user. Use `APP: servicepass` with `app-servicepass-prod-eus2/stage` and `app-servicepass-prod-wus3/stage`; do not reuse the MFA profiles. ServicePass Stage and production are now on hold.

### Phase 2: Fix the Shared Workflows

1. [x] Update and SHA-pin actions in the shared Framework build, [reusable .NET 8 build](.github/workflows/build-dot-net8.yaml), and shared deployment workflow: checkout `v7.0.1`, setup-nuget `v4.0`, setup-msbuild `v3`, setup-dotnet `v6.0.0`, upload-artifact `v7.0.2`, download-artifact `v8.0.2`, and webapps-deploy `v3.0.8`. Pin the configuration-copy action to `042023699388269110326b9f1df4abba8cbd2923`. Release SHAs and applicable inputs were checked; preserve SDK `8.0.x`, the application's `net8.0` target, and existing workflow contracts. Local diff/editor checks completed; item 2 removed the `DOTNET_ROOT` warnings. API subsequently moved to the modern .NET 10 build workflow; live results are recorded in Phase 4.
2. [x] Initialize unique publish/download directories under `runner.temp`, using run ID, run attempt, job identity, and a GUID to distinguish repeated reusable-workflow calls. Pass the publish directory through step outputs to build, configuration copy, and upload; use the download directory for deployment. Create `bin` before configuration copying, clean only the created directory with an `always()` step, and set `if-no-files-found: error` on both uploads. Actual directory-management scripts passed local execution checks, including paths with spaces and scoped cleanup; all three workflows had no editor diagnostics, and whitespace checks passed. Subsequent Stage build and deployment results are recorded in Phase 4.
3. [x] Preserve reusable workflow inputs, secrets, artifact names, and deployment target expressions. Checked the four stage callers and MFA preview: their interfaces remain compatible with the shared workflows. At this step, the API .NET 6 selection, ServicePass target references, and legacy output commands were left for the Phase 3 caller updates. No additional contract incompatibility was found.

### Phase 3: Update the Four Callers and Tag Tasks

1. [x] Set all four callers to `push.tags: ['stage-*']`, removed `workflow_dispatch`, and added caller-level `stage-${{ github.repository }}` concurrency with `cancel-in-progress: false`, covering both regions. Recursive checkout retains the tagged commit and recorded submodules; no obsolete-run checks were added. GitHub permits one running and one pending run per group; a newer pending run replaces the previous pending run, so this is not a FIFO queue of every tag.
2. [x] Switched the API stage caller to the updated .NET 8 build workflow; it was subsequently updated to the modern workflow with `DOTNET_VERSION: '10.0.x'`. Replaced SAML2 and ServicePass `::set-output` commands with `$env:GITHUB_OUTPUT`; local execution checks passed for all five outputs in each of the four callers. Corrected ServicePass to `APP: servicepass`; its caller now uses `APP_SVCPASS_PROD_EUS2_STAGE_PUBLISHPROFILE` and `APP_SVCPASS_PROD_WUS3_STAGE_PUBLISHPROFILE`, corrected after the original `APP_SCVPASS` spelling. Secret availability was not independently verified and ServicePass is on hold. No secret values were requested or changed.
3. [x] Extended the tag script with `stage-<yyyy.MM.dd-HH.mm.ss>` in UTC and updated its help/completion message. Preserved sandbox formats, signing, upstream-push guards, and duplicate-tag checks. Added `AppSuite: MFA Server: stage`, `AppSuite: API Server: stage`, `AppSuite: SAML2 Server: stage`, and `AppSuite: ServicePass: stage`, each using its own repository. Script parsing and tag-name checks passed for all four environments without invoking Git; the script and tasks have no editor diagnostics.
4. [x] Configured and read back all eight regional stage environments, including newly created ServicePass environments: each allowed only a `stage-*` policy of type `tag`, with no reviewers, wait timers, or approval gates. Created and verified active `Protect stage tags` rulesets in MFA (`24687866`), API (`24687871`), SAML2 (`24687876`), and ServicePass (`24687883`): `refs/tags/stage-*`, update/deletion restrictions, no bypass actors, and no creation restriction. Sandbox and unrelated environments were left unchanged. These are the recorded settings from the original rollout; they were not changed during the pin normalization.

### Phase 4: Verify and Run Stage

1. [x] Validated all seven originally changed workflow files with a YAML parser and editor diagnostics; checked configured inputs against metadata from all eight pinned action revisions. Verified all four callers against the local reusable-workflow input/secret contracts, output references, project paths, regional targets, artifact names/paths, and workflow-level concurrency. Executed each caller's output block and confirmed all five exact values. Parsed workspace/task JSONC and resolved all four stage-task working directories to the intended repositories; all six existing sandbox tasks remained. Parsed the tag script and executed only its naming assignments: UTC stage and legacy tag formats and completion messages passed, without invoking Git. Exact tag-only trigger configuration excludes branch pushes, and glob checks rejected `deploy2alpha-*`, `deploy2dev-*`, and `deploy2sandbox-*`. ServicePass secret availability was not tested. These were the original static checks; subsequent live results are listed above.
2. [x] Originally published shared-workflow changes on `docs/stage-deployment-remediation-plan` and pinned all twelve build/regional-deploy references to full commit SHA `f181b9308c3df3776eae8de142d17a27ba8b9052`. Verified that the commit and all three referenced workflow files exist on GitHub and match the validated local versions; exact-change checks confirmed no caller content changed beyond the pins. Committed and pushed the callers: MFA `3d3ee9dc` on `release/2026.4`, API `6df75db` on `release/2025.4`, SAML2 `27ec1ae` on `release/2026.4`, and ServicePass `a3b0d84` on `release/2025.3`. The pins changed again afterward. The normalization to `f2ac807` is now committed and pushed as recorded in Current rollout status. The shared branch remains unmerged; a later merge affects existing `@main` consumers, including MFA preview.
3. [x] Resolved for stage rollout: a retained rollback artifact is not a prerequisite for stage testing. If a stage candidate fails, fix it and publish again. Identifying the previous working version and compatible configuration for recovery is deferred until production promotion and remains the deploying person's responsibility; no rollback artifact has been verified by this step. No new rollback system or formal runbook is required.
4. [x] MFA, API, and SAML2 have successful tag-triggered Stage runs, with successful build and both regional deployment jobs; see the linked runs above. ServicePass verification is skipped while it is on hold. The newly published caller normalization has not itself been run.
5. [x] On 2026-11-23, the user confirmed that manual application validation in both Stage regions was complete. Production promotion is separate; no production swap is asserted by this record. On any future deployment or validation failure, stop promotion; the person deploying can retry or roll back without waiting for another person. Do not automate recovery or deploy another candidate between validation and swap.

Completion criteria for the current Stage rollout: MFA, API, and SAML2 have successful Stage runs and manual validation in both regions. ServicePass is excluded while on hold; no verification is required for it now. Caller pin normalization is published; merging the shared branch into `main` remains the only outstanding Stage source-control step. Production slot swaps and production-promotion recovery preparation are outside this plan. No unrelated repository rollout or additional test infrastructure is required.

## Resolved Questions and Decisions

All nine planning questions are resolved. Recorded answers below incorporate the two-person, no-approval operating model; unselected options are retained for reference. Current implementation and verification status is summarized above. Either team member can perform release operations when ready, without a separate reviewer or approver. This document update does not itself execute those operations.

### Q1: Which Action Upgrade Strategy Should We Use? (Resolved)

- **A (recommended):** Upgrade to the verified current releases with action compatibility checks, using full commit SHA pins with version comments. No separate runner prerequisite is required (Q2).
- **B:** Upgrade incrementally through intermediate majors when a specific compatibility blocker requires it.
- **C:** Defer action upgrades and implement directory isolation first; record a follow-up owner and date.

Answer: A

### Q2: How Should Runner Maintenance Be Handled? (Resolved)

- **A (selected, as clarified):** Automatic updates are already enabled. Leave the runner unchanged unless an actual compatibility issue occurs; no separate verification task or scheduled maintenance window is required.
- **B:** Validate on a separate updated runner before changing the existing build runner.
- **C:** Do not change runners; document their versions and select compatible action versions or defer blocked upgrades.

Answer: Automatic runner updates are already enabled. No action is needed for the runner. Investigate only if an upgraded action encounters an actual runner/OS compatibility error; do not treat this as an unresolved prerequisite.

### Q3: How Should Tags Trigger Stage Deployment? (Resolved)

- **A (recommended, selected):** Push a new `stage-<UTC timestamp>` tag to build and deploy its commit to both stage slots. Replace the branch trigger and remove unrestricted manual dispatch.
- **B:** Create a `stage-<UTC timestamp>` tag, then manually select that tag for deployment instead of deploying on tag push.

Answer: A. Use `stage-<yyyy.MM.dd-HH.mm.ss>` in UTC with the trigger `stage-*` in all four application repositories. Extend the existing deployment-tag script and add one stage task per application. Keep sandbox tags unchanged. Never move or reuse stage tags. Validate the deployed stage slots, then promote them using the existing swap process; no direct production deployment or rebuild.

### Q4: How Should Overlapping and Obsolete Runs Be Handled? (Resolved)

- **A:** Serialize whole stage runs without canceling active deployments; skip obsolete runs before deployment, with an explicit manual rollback exception.
- **B (recommended, selected):** Serialize each application's stage runs without canceling active runs. Do not add obsolete-run checks; permit older selected commits and reruns.
- **C:** Cancel superseded runs automatically; accept the risk of interruption between the two regional deployments.

Answer: B. Serialize each application's stage runs without canceling active runs or adding obsolete-run checks. Correct the known ServicePass/MFA target overlap; a broad inventory of other deployment workflows is not required for this implementation.

### Q5: How Should Shared Workflow and Custom Action Updates Be Adopted? (Resolved)

- **A (selected, clarified):** Pin verified full commit SHAs. Either team member can update pins after compatibility checks, without peer review or sign-off.
- **B:** Use versioned release tags for shared components and major tags for external actions; accept tag mutability.
- **C:** Keep `@main` for internal components so changes propagate immediately; accept the wider change impact.

Answer: A. Keep full commit SHA pins for reproducibility. Either team member can select compatible versions and update the pins directly; no formal review process or approval is required.

### Q6: Which Automated Validation Should Gate Deployment? (Resolved)

- **A (recommended):** Run an agreed existing test subset before deployment and bounded health/version checks on both stage slots afterward.
- **B:** Add post-deployment health checks now and schedule test integration separately.
- **C:** Keep manual validation for now and explicitly accept the lack of automated application verification.

Answer: C. Keep manual application validation for both stage slots before promotion. Accept the absence of automated application verification; do not add application test or health-check gates in this plan.

### Q7: How Should a Partial Regional Failure Be Handled? (Resolved)

- **A (selected, clarified):** Fail the run and report each region's result. The person deploying can retry or roll back using a retained known-good artifact, without another person's approval.
- **B:** Design automatic coordinated rollback as separate work, including configuration and data-compatibility checks.
- **C:** Permit temporary regional version differences and manually retry only the failed region.

Answer: A, as later clarified in Phase 4: fail the run on a regional deployment failure and report each region's result. The person deploying decides and performs retry or rollback without a separate approval. A retained rollback artifact is not a prerequisite for Stage testing; identify the previous working version and compatible recovery configuration before production promotion. Do not automate rollback. A problem discovered during manual application validation blocks promotion and follows the same recovery approach.

### Q8: What Is the Implementation and Rollout Scope? (Resolved)

- **A (selected, clarified):** Implement in all four stage callers, the Framework and selected API shared build workflows, shared deployment workflow, deployment-tag script, and four workspace stage tasks. Validate affected consumers; either team member can deploy when ready without formal review or approval gates.
- **B:** Implement and validate workflow changes only; leave runner maintenance, GitHub settings, and all deployments to the user.
- **C:** Expand adoption beyond these four applications in a separately agreed rollout plan.

Answer: A. Apply the two-person operating model: push the stage tag when ready, validate both slots, then swap using the existing process. No peer review, mandatory pull request, or separate deployment approval is required.

### Q9: Which Deployment Targets Should ServicePass Use? (Resolved)

At the time of review, the caller used `APP: mfa` and MFA publish-profile secret names while building ServicePass.

- **A (recommended):** Use dedicated ServicePass apps and stage slots. Provide the correct `APP` identifier, app names for `eus2` and `wus3`, and publish-profile secret names.
- **B:** Sharing the MFA targets is intentional. Explain the hosting arrangement before implementation; separate repository concurrency groups will not coordinate writes to a shared slot.
- **C:** Update the caller as part of this plan, but keep ServicePass live deployment disabled until its targets are confirmed.

Answer: A. Set `APP: servicepass`. The confirmed targets are `app-servicepass-prod-eus2` (slot `stage`) and `app-servicepass-prod-wus3` (slot `stage`), as shown in the supplied image. The caller's MFA references were corrected. As of 2026-11-23, ServicePass Stage and production are on hold, and live verification is skipped.
