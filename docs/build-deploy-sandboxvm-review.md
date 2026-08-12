# Review: `build-deploy-sandboxvm.yaml`

Reviewed: 2026-08-11 · **All thirteen open questions resolved 2026-08-11**

Remediation is planned in [build-deploy-sandboxvm-implementation-plan.md](build-deploy-sandboxvm-implementation-plan.md).

Line references reflect the workflow as of 2026-08-11, after the dead `SurePassId/SurePassIdMfaServer` case was removed (Q1).

## Scope

This review covers [`.github/workflows/build-deploy-sandboxvm.yaml`](../.github/workflows/build-deploy-sandboxvm.yaml), with emphasis on deployment correctness, recoverability, security, maintainability, and current GitHub Actions practices. It does not validate the application repositories, IIS configuration, runner image, or the implementation of `SurePassId/copy-web-env-files`.

## Executive summary

The workflow's repository validation and centralized configuration are useful, but the deployment path is fragile. A failed backup, copy, extraction, or restart can leave the IIS application offline; concurrent runs can alter the same site and archive simultaneously; and a release tag is created before deployment succeeds. These should be fixed before routine refactoring.

The main security improvements are to declare least-privilege token permissions, pin every action to an immutable commit SHA, avoid interpolating secrets directly into PowerShell source, and reduce the trust placed in a persistent self-hosted runner. The large repository switch and deployment script should then be moved toward explicit reusable-workflow inputs and a separately testable PowerShell script or action.

## Findings

### F1. Critical: a failed deployment can leave IIS stopped

The workflow stops the IIS site and app pool at [lines 241-248](../.github/workflows/build-deploy-sandboxvm.yaml#L241-L248), then performs backup, deletion, transfer, and extraction before restarting them at [lines 314-321](../.github/workflows/build-deploy-sandboxvm.yaml#L314-L321). There is no `try`/`finally`, rollback, or post-failure recovery. Any terminating error in between can leave the service offline. Session cleanup at [line 323](../.github/workflows/build-deploy-sandboxvm.yaml#L323) is similarly skipped on failure.

**Recommendation:** put the remote deployment in a `try`/`catch`/`finally`. Always close the PSSession, and attempt to restore/start the previous deployment in `finally` when activation fails. Prefer an atomic deployment model: extract to a versioned staging directory, validate it, switch the IIS physical path (or rename directories), health-check the application, and only then delete the prior version. Base the `finally` path on the retained previous directory rather than on a 7z archive restore, which has never been exercised end to end (Q10).

### F2. Critical: deployments are not serialized

The job has no `concurrency` declaration near [the job definition](../.github/workflows/build-deploy-sandboxvm.yaml#L37-L39). Two commits or manually re-run jobs for the same app/environment can use the same temporary archive, stop/start the same IIS site, prune the same backups, and delete or overwrite each other's files.

**Recommendation:** add a concurrency group keyed by the target rather than only the caller workflow, for example the called workflow identity, repository, environment, and app name. Use `cancel-in-progress: false` for deployments so a newer run waits instead of interrupting a deployment mid-flight.

```yaml
concurrency:
  group: sandboxvm-${{ github.repository }}-${{ github.ref_name }}-${{ inputs.DEPLOY_APP_NAME || 'default' }}
  cancel-in-progress: false
```

### F3. High: release tags are created before deployment succeeds

The release tag is generated and pushed at [lines 189-210](../.github/workflows/build-deploy-sandboxvm.yaml#L189-L210), before deployment starts at [line 215](../.github/workflows/build-deploy-sandboxvm.yaml#L215). A failed deployment therefore leaves a tag that falsely implies success. A rerun can also fail because `createRef` does not tolerate an existing tag.

The `createRef` call at [line 205](../.github/workflows/build-deploy-sandboxvm.yaml#L205) is also not awaited, so a rejected promise never fails the step — tagging can fail silently today.

**Recommendation:** create the tag only after a successful deployment and health check. Define the desired behavior for an existing tag: verify that it points to `context.sha` and treat that as idempotent, or fail with a clear version-collision error. Consider a GitHub environment deployment record or release as the auditable source of deployment status.

### F4. High: secrets are interpolated into PowerShell source

The VM username, password, and hostname are inserted directly into the script at [lines 223-225](../.github/workflows/build-deploy-sandboxvm.yaml#L223-L225). GitHub expands expressions before PowerShell parses the script. Quotes, backticks, dollar expressions, or newlines in a secret can break parsing or alter execution. Masking secrets in logs does not remove this risk.

**Recommendation:** map secrets to step environment variables and read them through `$env:`. Do the same for context or input values that enter scripts. Prefer certificate-based PowerShell remoting, a short-lived credential, or a deployment agent on the VM over a long-lived password.

```yaml
- name: Deploy to sandbox VM
  env:
    SANDBOX_VM_USERNAME: ${{ secrets.SANDBOX_VM_USERNAME }}
    SANDBOX_VM_PASSWORD: ${{ secrets.SANDBOX_VM_PASSWORD }}
    SANDBOX_VM_HOSTNAME: ${{ secrets.SANDBOX_VM_HOSTNAME }}
  run: |
    $credential = [pscredential]::new(
      $env:SANDBOX_VM_USERNAME,
      (ConvertTo-SecureString $env:SANDBOX_VM_PASSWORD -AsPlainText -Force)
    )
```

### F5. High: action references are mutable, outdated, and token permissions are implicit

The workflow uses version tags for `actions/checkout`, `microsoft/setup-msbuild`, `actions/setup-dotnet`, and `actions/github-script`, and uses the mutable `main` branch for the organization action at [line 181](../.github/workflows/build-deploy-sandboxvm.yaml#L181). A moved or compromised tag/branch changes executable code without changing this workflow. There is also no explicit `permissions` block, while tag creation at [lines 199-210](../.github/workflows/build-deploy-sandboxvm.yaml#L199-L210) requires `contents: write` on `GITHUB_TOKEN`.

`actions/checkout@v4` at [line 114](../.github/workflows/build-deploy-sandboxvm.yaml#L114) is several major versions behind; the current release is `v7.0.1` (published 2026-07-20). Reviewing the intervening majors against this workflow:

| Version | Change                                                                                                                    | Impact here                                                           |
| ------- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| v5.0.0  | `node24` runtime; requires Actions Runner **v2.327.1+**                                                                   | **Satisfied** — the runner reports 2.336.0 and self-updates (Q11, F8) |
| v6.0.0  | Credentials persist to `$RUNNER_TEMP` instead of `.git/config`                                                            | None; `persist-credentials: false` is already set                     |
| v7.0.0  | ESM migration; blocks fork-PR checkout under `pull_request_target`/`workflow_run` unless `allow-unsafe-pr-checkout: true` | None; this workflow is reached via `workflow_call` from `push`        |

The upgrade is therefore behaviorally safe for this workflow, and the runner floor is already met — there is no prerequisite work.

`SurePassId/copy-web-env-files` needs work before it can be pinned: its `action.yaml` declares `using: 'node16'`, a runtime the runner no longer honors natively, and the repository carries no tags at all — `main` has not moved since 2023-02-16. Bump it to `node24` and cut a release first.

**Recommendation:** pin every action, especially `SurePassId/copy-web-env-files`, to a reviewed full commit SHA and annotate it with the corresponding release version; a SHA pin also removes the ambiguity of floating major tags. Move `actions/checkout` to `v7.0.1`. Add an explicit `permissions` block — `contents: write` while tagging shares the single job, and no other write scopes. Once the job split in Q13 happens, narrow that to the tagging job alone. Keep in mind that callers can reduce, but cannot elevate, permissions granted to a called workflow.

Resolved commit SHAs and the remaining upgrade notes are in [build-deploy-sandboxvm-implementation-plan.md](build-deploy-sandboxvm-implementation-plan.md).

### F5a. High: the submodule credential is broader and longer-lived than necessary

Checkout authenticates recursive private submodules with `GH_ACTIONS_PAT` at [line 117](../.github/workflows/build-deploy-sandboxvm.yaml#L117). A PAT is bound to a user account, is typically valid for months, and — if it is a classic PAT — grants access to every repository that user can reach, far beyond the submodules actually required. On a persistent self-hosted runner this is a long-lived, broadly scoped credential on a shared machine.

Switching to an SSH key is **not** an improvement in this case. A deploy key authorizes exactly one repository, so it cannot cover a recursive submodule tree spanning several private repos; the alternative is a machine user's account-wide SSH key, which is broader than a fine-grained PAT and adds a user seat plus an outbound SSH egress requirement from the build VM.

| Option                        | Scope                    | Lifetime      | Verdict                           |
| ----------------------------- | ------------------------ | ------------- | --------------------------------- |
| GitHub App installation token | Per-repo, per-permission | ~1 hour       | Preferred                         |
| Fine-grained PAT              | Per-repo                 | Up to 1 year  | Acceptable                        |
| Machine-user SSH key          | Whole account            | Until rotated | Worse than a fine-grained PAT     |
| Deploy key                    | Single repo              | Until rotated | Unusable for recursive submodules |

**Recommendation:** mint a short-lived GitHub App installation token (for example via `actions/create-github-app-token`) scoped to just the submodule repositories with `contents: read`, and pass its output as checkout's `token`. Note that when `ssh-key` is not supplied, checkout rewrites `git@github.com:` submodule URLs to HTTPS, so a token works regardless of how `.gitmodules` is written. Also reconcile [README.md](../README.md), which documents `SSH_KEY` as the submodule-checkout secret while this workflow uses `GH_ACTIONS_PAT`.

`GH_ACTIONS_PAT` turns out to be a fine-grained PAT already limited to the submodule repositories (Q12), so the scope tier in the table is correct today and only lifetime is at issue. The decision is to move to the App token regardless, cutting credential validity from up to a year to roughly an hour and moving ownership off an individual account. Q12 carries the implementation outline and its caveats.

Keep `persist-credentials: false` at [line 118](../.github/workflows/build-deploy-sandboxvm.yaml#L118). The action's default is still `true`, which would write the credential into the checkout for every later step to read — precisely the wrong default on a reused runner. Nothing later in the workflow runs authenticated `git`: the tag is created through the REST API using `context.sha`.

### F6. High: destructive deployment is not validated or transactional

The destination contents are removed at [lines 278-294](../.github/workflows/build-deploy-sandboxvm.yaml#L278-L294) before the archive is copied and extracted. The workflow does not verify that the local archive exists and is valid, that the backup succeeded, that enough disk space is available, or that the extracted application is healthy. The retained files are mixed into the new release in place, which can also leave stale state.

Only the `oidc` application writes mutable state into its site directory (Q8), so every other application is a straight directory replacement and needs no merge step at all. That makes the atomic swap below simpler than the current `KEEP_LIST` logic suggests. The 7z backups, meanwhile, have been used exactly once and only to recover a single file (Q10) — plausible, but unexercised as a whole-site rollback.

**Recommendation:** fail before stopping IIS unless publish output and the archive pass validation. On the VM, stage and test extraction in a new directory, preserve mutable data outside the application directory, switch atomically, then run an HTTP health check. Retain the prior directory for rollback — that directory, not the archive, should be what `finally` restores. Validate one end-to-end archive restore separately so the backups are a known quantity. Check exit codes from 7-Zip and `appcmd` explicitly.

### F7. Medium: native command failures may not fail the step reliably

7-Zip and `appcmd` are invoked as native executables throughout the deploy script, including archive creation at [lines 234-239](../.github/workflows/build-deploy-sandboxvm.yaml#L234-L239), backup, extraction, and IIS control. Depending on the installed PowerShell version and settings, a nonzero native exit code may not become a terminating PowerShell error. The workflow can continue after a failed backup or extraction.

**Recommendation:** set strict error behavior at the start of scripts and wrap native invocations in a helper that checks `$LASTEXITCODE`. On PowerShell 7.3+, enable `$PSNativeCommandUseErrorActionPreference = $true`; retain explicit checks if runner versions vary. Replace the fixed sleeps at [line 255](../.github/workflows/build-deploy-sandboxvm.yaml#L255) and [line 280](../.github/workflows/build-deploy-sandboxvm.yaml#L280) with bounded polling for the actual site/app-pool or file-lock state.

### F8. Medium: the persistent self-hosted runner has a broad trust boundary

The job runs on a self-hosted machine at [line 39](../.github/workflows/build-deploy-sandboxvm.yaml#L39), handles deployment credentials, has private-submodule access, and can reach the deployment VM. The manual cleanup at [lines 42-45](../.github/workflows/build-deploy-sandboxvm.yaml#L42-L45) is not equivalent to a fresh runner and may miss hidden files or state outside the workspace.

**Recommendation:** restrict the workflow to trusted branches and callers; use a dedicated runner group available only to selected repositories; and prefer an ephemeral or just-in-time runner with a clean machine per job. If the runner must remain persistent, harden its service account, network egress, filesystem permissions, patching, and log retention. Replace broad pre-job deletion with controlled runner lifecycle cleanup.

The runner application itself self-updates by default and carries its own `node20`/`node24` binaries, so the `node24` requirement of `actions/checkout` v5+ (see F5) is satisfied without manual work; the installed version is 2.336.0 (Q11). What is worth periodic confirmation is that auto-update is still functioning, since it can be disabled with `--disableupdate` at config time and stops silently if the machine cannot reach the GitHub release assets host. The operating system and the installed tooling on this machine — MSBuild, 7-Zip, PowerShell — are not covered by that mechanism and still need their own patching routine.

### F9. Medium: environment selection should be an explicit deployment contract

The environment is inferred by splitting `github.ref` at [lines 50-54](../.github/workflows/build-deploy-sandboxvm.yaml#L50-L54). This couples deployment behavior to the caller event and assumes the last ref segment uniquely identifies the branch. It also prevents GitHub environment protection rules, approvals, environment-scoped secrets, and deployment history from being used because the job has no `environment` declaration.

Callers trigger on `workflow_dispatch` plus pushes to `DEPLOY/alpha`, `DEPLOY/dev`, and `DEPLOY/sandbox` (Q3). Splitting on `/` happens to yield the right value for those branches, but the result is accidental rather than designed: a `workflow_dispatch` run started from any other branch reaches the `Throw`, and the planned move to deploy tags breaks it outright — `refs/tags/deploy-to-alpha` reduces to `deploy-to-alpha`, which is not in the allowed set. The explicit input below is therefore a **prerequisite** for the tag-based trigger, not an optional cleanup.

**Recommendation:** accept a typed string input such as `deployment_environment`, validate it against the allowed values, and declare the job's GitHub environment. Have each caller pass the value explicitly instead of deriving it from the ref, which makes the trigger mechanism and the deployment target independent of one another. Move VM secrets into environment-scoped secrets where practical — noting that the `environment:` declaration itself only becomes available once the job split in Q13 happens.

### F10. Medium: repository-specific configuration is duplicated inside executable code

The long switch beginning at [line 56](../.github/workflows/build-deploy-sandboxvm.yaml#L56) combines policy, project metadata, and build/deploy behavior. Adding an application requires editing a security-sensitive workflow, and similar entries drift silently: a dead `SurePassIdMfaServer` case pointing at `SurePassIdApiServer.sln` survived a repository rename until this review found it (Q1). The reverse problem exists too — the `oidc` case's `Debug`/`Development` build looks like a bring-up leftover but is deliberate (Q5), which is exactly the kind of decision that needs a recorded reason rather than a bare switch arm.

**Recommendation:** make project path, application name, .NET kind/version, assembly path, and configuration explicit `workflow_call` inputs supplied by a small caller workflow in each repository. Validate paths against expected workspace-relative forms. If central policy is required, keep declarative metadata in a reviewed configuration file and have a script parse and validate it.

### F11. Medium: build reproducibility and efficiency can improve

The .NET path restores at [lines 159-163](../.github/workflows/build-deploy-sandboxvm.yaml#L159-L163) and then publishes without `--no-restore` at [lines 165-174](../.github/workflows/build-deploy-sandboxvm.yaml#L165-L174), allowing a second restore. It forces `--self-contained true`, increasing artifact size and deployment time, and fetches full Git history at [line 119](../.github/workflows/build-deploy-sandboxvm.yaml#L119) even though only the checked-out commit appears necessary.

`fetch-depth: 0` is likely the most expensive line in the workflow. It fetches all history for all branches and tags, and with `submodules: recursive` that cost is multiplied across every submodule. Nothing here consumes history: the version comes from reflection over the built assembly, and tagging uses `context.sha`. Compounding this, the `Clean workspace` step at [lines 42-45](../.github/workflows/build-deploy-sandboxvm.yaml#L42-L45) deletes the whole workspace on every run, which defeats checkout's incremental `git clean`/`reset` (its `clean: true` default) and forces a full re-clone of the repository and every submodule each time.

**Recommendation:** use locked dependency restoration where repositories maintain lock files, and add `--no-restore` to publish. Self-contained publishing is no longer required: the VM's ASP.NET Core 8.0 hosting bundle was updated to 8.0.30 (Q6), so publish `--self-contained false` while keeping `--runtime win-x64`. Remove `fetch-depth: 0` and take the default of `1` — no application repository uses GitVersion, Nerdbank.GitVersioning, or MinVer (Q7), so nothing consumes history. Dropping the full-history fetch, the blanket workspace deletion, and the self-contained runtime payload should remove a large share of build and deployment time; add NuGet caching only after measuring what remains.

### F12. Medium: no timeout or post-deployment health check exists

The job has no `timeout-minutes`, and remoting or native tools can hang indefinitely. Starting IIS at [lines 314-321](../.github/workflows/build-deploy-sandboxvm.yaml#L314-L321) only proves that start commands were issued, not that the application is serving traffic.

**Recommendation:** add a realistic job timeout and operation-level timeouts for remoting. The HTTP health check is deferred by decision (Q9) — health endpoints are inconsistent across the applications and not every site is reachable from the runner. Note the consequence: until it exists, the deployment has no success signal beyond `appcmd` returning, so the `finally` recovery in F1 is the only thing standing between a broken release and an offline site. Treat the timeout and recovery work as the higher priority of the two, and revisit the health check when the applications converge on a common endpoint.

### F13. Low: release metadata and diagnostics need tightening

Assembly reflection at [lines 189-194](../.github/workflows/build-deploy-sandboxvm.yaml#L189-L194) loads application code merely to read its version. Loading can fail because of dependencies or execute module initialization behavior. The temporary local archive is not removed, and typo-heavy/log-separator output makes the deployment harder to scan.

**Recommendation:** read file version metadata without loading the assembly, use unique per-run temporary paths such as `${{ github.run_id }}-${{ github.run_attempt }}`, remove temporary files in `finally`, and use GitHub log groups and step summaries for deployment details.

## Recommended target structure

Per Q13 this is the **deferred end state, not the next change** — the correctness and security fixes land in the current single job first. It is recorded here because two of them cannot be expressed in a single job at all: `environment:` protection and confining `contents: write` to tagging are both job-level settings.

1. **Validate job:** validate explicit inputs and calculate normalized deployment metadata. No secrets and read-only permissions.
2. **Build job:** clean checkout, restore, test, publish, validate output, produce a checksummed artifact. No deployment credentials.
3. **Deploy job:** use a protected GitHub environment, target-scoped concurrency, environment secrets, staged extraction, atomic activation, health check, and rollback.
4. **Tag job:** after deployment succeeds, idempotently create the release tag with only `contents: write` permission.

Separating jobs also makes failures clearer and prevents build steps from sharing a process with deployment credentials. If artifacts contain environment-specific secrets, do not upload them; instead apply non-secret configuration on the target or retrieve secrets at runtime from an approved secret store.

Two practical constraints to weigh when the split is scheduled:

- **Runner count on `windows-build-vm`.** Four jobs mean up to four runner acquisitions. With a single registered runner, a deploy job can queue behind an unrelated repository's build, turning one wait into three. Confirm the registered runner count before committing to the shape.
- **`concurrency` groups are scoped to the calling repository.** Because this is `workflow_call`, the group name is evaluated in the caller's context, so the same group string from two different application repositories is two different groups. F2 can serialize an application against itself, but it cannot serialize the four repositories that share the one VM (Q2); that serialization comes from runner count, not from `concurrency`.

The artifact handoff the split requires is much cheaper now that publishing is framework-dependent rather than self-contained (Q6) — that change is what makes this structure affordable.

## Suggested implementation order

Steps 1–7 stay inside the existing single job (Q13); step 8 is the restructure.

1. Add deployment concurrency, a job timeout, strict native exit handling, and `try`/`finally` recovery (F1, F2, F7, F12).
2. Move tagging after a successful deployment and make it idempotent (F3).
3. Map secrets to step environment variables, declare an explicit `permissions` block, and pin every action to a reviewed commit SHA — including `actions/checkout` at `v7.0.1` and `SurePassId/copy-web-env-files` (F4, F5).
4. Switch the .NET publish to `--self-contained false --no-restore`, add `--runtime win-x64` to the restore, and drop `fetch-depth: 0`. Roll out on `alpha` first and confirm the site serves (F11, Q6, Q7).
5. Replace `GH_ACTIONS_PAT` with a GitHub App installation token and reconcile [README.md](../README.md) in the same change (F5a, Q12).
6. Replace in-place deletion with staged extraction, atomic activation, and rollback from the retained previous directory (F1, F6).
7. Replace the `github.ref` split with a validated `deployment_environment` input supplied by each caller — required before the deploy-tag trigger in Q3 can work (F9).
8. Split validate, build, deploy, and tag into separate jobs, then externalize repository metadata into explicit inputs or declarative configuration. This is what unlocks `environment:` protection and a tagging job scoped to `contents: write` (F5, F8, F9, F10, Q13).
9. Move complex PowerShell into a script with Pester tests, and add `actionlint` plus dependency updates through Dependabot or Renovate (F5, F13).

Deferred by decision: the post-deployment HTTP health check (Q9).

## Current GitHub guidance consulted

- [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use): least privilege, script-injection defenses, and immutable action references.
- [Workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax): permissions, reusable-workflow inputs/secrets, job timeouts, and environment files.
- [Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency): concurrency groups and cancellation behavior.
- [Control deployments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments): environments and deployment concurrency.
- [Self-hosted runners reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners): ephemeral and just-in-time runner guidance.
- [`actions/checkout` releases](https://github.com/actions/checkout/releases) and the v7.0.1 `action.yml`/README: current version, input defaults, and the per-major breaking changes summarized in F5.

## Open questions — resolved

**Status: all thirteen answered and resolved 2026-08-11.** The findings above have been updated to match. This section is retained as the record of why each recommendation reads the way it does.

### Q1. Do `SurePassIdApiServer` and `SurePassIdMfaServer` deliberately deploy to the same site? (F10)

Both cases in the repository switch set `APP_NAME=api` and build `SurePassIdApiServer.sln` / `SurePassIdApiServer.csproj`. Two different repositories therefore build the same project name and deploy to `api-<env>.surepassid.com`, overwriting each other.

- **A.** The repository was renamed and only one case is live; the other is dead configuration.
- **B.** Both repositories are active and this is an unnoticed collision.
- **C.** Both are active and intentionally share a site.

**Recommendation:** if A, delete the stale case in the same change so the switch cannot silently pick the wrong one. If B, treat it as a production defect and give each application a distinct `APP_NAME` before anything else in this review is actioned.

**Answer:** (**A**) That was there because the GitHub repo name was changed from `SurePassIdMfaServer` to `SurePassIdApiServer`. I manually removed the dead configuration `SurePassId/SurePassIdMfaServer` (L73-L81)

### Q2. Is there one sandbox VM for all environments, or one per environment? (F2, F9)

A single `SANDBOX_VM_HOSTNAME` secret serves `alpha`, `dev`, and `sandbox`, and the destination path embeds the environment as `E:\iis_sites\$SiteEnv\...`, which suggests one machine hosting all three.

- **A.** One VM hosting all three environments' sites.
- **B.** One VM per environment, selected by a caller-level secret today.
- **C.** Mixed.

**Recommendation:** either way, declare a GitHub environment per target and move the host, username, and password to environment-scoped secrets. If A, the shared machine also means the concurrency group must cover the whole VM for backup pruning and disk pressure, not just the individual site.

**Answer:** **A.** One VM hosting all three environments' sites.

### Q3. How are the calling workflows triggered? (F9)

The environment is derived by splitting `github.ref` at [lines 50-54](../.github/workflows/build-deploy-sandboxvm.yaml#L50-L54), which only behaves correctly for a branch push.

- **A.** Push to `alpha`/`dev`/`sandbox` only.
- **B.** Also `workflow_dispatch`.
- **C.** Also tag pushes or pull request events.

**Recommendation:** replace the ref parsing with an explicit, validated `deployment_environment` input regardless of the answer. If B or C is in use today, the current logic is already producing wrong or rejected environments.

**Answer:** Each repo has a workflow that calls this reusable workflow. The trigger is the same for all of them.

```yaml
on:
  workflow_dispatch:
  push:
    branches:
      - DEPLOY/alpha
      - DEPLOY/dev
      - DEPLOY/sandbox
```

This brings up a change that I would like to make. I want to stop using the branches as the trigger. Instead I would like to use `tags`. I'm thinking of using a tag name like `deploy-to-<ENV>` as a single moving tag. As you can see in the workflow, a release tag (`<SITE_ENV>-<ASSEMBLY_VERSION>`) would be applied to the commit point as a record of the deployment. The deploy tag would indicate the current code running for that environment.

- `deploy-to-alpha`
- `deploy-to-dev`
- `deploy-to-sandbox`

I can update the calling workflows to implement this change.

Suggestions for another method are welcome.

### Q4. Which mechanism owns environment configuration: the baked `EnvironmentName`, or `copy-web-env-files`? (F11)

The publish step passes `-p:EnvironmentName=${{ env.ENV_NAME }}` at [line 174](../.github/workflows/build-deploy-sandboxvm.yaml#L174), which bakes the environment into the build output, while `copy-web-env-files` at [line 181](../.github/workflows/build-deploy-sandboxvm.yaml#L181) overlays environment files afterwards. Two mechanisms configure the same thing, and the baked value makes the artifact environment-specific.

- **A.** Keep both; `EnvironmentName` only seeds a default that the overlay can override.
- **B.** Drop `EnvironmentName` and set `ASPNETCORE_ENVIRONMENT` on the IIS site or app pool.
- **C.** Drop the file overlay and rely on the baked value.

**Recommendation:** B. Setting the environment on the target makes the artifact environment-neutral, which is the prerequisite for building once and promoting the same artifact through `alpha`, `dev`, and `sandbox` instead of rebuilding per environment.

**Answer:** `SurePassId/copy-web-env-files` is basically a no-op for `${{ env.DOT_NET_TYPE == 'core' }}`. ot only applies to ` ${{ env.DOT_NET_TYPE == 'framework' }}`. I added a condition to the "Copy environment specific files in place." step.

### Q5. Is the `oidc` application's hardcoded `Debug`/`Development` configuration intentional? (F10)

At [lines 85-92](../.github/workflows/build-deploy-sandboxvm.yaml#L85-L92) the `oidc` case forces `CONFIGURATION=Debug` and `ENV_NAME=Development` for every branch, so all three environments receive an unoptimized build with development-mode behavior such as detailed error pages.

- **A.** Intentional and still required.
- **B.** Left over from initial bring-up; should be `Release` and `oidc-$SiteEnv` like its sibling.

**Recommendation:** B unless a concrete need exists. If A, document the reason inline, because a `Debug`/`Development` deployment usually implies verbose diagnostics that should not be reachable from a shared environment.

**Answer:** **A.** Intentional and still required. It allows a library that is used to run in development mode.

NOTE: None of these deployments are production/release environments.

### Q6. Is `--self-contained true` required on the target VM? (F11)

The publish at [lines 165-174](../.github/workflows/build-deploy-sandboxvm.yaml#L165-L174) always publishes self-contained `win-x64`, which multiplies artifact size, compression time, transfer time, and extraction time on every deployment.

- **A.** Required; the VM has no .NET 8 hosting bundle and cannot get one.
- **B.** Not required; the hosting bundle is installed or can be.
- **C.** Unknown.

**Recommendation:** B if at all possible. A framework-dependent publish is typically a large reduction in deployment payload, and the IIS hosting bundle is already a prerequisite for ASP.NET Core on IIS. If A must stand, keep self-contained but add `--no-restore` and trimming considerations separately.

**Answer:** **B.** The hosting bundles were updated on 2026-08-11:

| Bundle           | Was    | Now                       |
| ---------------- | ------ | ------------------------- |
| ASP.NET Core 8.0 | 8.0.11 | **8.0.30** (8.0.30.26373) |
| ASP.NET Core 9.0 | 9.0.0  | **9.0.19** (9.0.19.26370) |

Switch the publish to `--self-contained false`, keeping `--runtime win-x64` so the output keeps its `apphost` and the generated `web.config` still points at `.\App.exe`. The restore must be RID-scoped as well, or `--no-restore` fails with NETSDK1047 because the assets file has no `net8.0/win-x64` target:

```yaml
dotnet restore "${{ env.APP_SOLUTION }}" `
--runtime win-x64 `
--source https://api.nuget.org/v3/index.json

dotnet publish "${{ env.APP_PROJECT }}" `
--nologo `
--runtime win-x64 `
--self-contained false `
--no-restore `
--configuration ${{ env.CONFIGURATION }} `
--output ${{ env.PUBLISH_DIR }} `
-p:EnvironmentName=${{ env.ENV_NAME }}
```

The 8.0.11 → 8.0.30 update was a prerequisite, not housekeeping. Self-contained publishing shipped whatever runtime `actions/setup-dotnet` resolved at build time, so the apps were running a current runtime regardless of the VM. Framework-dependent hands that responsibility to the VM, and a `net8.0` app requests framework `8.0.0` with `rollForward: latestPatch` — it would have started happily on 8.0.11 and silently run ~19 months of missing security patches with no warning anywhere.

Two consequences to carry forward:

- The hosting bundle is now a runtime dependency of every deployed application, not an install-time detail. It belongs in the same patching routine as the Actions Runner version (F8).
- .NET 8 support ends in November 2026. Framework-dependent publishing makes that migration a bundle install plus a `TargetFramework` bump, instead of a change baked into every artifact and every retained backup.

Roll out on `alpha` first and confirm the site serves before applying it to `dev` and `sandbox`, since this changes what the ASP.NET Core Module actually launches.

### Q7. Does any application repository derive its version from Git history? (F11)

`fetch-depth: 0` at [line 119](../.github/workflows/build-deploy-sandboxvm.yaml#L119) fetches all history for the repository and every recursive submodule. Nothing in this workflow reads history: the version comes from assembly reflection and the tag uses `context.sha`.

- **A.** No repository uses GitVersion, Nerdbank.GitVersioning, or MinVer.
- **B.** At least one does — please name it.
- **C.** Unknown; needs a check of `.csproj` and `Directory.Build.props`.

**Recommendation:** if A, remove `fetch-depth: 0` and take the default of `1`. If B, keep full history only for that repository via an input, rather than for all of them.

**Answer:** **A.** No repository uses GitVersion, Nerdbank.GitVersioning, or MinVer.

### Q8. What mutable runtime state lives inside the deployment directories? (F6)

`KEEP_LIST` is populated only for `oidc` (`keys,logs,spidp_log.txt`) at [line 91](../.github/workflows/build-deploy-sandboxvm.yaml#L91), and the backup excludes a `Trace` directory at [line 258](../.github/workflows/build-deploy-sandboxvm.yaml#L258). Everything else in the site directory is deleted on each deployment at [lines 278-294](../.github/workflows/build-deploy-sandboxvm.yaml#L278-L294).

- **A.** Only `oidc` writes state into its site directory; the other applications are fully replaceable.
- **B.** Other applications also write logs, uploads, caches, or data protection keys there.
- **C.** Unknown.

**Recommendation:** relocate all mutable state outside the site directory — data protection keys to a configured path or certificate, logs to a dedicated log volume. That makes each deployment a full directory replacement, which in turn makes the atomic swap and rollback in F1 and F6 straightforward instead of requiring a merge with retained files.

**Answer:** **A.** Only `oidc` writes state into its site directory; the other applications are fully replaceable.

### Q9. Does each application expose a health endpoint? (F12)

The deployment currently declares success once `appcmd start` returns, which proves only that IIS accepted the command.

- **A.** Yes — please give the path and whether it requires authentication.
- **B.** No, but one can be added.
- **C.** No, and the root path returning HTTP 200 is the best available signal.

**Recommendation:** A or B. A health check that exercises configuration and critical dependencies is what makes automated rollback meaningful; without it, a broken deployment still reports green.

**Answer:** **D.** some apps have health endpoints. Others, the root path returning HTTP 200 is the best available signal. Not all of the servers are accessible from the internet. I would like to defer the health check at this time.

### Q10. Are the 7z backups a trusted rollback source? (F1, F6)

The workflow archives the site directory before deleting it and keeps the three most recent archives at [line 269](../.github/workflows/build-deploy-sandboxvm.yaml#L269), but nothing in the repository restores from them.

- **A.** Restores have been performed successfully and there is a documented procedure.
- **B.** Restores are ad hoc.
- **C.** The backups have never been used.

**Recommendation:** if A, automate that procedure as the rollback path in the `finally` block. If B or C, validate a restore manually once before relying on it; an untested backup is not a rollback plan, and the archive is created after IIS is already stopped, so a failure there currently leaves the site down with no verified way back.

**Answer:** **B.** Restores are ad hoc. I have used one once in the past just to restore a specific file. I'm highly confident that they work.

### Q11. What Actions Runner version is installed on `windows-build-vm`? (F5, F8)

This gates the `actions/checkout` upgrade: v5 and later require Actions Runner v2.327.1 or newer for the `node24` runtime. The runner application self-updates by default, so this is a verification rather than a blocker — but auto-update can be switched off with `--disableupdate` at config time, or silently stop working if the machine cannot reach the GitHub release assets host.

- **A.** v2.327.1 or newer.
- **B.** Older, and it can be updated.
- **C.** Older, and it cannot be updated soon.

**Recommendation:** A or B — update the runner and move to `actions/checkout` v7.0.1 pinned by SHA. If C, pin `v4.4.0` by SHA instead; it is still maintained, but treat the runner update as scheduled work since it also blocks other current actions.

**Answer:** **A.** `Runner.Listener.exe --version` reports **2.336.0**, well past the v2.327.1 floor. Auto-update is evidently working, so `actions/checkout` v7.0.1 is unblocked and no runner maintenance is required first.

```powershell
PS E:\action-runner> & '.\bin\Runner.Listener.exe' --version
2.336.0
```

### Q12. Should the submodule credential move from a PAT to a GitHub App installation token? (F5a)

`GH_ACTIONS_PAT` is a **fine-grained PAT limited to the submodule repositories** — already the middle tier of the F5a table. Scope is therefore not the problem; lifetime is. The token is valid for up to a year and sits in a persistent secret store used by a long-lived self-hosted runner.

Separately, and regardless of which option is chosen: [README.md](../README.md) documents `SSH_KEY` as the submodule-checkout secret while this workflow uses `GH_ACTIONS_PAT`. One of the two is out of date and should be corrected.

- **A.** Register a GitHub App with `contents: read` on only the submodule repositories and mint a short-lived installation token per run.
- **B.** Keep the fine-grained PAT, with a documented owner and rotation schedule.
- **C.** Defer until the workflow is split into separate jobs (Q13), then decide.

**Recommendation:** A. With scope already correct, the remaining gain is reducing credential lifetime from months to roughly an hour, and moving ownership from an individual's account to an installation that survives staff changes.

**Answer:** **A.** Move to a GitHub App installation token.

Implementation outline:

```yaml
- name: Mint submodule token
  id: submodule_token
  uses: actions/create-github-app-token@<sha> # v3.x
  with:
    app-id: ${{ secrets.SUBMODULE_APP_ID }}
    private-key: ${{ secrets.SUBMODULE_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}

- name: Checkout
  uses: actions/checkout@<sha> # v7.0.1
  with:
    submodules: recursive
    token: ${{ steps.submodule_token.outputs.token }}
    persist-credentials: false
```

Points to settle during implementation:

- The App must be installed on every submodule repository **and** on each calling application repository, since checkout uses the same token for the top-level clone.
- This is a `workflow_call` workflow, so `SUBMODULE_APP_ID` and `SUBMODULE_APP_PRIVATE_KEY` must reach it — organization-level secrets, or `secrets: inherit` from each caller.
- Grant `contents: read` only. No write permission is needed; the release tag is created with `GITHUB_TOKEN` through the REST API.
- Retire `GH_ACTIONS_PAT` once the App path is verified on `alpha`, and update the README in the same change.

### Q13. Should remediation restructure the workflow into separate jobs, or stay in one job?

The review proposes splitting validate, build, deploy, and tag into separate jobs. That is the cleaner end state, but it changes how the artifact moves between steps and how the self-hosted runner is occupied.

- **A.** Restructure into separate jobs as the target.
- **B.** Keep the single job and apply the correctness and security fixes in place.
- **C.** Single job now, restructure later.

**Recommendation:** C. The critical items — F1, F2, F3, F4, F7, F12 — can all be fixed inside the current job shape and should not wait on a restructure. Move to separate jobs once those are stable, at which point the artifact handoff and least-privilege token scoping become worth the churn.

**Answer:** **C.** Single job now, restructure later.
