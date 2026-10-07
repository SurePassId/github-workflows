# Stage Deployment Workflow Review and Remediation Plan

Review date: 2026-10-07

Status: Planning decisions resolved (Q1-Q9). The plan reflects the recorded answers; technical prerequisites still require verification during implementation. No workflow changes, runner updates, or deployments have been performed. This update is documentation only; commits, pushes, and live deployments require explicit approval.

## Scope

The plan covers all four application stage deployment callers and their shared build/deployment workflows:

- [Legacy MFA stage caller](../SurePassIdLegacyMfaServer/.github/workflows/deploy-stage.yaml)
- [API Server stage caller](../SurePassIdApiServer/.github/workflows/deploy-stage.yaml)
- [SAML2 stage caller](../SAML2_IdP/.github/workflows/deploy-stage.yaml)
- [ServicePass stage caller](../ServicePass/.github/workflows/deploy-stage.yaml)
- [Reusable .NET Framework build](.github/workflows/build-dot-net-fwk.yaml)
- [API caller&#39;s current reusable .NET build](.github/workflows/build-dot-net6.yaml)
- [Reusable App Service deployment](.github/workflows/deploy-to-app-service.yaml)

Each caller builds its application once and deploys the same artifact to that application's `stage` slots in `eus2` and `wus3`. The intended application identifiers are `mfa`, `api`, `saml2`, and `servicepass`. ServicePass currently specifies `mfa`; change it to the confirmed `servicepass` identifier during implementation (F6 and Q9). `DEPLOY_ENV=prod` selects production configuration; it does not mean the workflow targets the production slot. Preserve this distinction.

Approved Q3 direction: Replace the branch trigger with tags named `stage-<yyyy.MM.dd-HH.mm.ss>` using UTC, for example `stage-2026.10.07-14.30.00`. Pushing a new tag builds its commit and deploys to both stage slots. After validation, the existing slot-swap process promotes that deployed build to production; there is no direct production deployment or rebuild. Do not deploy another candidate between validation and the swap.

Reuse [the deployment-tag script](../../scripts/tag-deploy.ps1) and add one stage task per application to [the workspace tasks](../../.vscode/tasks.json). Each task runs in its application's repository: MFA Server, API Server, SAML2 Server, or ServicePass. A tag push deploys only the application in that repository, not all four applications. Existing `deploy2alpha-*`, `deploy2dev-*`, and `deploy2sandbox-*` tags remain unchanged; `stage-*` does not match the sandbox convention `deploy2*`.

This was a static review of local files plus upstream action releases. The called workflows use `@main`, so their executed remote revisions may differ from the local copies. Runner versions, runner topology, environment protections, and the private `copy-web-env-files` implementation were not verified.

## Findings

### F1: Shared Publish Directory Can Contaminate Artifacts

Severity: High.

The build sets `_PackageTempDir` to `\published\`, overlays configuration in `/published`, and uploads `/published/**`. This drive-root directory is outside the checkout and has no explicit cleanup in the workflow.

On a persistent self-hosted runner, leftover files could enter a later artifact. If multiple runner instances share the same drive, concurrent builds could also write into the same directory. Confirm whether the MSBuild target or custom action performs any cleanup; the workflow itself does not guarantee isolation.

Recommended fix: Use an explicitly initialized, job-specific directory under `runner.temp`. Include run ID, run attempt, and job identity in its name. Pass the same absolute path to MSBuild, configuration copying, and artifact upload. Verify that the custom action accepts this path before changing callers.

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

These are a dated release snapshot, not an instruction to upgrade without compatibility checks. Recheck release notes and resolve approved releases to commit SHAs during implementation.

The table above covers the originally reviewed Framework build and shared deploy actions. The newly included API build also uses `actions/checkout@v3`, `actions/setup-dotnet@v2`, and `actions/upload-artifact@v3`. Include these in the action update inventory, verify the current `setup-dotnet` release, and resolve the artifact incompatibility described in F8.

Current checkout uses Node 24 and documents a minimum Actions runner version of `2.327.1`. Its authenticated Git support inside Docker container actions has an additional `2.329.0` requirement, if applicable. Verify all selected actions' runner and operating-system requirements; do not treat checkout's minimum as a complete compatibility assessment. Updating an action's Node runtime does not require upgrading the application's .NET Framework target.

Azure continues to publish `v2` maintenance releases. Its latest-release badge points to `v2.2.19` despite `v3.0.8` being available, so do not rely solely on that badge. The private `copy-web-env-files` action's release and runtime status remain unverified.

Recommended fix: Update the runner first if necessary, then test the approved action releases together with recursive SSH checkout, restore, build, artifact transfer, and deployment.

### F3: Overlapping Runs Can Deploy Older Builds After Newer Builds

Severity: Medium.

None of the four stage callers has concurrency control. Pushes and manual dispatches can overlap and deploy to the same application's slots. Its two regions could also end up on different releases if runs interleave or one deployment fails.

Recommended fix: Add caller-level concurrency keyed to the application and target environment, covering both regional deployments. Use `cancel-in-progress: false` to avoid interrupting an active deployment. Use distinct groups if additional locking is added inside reusable workflows.

Selected policy (Q4: B): Serialize each application's stage runs without canceling active deployments. Do not add obsolete-run checks; allow deliberate redeployment of older tagged commits. Different applications may deploy independently once their targets are confirmed to be distinct. GitHub concurrency is repository-scoped, so it cannot protect a shared target across repositories; resolve the ServicePass/MFA target overlap in F6 before rollout. This serialization does not reserve a slot during manual validation before a swap.

### F4: Manual Dispatch Is Not Restricted to the Stage Branch

Severity: Medium, subject to existing environment restrictions.

The `push.branches` filter restricts push-triggered runs only. Manual dispatch can select another ref while the destination remains the production apps' stage slots. Existing GitHub environment rules might already block this; they were not inspected.

Selected fix (Q3): In all four callers, replace the `release/stage` push trigger with the tag filter `stage-*` and remove unrestricted `workflow_dispatch`. Restrict each application's two GitHub stage environments to matching tags, not branches. Existing tag-triggered runs can still be retried. Keep this trigger policy in the callers rather than hard-coding it into shared workflows used by other applications. Protect stage tags against updates and deletion; never move or reuse them.

### F5: Deployment Download Directory Has No Explicit Cleanup

Severity: Medium.

The deployment workflow downloads into `./deplotment-package` and deploys that directory. It does not check out or clean the workspace first. On a reused runner workspace, files absent from the new artifact could remain in the destination and be deployed.

Recommended fix: Download into an explicitly initialized, job-specific directory under `runner.temp` and use that exact path for deployment. Cleanup must be limited to the directory owned by that job.

The spelling `deplotment-package` is consistent between download and deployment and is not itself a functional bug.

### F6: ServicePass Currently Targets MFA Slots

Severity: High; deployment blocker until the caller is corrected and the publish-profile secret mapping is confirmed.

The ServicePass caller builds `SurePassSelfServiceApp/SurePassSelfServiceApp.csproj`, but sets `APP: mfa` and passes `APP_MFA_PROD_EUS2_STAGE_PUBLISHPROFILE` and `APP_MFA_PROD_WUS3_STAGE_PUBLISHPROFILE`. The shared deploy workflow therefore names the MFA apps as its targets. If those secrets contain the expected MFA profiles, a ServicePass deployment could overwrite the MFA stage slots.

Confirmed targets (Q9): Set `APP: servicepass` and deploy to the `stage` slots of `app-servicepass-prod-eus2` and `app-servicepass-prod-wus3`. The user confirmed the identifier and supplied an image showing both apps and their stage slots. Publish-profile secret names remain unconfirmed.

Required fix: Correct the caller's application identifier and use the confirmed ServicePass stage-slot publish-profile secrets instead of the MFA references. Verify the secret mapping and target separation before any live tag push. Do not guess secret names or assume repository-level concurrency prevents this cross-repository conflict.

### F7: SAML2 and ServicePass Use Legacy Output Commands

Severity: Medium.

Both callers use `::set-output` to pass application and build settings between jobs. Replace these legacy commands with writes to `$env:GITHUB_OUTPUT`, following the existing MFA and API callers. Verify all five outputs reach the shared workflows unchanged, except any approved ServicePass target correction.

### F8: API Build Has an Obsolete Artifact Upload and SDK Configuration

Severity: High for artifact delivery; SDK compatibility requires verification.

The API caller invokes the shared .NET 6 build, which uses `actions/upload-artifact@v3`; the shared deploy workflow downloads with `actions/download-artifact@v4`. Upload v3 is retired on GitHub.com and its artifact format is not compatible with download v4. Update upload and download to a compatible supported pair before deployment.

The build explicitly sets up SDK `6.0.x`. Verify the API project's current target framework and SDK requirements before selecting the appropriate shared build workflow or updating SDK setup. Do not rely on the hosted runner incidentally having a newer SDK, and do not upgrade the application's target framework as part of this plan. The API publish path is under `DOTNET_ROOT`; give it a job-owned temporary output path consistent with the isolation plan.

### Additional Hardening and Verification Gaps

- **H1: Mutable dependencies.** Reusable workflows and `copy-web-env-files` reference `@main`; action major tags are mutable too. Pin approved revisions to full commit SHAs, with readable version comments and a deliberate update process.
- **H2: Missing-output handling.** Artifact upload omits `if-no-files-found: error`, so an empty output can produce a warning rather than fail the build at the source. Add the setting; inspect the package during the first approved stage run instead of adding custom file-validation logic.
- **H3: No tests or health checks in the reviewed chain.** The build goes directly to deployment, and action success is not an application health check. Accepted under Q6: C. Keep manual application validation for both stage slots before promotion; do not add automated application test or health-check gates in this scope. Other repository workflows may already provide tests; their coverage was not assessed here. Workflow and build verification in this plan still applies.

## Remediation Plan

This is the minimum implementation path. Preserve the resolved decisions, existing application target frameworks, `Release` builds, `DEPLOY_ENV=prod`, artifact naming (`app-${APP}-${SLOT}`), and the manual validation-then-swap process. No direct production deployments or automatic swaps.

Removed from the required work: fleet-wide runner and consumer inventories, synthetic stale-file/concurrency/failure exercises, custom package-validation and reporting code, formal validation/rollback documents, and broader consumer rollout. Use focused configuration review and the first approved stage runs instead. No new application tests or automated health checks are required.

### Phase 1: Check Blocking Prerequisites

1. [ ] Verify the selected actions' runner/OS requirements and the API project's required SDK. Keep automatic runner updates enabled; intervene only if incompatible. Do not change application target frameworks.
2. [ ] Check the selected `copy-web-env-files` revision for runtime compatibility and support for the new absolute publish path.
3. [ ] Confirm the ServicePass stage-slot publish-profile secret names and their regional mapping. Use `APP: servicepass` with `app-servicepass-prod-eus2/stage` and `app-servicepass-prod-wus3/stage`; do not reuse the MFA profiles.

### Phase 2: Fix the Shared Workflows

1. [ ] Update the actions to verified compatible releases, including a compatible artifact upload/download pair. Select the API build workflow/SDK for its existing target framework. Pin actions and the configuration-copy action to verified full commit SHAs (Q1 and Q5).
2. [ ] Use initialized, job-specific `runner.temp` directories for publishing and artifact download. Pass the same publish path through build, configuration copy, and upload; deploy from the download path. Clean only job-owned directories and add `if-no-files-found: error` to uploads.
3. [ ] Preserve reusable workflow inputs, secrets, and artifact contracts except for the approved ServicePass caller correction. Review known affected call sites for compatibility; expand testing only if an actual contract or behavior incompatibility is found.

### Phase 3: Update the Four Callers and Tag Tasks

1. [ ] Set all four callers to `push.tags: ['stage-*']`, remove `workflow_dispatch`, and add per-application stage concurrency with `cancel-in-progress: false`. Build the tagged commit and its recorded submodules; do not add obsolete-run checks.
2. [ ] Replace SAML2 and ServicePass `::set-output` commands with `$env:GITHUB_OUTPUT`. Correct ServicePass's `APP` and regional secret references using Phase 1's confirmed mapping.
3. [ ] Extend the tag script with `stage-<yyyy.MM.dd-HH.mm.ss>` in UTC and update its help/completion message. Preserve sandbox formats, signing, upstream-push guards, and duplicate-tag checks. Add `AppSuite: MFA Server: stage`, `AppSuite: API Server: stage`, `AppSuite: SAML2 Server: stage`, and `AppSuite: ServicePass: stage`, each using its own repository.
4. [ ] Ensure each application's GitHub stage environments allow only `stage-*` tags and stage tags are protected against updates/deletion. Change settings only where necessary; leave sandbox triggers unchanged.

### Phase 4: Verify and Run Stage

1. [ ] Check workflow syntax, action inputs, job outputs, target/secret mappings, and concurrency settings for the touched workflows. Check script tag generation and task working directories without creating or pushing tags; confirm branch pushes and `deploy2*` tags cannot trigger stage.
2. [ ] Review the changes before requesting commit/push approval. With explicit approval, publish shared-workflow changes first, then pin all four callers to the published full commit SHA. Each application tag must include its updated caller; no caller may reference an unpublished commit.
3. [ ] Before live rollout, identify a retained known-good artifact and compatible configuration for operator-approved rollback. Use existing retention if sufficient; no new rollback system or formal runbook is required.
4. [ ] With explicit deployment approval, run one stage deployment per application. Confirm checkout, build, configuration copy, package contents, and artifact transfer succeed and that both regions receive the same application artifact. Inspect configuration without logging secrets. Use the existing regional job results to report failures; do not suppress failures or add custom reporting.
5. [ ] Manually validate each application's version and operation in both stage slots before the existing production swap. On any deployment or validation failure, stop promotion and obtain operator approval for retry or rollback; do not automate recovery. Do not deploy another candidate between validation and swap.

Completion criteria: All four tag-triggered workflows build and deploy correctly to their intended stage slots, using compatible pinned dependencies and isolated directories. Both regions pass manual validation before promotion. No unrelated repository rollout or additional test infrastructure is required.

## Resolved Questions and Decisions

All nine planning questions are resolved. Recorded answers below control the plan; unselected options are retained for reference. Resolution does not mean implementation or verification is complete, and does not authorize commits, pushes, or live deployments. Blocking compatibility and secret checks are in Phase 1; essential rollback readiness is in Phase 4. The streamlined checklist above replaces the earlier broad inventories and extended validation tasks.

### Q1: Which Action Upgrade Strategy Should We Use? (Resolved)

- **A (recommended):** Upgrade to the verified current releases after runner and compatibility validation, using full commit SHA pins with version comments.
- **B:** Upgrade incrementally through intermediate majors when a specific compatibility blocker requires it.
- **C:** Defer action upgrades and implement directory isolation first; record a follow-up owner and date.

Answer: A

### Q2: How Should Runner Maintenance Be Handled? (Resolved)

- **A (selected, as clarified):** Keep automatic updates enabled, verify compatibility, and intervene only if necessary while the runner is idle. No scheduled maintenance window is required.
- **B:** Validate on a separate updated runner before changing the existing build runner.
- **C:** Do not change runners; document their versions and select compatible action versions or defer blocked upgrades.

Answer: Keep automatic runner updates enabled. Verify the installed version meets the upgraded actions' requirements; intervene only if needed. No scheduled maintenance window is required.

### Q3: How Should Tags Trigger Stage Deployment? (Resolved)

- **A (recommended, selected):** Push a new `stage-<UTC timestamp>` tag to build and deploy its commit to both stage slots. Replace the branch trigger and remove unrestricted manual dispatch.
- **B:** Create a `stage-<UTC timestamp>` tag, then manually select that tag for deployment instead of deploying on tag push.

Answer: A. Use `stage-<yyyy.MM.dd-HH.mm.ss>` in UTC with the trigger `stage-*` in all four application repositories. Extend the existing deployment-tag script and add one stage task per application. Keep sandbox tags unchanged. Never move or reuse stage tags. Validate the deployed stage slots, then promote them using the existing swap process; no direct production deployment or rebuild.

### Q4: How Should Overlapping and Obsolete Runs Be Handled? (Resolved)

- **A:** Serialize whole stage runs without canceling active deployments; skip obsolete runs before deployment, with a separately approved rollback exception.
- **B (recommended, selected):** Serialize each application's stage runs without canceling active runs. Do not add obsolete-run checks; permit older selected commits and reruns.
- **C:** Cancel superseded runs automatically; accept the risk of interruption between the two regional deployments.

Answer: B. Serialize each application's stage runs without canceling active runs or adding obsolete-run checks. Correct the known ServicePass/MFA target overlap; a broad inventory of other deployment workflows is not required for this implementation.

### Q5: How Should Shared Workflow and Custom Action Updates Be Adopted? (Resolved)

- **A (recommended):** Pin reviewed full commit SHAs and adopt updates through explicit review changes.
- **B:** Use versioned release tags for shared components and major tags for external actions; accept tag mutability.
- **C:** Keep `@main` for internal components so changes propagate immediately; accept the wider change impact.

Answer: A. Adopt dependency updates through explicit review changes using full commit SHA pins.

### Q6: Which Automated Validation Should Gate Deployment? (Resolved)

- **A (recommended):** Run an agreed existing test subset before deployment and bounded health/version checks on both stage slots afterward.
- **B:** Add post-deployment health checks now and schedule test integration separately.
- **C:** Keep manual validation for now and explicitly accept the lack of automated application verification.

Answer: C. Keep manual application validation for both stage slots before promotion. Accept the absence of automated application verification; do not add application test or health-check gates in this plan.

### Q7: How Should a Partial Regional Failure Be Handled? (Resolved)

- **A (recommended):** Fail the run, report each region's result, and require an operator to approve retry or rollback using a retained known-good artifact.
- **B:** Design automatic coordinated rollback as a separate approved change, including configuration and data-compatibility checks.
- **C:** Permit temporary regional version differences and retry only the failed region after approval.

Answer: A. Fail the run on a regional deployment failure, report each region's result, and require operator approval for retry or rollback. No automatic rollback. Confirm the approving operator and known-good artifact retention before live rollout. A problem discovered during manual application validation blocks promotion and follows the same operator-led recovery policy.

### Q8: What Implementation and Rollout Scope Is Approved? (Resolved)

- **A (recommended):** Implement in all four stage callers, the Framework and selected API shared build workflows, shared deployment workflow, deployment-tag script, and four workspace stage tasks. Validate affected consumers; perform only explicitly approved stage deployments.
- **B:** Implement and validate workflow changes only; leave runner maintenance, GitHub settings, and all deployments to the user.
- **C:** Expand adoption beyond these four applications in a separately agreed rollout plan.

Answer: A

### Q9: Which Deployment Targets Should ServicePass Use? (Resolved)

Its current caller uses `APP: mfa` and MFA publish-profile secret names while building ServicePass.

- **A (recommended):** Use dedicated ServicePass apps and stage slots. Provide the correct `APP` identifier, app names for `eus2` and `wus3`, and publish-profile secret names.
- **B:** Sharing the MFA targets is intentional. Explain the hosting arrangement before implementation; separate repository concurrency groups will not coordinate writes to a shared slot.
- **C:** Update the caller as part of this plan, but keep ServicePass live deployment disabled until its targets are confirmed.

Answer: A. Set `APP: servicepass`. The confirmed targets are `app-servicepass-prod-eus2` (slot `stage`) and `app-servicepass-prod-wus3` (slot `stage`), as shown in the supplied image. The target decision is resolved. Verify publish-profile secret names for these slots as an implementation prerequisite; do not use the current MFA secret references or assume replacement names.
