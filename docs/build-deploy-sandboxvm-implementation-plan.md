# Implementation plan: `build-deploy-sandboxvm.yaml`

Created: 2026-08-11 · Source: [build-deploy-sandboxvm-review.md](build-deploy-sandboxvm-review.md)

## How this plan is organized

Phases 1–7 change [the workflow](../.github/workflows/build-deploy-sandboxvm.yaml) **in place, inside the existing single job** (Q13). Phase 8 is the job split. Phase 9 is tooling. Each phase is independently shippable and independently revertable.

**Rollout rule for every phase:** merge, deploy `alpha` first and confirm the site serves, then `dev`, then `sandbox`. All three share one VM (Q2), so a bad change reaches everything if it is rolled out in parallel.

**Phase 0 is a prerequisite for phases 3 and 5** and involves work outside this repository.

---

## Progress

Status markers appear on every phase heading and on every task heading inside a phase. Update them as work lands.

| Marker | Meaning                                                                 |
| ------ | ----------------------------------------------------------------------- |
| ✅     | Complete — merged and verified on all three environments                |
| ☑️     | Implemented — committed to `feat/sandboxvm-hardening`, not yet verified |
| 🔄     | In progress — some tasks in the phase are implemented, others are not   |
| ⬜     | Not started                                                             |
| ➖     | Reference or decision note — nothing to implement                       |

| Phase                                       | Status | Notes                                                                             |
| ------------------------------------------- | ------ | --------------------------------------------------------------------------------- |
| 0 — Prerequisites                           | ✅     | Completed 2026-08-12. All five tasks done; see the table below.                   |
| 1 — Safety rails                            | ☑️     | `27592bf`                                                                         |
| 2 — Tag after deployment                    | ☑️     | `a742f9c`                                                                         |
| 3 — Secrets, permissions, SHA pins          | ☑️     | `a742f9c`                                                                         |
| 4 — Framework-dependent publish             | ☑️     | `a742f9c`                                                                         |
| 5 — GitHub App installation token           | 🔄     | 5.1 done in `a742f9c`. 5.2 waits on the callers passing the App secrets.          |
| 6 — Staged, atomic deployment with rollback | ☑️     | `55f8971`                                                                         |
| 7 — Explicit environment input              | 🔄     | 7.1 done in `55f8971`, as an optional input. 7.2 waits on the callers.            |
| 8 — Split into separate jobs                | ⬜     | Deferred by decision. The single runner makes it costly.                          |
| 9 — Tooling                                 | 🔄     | actionlint, PSScriptAnalyzer, Dependabot and log groups done; Pester outstanding. |

Everything lands on the single branch `feat/sandboxvm-hardening`. Nothing has merged to `main` and nothing has run yet, so no phase is ✅: the workflow is unused and non-functional today, which is why merging carries no risk to a live deployment. ☑️ becomes ✅ only after the [verification checklist](#verification-checklist) passes on `alpha`, `dev` and `sandbox`.

**Blocking merge:** the deploy step references `SurePassId/github-workflows/.github/actions/deploy-iis-site@main`, so the composite action from phase 6 has to exist on `main` before any run can resolve it. Testing before merge means pointing that `uses:` at the branch temporarily.

---

## Issues found while planning

These were discovered while writing the plan and are not in the review. Each is resolved in the phase noted.

| #   | Issue                                                                                                                                  | Resolution                                                          | Phase | Status |
| --- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | ----- | ------ |
| I1  | `SurePassId/copy-web-env-files` declares `using: 'node16'`, which the runner no longer honors natively                                 | Bump to `node24`, tag a release, pin by SHA                         | 0, 3  | ☑️     |
| I2  | `github.rest.git.createRef(...)` is **not awaited** — a failed tag creation becomes an unhandled rejection and the step can still pass | `await` + explicit `try`/`catch`                                    | 2     | ☑️     |
| I3  | `dotnet publish --runtime win-x64 --no-restore` **fails** (NETSDK1047) unless the restore was also RID-scoped                          | Add `--runtime win-x64` to `dotnet restore`                         | 4     | ☑️     |
| I4  | The shell is implicit. Under Windows PowerShell 5.1, `>>` writes UTF-16LE, which corrupts `$GITHUB_ENV` parsing                        | Declare `defaults.run.shell: pwsh`                                  | 1     | ☑️     |
| I5  | `Assembly::LoadFile` becomes more failure-prone once framework-dependent publishing removes the runtime DLLs from the output folder    | `AssemblyName::GetAssemblyName` — reads metadata without loading    | 4     | ☑️     |
| I6  | The temp archive path is shared between concurrent runs and is never deleted                                                           | Unique per-run path, removed in `finally`                           | 1     | ☑️     |
| I7  | `concurrency` cannot read the `env` context, so it cannot key on `APP_NAME`                                                            | Key on the `inputs` and `github` contexts                           | 1     | ☑️     |
| I8  | The backup runs _inside_ the downtime window                                                                                           | Move it before the stop, using 7-Zip `-ssw` to read files held open | 6     | ☑️     |
| I9  | `actions/github-script` v9.0.0 is an annotated tag — pinning the tag object SHA fails                                                  | Pin the **commit** SHA                                              | 3     | ☑️     |

**Verified as non-issues:** `actions/github-script` v9 is a breaking major (ESM; `require('@actions/github')` removed; `getOctokit` is now an injected parameter), but the tagging script here uses only `github.rest.*` and `process.env`, so it is unaffected. `echo "X=..." >> "${{ github.env }}"` is valid — `github.env` expands to the env-file path — and is safe once I4 is fixed.

---

## ✅ Phase 0 — Prerequisites (outside this repository)

Completed 2026-08-12.

| Status | Task                                | Detail                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------ | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ✅     | Register the GitHub App             | _SurePassID Submodule Reader_, registered under the `SurePassId` organization with **`contents: read` only**, installed on every submodule repository **and** on all four application repositories (Q12). Registered manually per [Appendix A](#appendix-a--registering-the-github-app).                                                                                                                                                                               |
| ✅     | Store App credentials               | `SUBMODULE_APP_ID` and `SUBMODULE_APP_PRIVATE_KEY` stored as **organization** secrets, scoped to the four application repositories, so a `workflow_call` workflow can receive them.                                                                                                                                                                                                                                                                                    |
| ✅     | Fix `copy-web-env-files` (I1)       | [PR #1](https://github.com/SurePassId/copy-web-env-files/pull/1) moved `using: 'node16'` to `'node24'`, squash-merged to `main` as `0420236`. Optionally tag `v1.0.0` on it for readability; the SHA pin does not require one. Separate pre-existing defects are catalogued in that repository's `docs/known-defects.md`.                                                                                                                                              |
| ✅     | Reconcile [README.md](../README.md) | Corrected the .NET Framework runner, the `SurePassIdApiServer` rename, and the `SSH_KEY` vs `GH_ACTIONS_PAT` attribution. The App-token description follows when phase 5 lands.                                                                                                                                                                                                                                                                                        |
| ✅     | Record the runner count             | **One.** `windows-build-vm (ProtectedBuild1)`, runner group `default`, registered at the **organization** level — no repository-scoped runners exist on any of the four callers. Confirmed 2026-08-12 from the `runner_name` of every self-hosted job across their recent run history; the org runner API needs `admin:org`, so this is inference from usage rather than a direct listing. Informational for phase 1's concurrency expectations, decisive for phase 8. |

### ➖ Pinned action reference

Commit SHAs resolved from the GitHub API on 2026-08-11.

| Action                            | Pin to                                     | Version    | Note                                                          |
| --------------------------------- | ------------------------------------------ | ---------- | ------------------------------------------------------------- |
| `actions/checkout`                | `3d3c42e5aac5ba805825da76410c181273ba90b1` | v7.0.1     | From v4. Runner floor already met (Q11).                      |
| `actions/setup-dotnet`            | `a98b56852c35b8e3190ac28c8c2271da59106c68` | v6.0.0     | From v4. ESM migration; no input changes.                     |
| `microsoft/setup-msbuild`         | `30375c66a4eea26614e0d39710365f22f8b0af57` | v3         | From v2. node24 only.                                         |
| `actions/github-script`           | `3a2844b7e9c422d3c10d287c895573f7108da1b3` | v9.0.0     | From v7. **Commit** SHA, not the tag object `d746ffe3…` (I9). |
| `actions/create-github-app-token` | `bcd2ba49218906704ab6c1aa796996da409d3eb1` | v3.2.0     | New in phase 5.                                               |
| `SurePassId/copy-web-env-files`   | `042023699388269110326b9f1df4abba8cbd2923` | _untagged_ | node24 bump, merged 2026-08-12 (I1).                          |

---

## ☑️ Phase 1 — Safety rails (F1, F2, F7, F12, I4, I6, I7)

**Goal:** make failures fail loudly, stop concurrent runs from colliding, and guarantee the IIS site is restarted and the session closed no matter what.

Implemented on `feat/sandboxvm-hardening`, the single branch carrying every phase. `pwsh` 7.6.4 is confirmed present on the build VM, so `defaults.run.shell: pwsh` and `$PSNativeCommandUseErrorActionPreference` are both safe. Remote `Invoke-Command` sessions still run Windows PowerShell 5.1 over WinRM, so the remote side relies on `$global:ErrorActionPreference` plus `Invoke-Native` for exit-code checking.

### ☑️ 1.1 Workflow-level shell (I4)

```yaml
defaults:
  run:
    shell: pwsh
```

### ☑️ 1.2 Job-level concurrency and timeout (F2, F12, I7)

```yaml
jobs:
  BuildAndDeployToSandboxVM:
    runs-on: [self-hosted, windows-build-vm]
    timeout-minutes: 45
    concurrency:
      group: sandboxvm-${{ github.repository }}-${{ github.ref_name }}-${{ inputs.DEPLOY_APP_NAME || 'default' }}
      cancel-in-progress: false
```

`cancel-in-progress: false` so a newer run queues rather than interrupting a deployment mid-swap.

> This group is evaluated in the **calling** repository's context, so it serializes an application against itself but cannot serialize the four repositories that share the VM (Q2). That protection comes from the registered runner count — which is **one** (phase 0), so cross-repository runs already serialize by queueing for the single runner. Registering a second runner on that VM would remove that accidental protection.

### ☑️ 1.3 Session-scoped helpers

Functions declared `global:` inside an `Invoke-Command` persist for the life of the `PSSession`, so they are defined once and reused by every later remote call.

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -ge [version]'7.3') {
    $PSNativeCommandUseErrorActionPreference = $true
}

$RemoteHelpers = {
    $global:ErrorActionPreference = 'Stop'

    function global:Invoke-Native {
        param(
            [Parameter(Mandatory)][string]   $FilePath,
            [Parameter(Mandatory)][string[]] $ArgumentList,
            [string] $Description = $FilePath
        )
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$Description failed with exit code $LASTEXITCODE."
        }
    }

    function global:Wait-For {
        param(
            [Parameter(Mandatory)][scriptblock] $Condition,
            [string] $Description = 'condition',
            [int]    $TimeoutSeconds = 90
        )
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (& $Condition) {
                return
            }
            Start-Sleep -Milliseconds 500
        }
        throw "Timed out after $TimeoutSeconds seconds waiting for $Description."
    }
}
```

### ☑️ 1.4 Wrap the deployment (F1)

```powershell
$session       = $null
$iisStopped    = $false
$contentIntact = $true
$RunId         = '${{ github.run_id }}-${{ github.run_attempt }}'
$ArchiveName   = "deploy-$SiteDomainName-$RunId.7z"                 # I6
$LocalZipPath  = Join-Path $env:RUNNER_TEMP $ArchiveName

try {
    $session = New-PSSession -ComputerName $azureVm -Credential $credential
    Invoke-Command -Session $session -ScriptBlock $RemoteHelpers

    $iisStopped = $true          # set *before* the stop; see below
    # ... stop, back up, delete, copy, extract ...
    $contentIntact = $false      # set immediately before the destructive delete
    # ...
    $contentIntact = $true       # set once extraction succeeds
    # ... start, then:
    $iisStopped = $false
}
finally {
    if ($session) {
        if ($iisStopped) {
            if ($contentIntact) {
                Invoke-Command -Session $session -ScriptBlock {
                    param($SiteDomainName, $Appcmd)
                    & $Appcmd start apppool $SiteDomainName 2>$null | Out-Null
                    & $Appcmd start site    $SiteDomainName 2>$null | Out-Null
                } -ArgumentList $SiteDomainName, $Appcmd
            }
            else {
                Write-Host "::error::… deliberately left STOPPED … restore from ${DestinationPath}_*.7z"
            }
        }
        Remove-PSSession $session
    }
    if (Test-Path -Path $LocalZipPath) {
        Remove-Item -Path $LocalZipPath -Force
    }
}
```

Two deviations from the original sketch, both deliberate:

- **`$iisStopped` is set _before_ the stop, not after.** A partial stop — site stopped, app pool stop throws — would otherwise leave the flag `$false` and the site down. Restarting something already running is harmless because the `finally` restart ignores exit codes.
- **The restart is conditional on `$contentIntact`.** If the failure lands between the destructive delete and a successful extract, the site is left **stopped** on purpose. Starting it there would serve 500s from a gutted directory — equally broken, but less obvious — and `w3wp` would re-acquire handles on that directory, which can make the _next_ deployment's delete step fail. The error annotation names the backup archive to restore from. This whole branch disappears once phase 6 replaces the in-place overwrite with a staged directory and a rename swap.

### ☑️ 1.5 Replace the fixed sleeps (F7)

Delete both `Start-Sleep -Seconds 3` calls and poll for real state instead:

```powershell
Wait-For -Description "app pool $SiteDomainName to report Stopped" -Condition {
    (& $Appcmd list apppool "$SiteDomainName" /text:state 2>$null) -eq 'Stopped'
}
Wait-For -Description 'worker processes to exit' -Condition {
    -not (& $Appcmd list wp /apppool.name:"$SiteDomainName" /text:name 2>$null)
}
```

> These calls deliberately bypass `Invoke-Native`: "no matching object" is the success condition, not an error.

The `appcmd stop` commands themselves also ignore their exit codes, because stopping an already-stopped site is an error to `appcmd` but not to us — and phase 1.4 can now deliberately leave a site stopped for the next run to find. The `Wait-For` calls are the real assertion. The start path is the mirror image: `Invoke-Native` on both `start` commands, then `Wait-For` the site to report `Started`.

**Verify:** force a failure (point `APP_PROJECT` at a bad path on a scratch branch) and confirm the run fails, the site is running, and no session or temp archive is left behind.

---

## ☑️ Phase 2 — Tag after deployment, idempotently (F3, I2)

**Goal:** a release tag means the deployment succeeded.

Leave `Generate Release Tag Name` where it is — it needs the publish output, not the deployment. Move only the tagging step to **after** the deploy step, and rewrite it:

```yaml
- name: Tag the commit with the release tag
  if: ${{ env.TAG_REPOSITORY == 'true' }}
  uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0
  with:
    script: |
      const tagName = process.env.APP_TAG_NAME;
      const shortRef = `tags/${tagName}`;
      try {
        await github.rest.git.createRef({
          owner: context.repo.owner,
          repo: context.repo.repo,
          ref: `refs/${shortRef}`,
          sha: context.sha
        });
        core.info(`Created ${tagName} at ${context.sha}.`);
      } catch (err) {
        if (err.status !== 422) {
          throw err;
        }
        const existing = await github.rest.git.getRef({
          owner: context.repo.owner,
          repo: context.repo.repo,
          ref: shortRef
        });
        if (existing.data.object.sha !== context.sha) {
          throw new Error(
            `Tag ${tagName} already exists at ${existing.data.object.sha}, ` +
            `but this run deployed ${context.sha}. Version was not incremented.`
          );
        }
        core.info(`Tag ${tagName} already points at ${context.sha}; nothing to do.`);
      }
```

The `await` is the substantive fix (I2): without it, a rejected promise never failed the step. Re-running a successful deployment is now a no-op; re-deploying a _different_ commit under an unchanged version number fails with a message that says why.

**Verify:** re-run a completed job and confirm the step succeeds with "nothing to do".

---

## ☑️ Phase 3 — Secrets, permissions, and SHA pins (F4, F5, I9)

### ☑️ 3.1 Explicit permissions

```yaml
jobs:
  BuildAndDeployToSandboxVM:
    permissions:
      contents: write # release tag only; narrows to the tag job in phase 8
```

### ☑️ 3.2 Secrets via the environment, not string interpolation (F4)

```yaml
- name: Deploy files to sandboxvm
  env:
    SANDBOX_VM_USERNAME: ${{ secrets.SANDBOX_VM_USERNAME }}
    SANDBOX_VM_PASSWORD: ${{ secrets.SANDBOX_VM_PASSWORD }}
    SANDBOX_VM_HOSTNAME: ${{ secrets.SANDBOX_VM_HOSTNAME }}
  run: |
    $azureVm    = $env:SANDBOX_VM_HOSTNAME
    $credential = [pscredential]::new(
        $env:SANDBOX_VM_USERNAME,
        (ConvertTo-SecureString $env:SANDBOX_VM_PASSWORD -AsPlainText -Force)
    )
```

### ☑️ 3.3 Pin every action

Apply the reference table above. Annotate each with its version:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

For `copy-web-env-files`, pin the commit produced by the node24 bump in phase 0. **Do not pin `d746ffe3…` for github-script** — that is the annotated tag object, not a commit (I9).

**Verify:** confirm `microsoft/setup-msbuild@v3` still locates MSBuild for the .NET Framework repositories before rolling past `alpha`; it is the only pin here that changes tool discovery.

---

## ☑️ Phase 4 — Framework-dependent publish and shallow fetch (F11, F13, Q6, Q7, I3, I5)

### ☑️ 4.1 RID-scoped restore, then `--no-restore` publish (I3)

Both flags change together or the build breaks.

```yaml
- name: Restore NuGet packages.
  if: ${{ env.DOT_NET_TYPE == 'core' }}
  run: |
    dotnet restore "${{ env.APP_SOLUTION }}" `
           --runtime win-x64 `
           --source https://api.nuget.org/v3/index.json

- name: Build ${{ env.APP_PROJECT }}
  if: ${{ env.DOT_NET_TYPE == 'core' }}
  run: |
    dotnet publish "${{ env.APP_PROJECT }}" `
           --nologo `
           --runtime win-x64 `
           --self-contained false `
           --no-restore `
           --configuration ${{ env.CONFIGURATION }} `
           --output ${{ env.PUBLISH_DIR }} `
           -p:EnvironmentName=${{ env.ENV_NAME }}
```

`--runtime win-x64` stays so the output keeps its `apphost` and the generated `web.config` still points at `.\App.exe` (Q6).

### ☑️ 4.2 Drop the full-history fetch (Q7)

Delete `fetch-depth: 0` from the checkout step. The default of `1` applies; no repository derives its version from history.

### ☑️ 4.3 Read the version without loading the assembly (F13, I5)

Framework-dependent output no longer carries the runtime DLLs, which makes `LoadFile` a worse bet than it already was.

```powershell
$assemblyPath = Join-Path '${{ env.PUBLISH_DIR }}' '${{ env.APP_ASSEMBLY }}'
if (-not (Test-Path -Path $assemblyPath)) {
    throw "Expected assembly not found at $assemblyPath. The publish step produced nothing usable."
}
$version = [System.Reflection.AssemblyName]::GetAssemblyName($assemblyPath).Version
echo "APP_TAG_NAME=${{ env.SITE_ENV }}-$version" >> "${{ github.env }}"
```

`GetAssemblyName` reads the metadata without loading into the AppDomain and returns the same `AssemblyVersion` as before, so tag values do not change. The `Test-Path` guard doubles as the publish-output validation F6 asks for.

**Verify on `alpha` before anything else:** the deployed site serves, and `E:\iis_sites\alpha\...` is dramatically smaller than the previous release. This is the phase most likely to surface a missing hosting-bundle assumption.

---

## 🔄 Phase 5 — GitHub App installation token (F5a, Q12)

The App, its installation, and both organization secrets exist as of phase 0 — only the workflow changes below remain.

### ☑️ 5.1 Transitional release

Accept both credentials so callers can be migrated without a flag day.

```yaml
on:
  workflow_call:
    secrets:
      GH_ACTIONS_PAT:
        required: false
      SUBMODULE_APP_ID:
        required: false
      SUBMODULE_APP_PRIVATE_KEY:
        required: false
```

```yaml
jobs:
  BuildAndDeployToSandboxVM:
    env:
      # The `secrets` context is not available in a step-level `if`, so presence has to be surfaced through `env`.
      SUBMODULE_APP_ID: ${{ secrets.SUBMODULE_APP_ID }}

- name: Mint submodule token
  id: submodule_token
  if: ${{ env.SUBMODULE_APP_ID != '' }}
  uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
  with:
    app-id: ${{ secrets.SUBMODULE_APP_ID }}
    private-key: ${{ secrets.SUBMODULE_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}

- name: Checkout ${{ github.repository }} and submodules
  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    submodules: recursive
    token: ${{ steps.submodule_token.outputs.token || secrets.GH_ACTIONS_PAT }}
    persist-credentials: false
```

`app-id` carries a deprecation warning in v3 — the action prefers `client-id`. Swapping the organization secret's value from the App ID to the App's client ID and renaming the input clears it; the two are interchangeable otherwise.

If callers use `secrets: inherit`, organization secrets reach the workflow with no caller change. If any caller maps secrets explicitly, add the two there.

### ⬜ 5.2 Cleanup release

Once all four repositories have deployed successfully to all three environments on App tokens: make the App secrets `required: true`, delete `GH_ACTIONS_PAT` from the `secrets:` block and from the callers, revoke the PAT, and update the README.

**Verify:** the checkout log shows submodules resolving, and the App's installation shows the expected repositories and only `contents: read`.

---

## ☑️ Phase 6 — Staged, atomic deployment with rollback (F1, F6, I8)

**Goal:** the site is only down for the directory swap, and a failure leaves the previous release running.

### ➖ Directory model

IIS's physical path never changes; only what sits at that path does.

| Path                                                   | Role                                                    |
| ------------------------------------------------------ | ------------------------------------------------------- |
| `E:\iis_sites\<env>\<site>`                            | Live. IIS physical path.                                |
| `E:\iis_sites\<env>\<site>.staging-<run_id>-<attempt>` | New release, assembled while the site is still serving. |
| `E:\iis_sites\<env>\<site>.previous`                   | Prior release, retained as the rollback source.         |

All three share a parent directory, so the swap is a pair of metadata-only renames rather than a copy.

### ☑️ Sequence

**Site stays up:**

1. Local — validate the publish output (`Test-Path` on `APP_ASSEMBLY`, from phase 4), create the archive at the unique temp path.
2. Remote — remove stale `*.staging-*` directories; verify free space on the volume is at least three times the archive size; create the staging directory.
3. Copy the archive into staging; extract; verify `APP_ASSEMBLY` is present in the extracted tree; delete the archive.
4. Remote — 7-Zip backup of the live directory **before** the stop, using `-ssw` so files held open by `w3wp` can still be read (I8); prune to the three most recent.

**Downtime window opens:**

5. Stop site and app pool; `Wait-For` both the `Stopped` state and worker-process exit (phase 1).
6. Move each `KEEP_LIST` entry from live into staging, skipping any that do not exist. Only `oidc` has entries (Q8), so this is a no-op for every other application.
7. Delete `.previous` if present; `Rename-Item` live → `.previous`; `Rename-Item` staging → live.
8. Start app pool and site; `Wait-For` the `Started` state.

**Downtime window closes.**

### ☑️ Rollback

In the `finally` from phase 1, extended:

```powershell
Invoke-Command -Session $session -ScriptBlock {
    param($Live, $Previous, $SiteDomainName, $Appcmd)
    if (-not (Test-Path -Path $Live) -and (Test-Path -Path $Previous)) {
        Rename-Item -Path $Previous -NewName (Split-Path -Leaf $Live)
    }
    & $Appcmd start apppool $SiteDomainName
    & $Appcmd start site    $SiteDomainName
} -ArgumentList $live, $previous, $SiteDomainName, $appcmd
```

`.previous` is left in place on success and removed at the start of the next deployment, so the fast rollback source is always one release deep. The 7z archives remain as the deeper history — and are no longer what recovery depends on, which matters given they have only ever been used to pull back a single file (Q10).

### ☑️ Extract the remote script

This phase is where the remote logic outgrows an inline `run:` block.

**Correction to the original sketch.** It proposed `scripts/Deploy-IisSite.ps1` invoked with `Invoke-Command -Session $session -FilePath .\scripts\Deploy-IisSite.ps1`. That cannot work: a reusable workflow only ever has the **caller's** repository checked out, so no file from this repository is on disk. `uses: ./...` has the same problem — it resolves against the caller's workspace.

What does work is a **composite action in this repository**, referenced the same way the reusable workflow itself is:

| Path                                                 | Role                                                             |
| ---------------------------------------------------- | ---------------------------------------------------------------- |
| `.github/actions/deploy-iis-site/action.yaml`        | Input surface; runs the script from `${{ github.action_path }}`. |
| `.github/actions/deploy-iis-site/Deploy-IisSite.ps1` | The orchestration — a plain file, so Pester can load it.         |

The script runs **on the runner** and owns the session, because the `Copy-Item -ToSession` transfer has to originate locally; only the individual `Invoke-Command` blocks execute remotely.

One consequence worth knowing: `uses: SurePassId/github-workflows/.github/actions/deploy-iis-site@main` is resolved independently of the workflow file, so the action has to exist on `main` before a run can use it. Testing the pair on a branch means pointing that `uses:` at the branch for the duration.

**Verify:** deliberately corrupt the archive on a scratch branch and confirm the site is still serving the previous release when the run fails. Measure the downtime window before and after — it should drop from "backup + delete + transfer + extract" to "two renames".

---

## 🔄 Phase 7 — Explicit environment input (F9, Q3)

### ☑️ 7.1 Workflow change

```yaml
on:
  workflow_call:
    inputs:
      DEPLOYMENT_ENVIRONMENT:
        description: "Target environment: alpha, dev, or sandbox. Derived from the ref when omitted."
        type: string
        required: false
        default: ""
```

```powershell
$SiteEnv = $env:DEPLOYMENT_ENVIRONMENT
if (-not $SiteEnv) {
  if ($env:GITHUB_REF -match '^refs/tags/deploy-to-(.+)$' -or $env:GITHUB_REF -match '^refs/heads/DEPLOY/(.+)$') {
    $SiteEnv = $Matches[1]
  }
  else {
    Throw "Cannot derive a deployment environment from '$($env:GITHUB_REF)'. Push a deploy-to-<env> tag, or pass DEPLOYMENT_ENVIRONMENT."
  }
}
if ("alpha", "dev", "sandbox" -notcontains $SiteEnv) {
  Throw "Invalid deployment environment: '$SiteEnv'. Expected alpha, dev, or sandbox."
}
echo "SITE_ENV=$SiteEnv" >> "${{ github.env }}"
```

In a reusable workflow the `github` context is the **caller's**, so `$env:GITHUB_REF` is the ref that triggered the caller run — which is why the parsing can live here instead of being copied into four repositories. Both ref shapes are recognized so the branch trigger keeps working until every caller has moved to tags.

Both the input and the ref arrive through `env:` rather than `${{ }}` interpolation. A ref name may legally contain a double quote, and the input is caller-controlled text; either one interpolated into a PowerShell literal is a script-injection vector (F4).

**Deviation:** the input is optional, not `required: true`. Making it required would break all four callers the moment it merged, and none of them can be updated from this repository. More usefully, keeping it optional is what lets the callers stay ignorant of the environment list entirely — see 7.2.

This is a **prerequisite** for the deploy-tag trigger in Q3: `refs/tags/deploy-to-alpha` reduces to `deploy-to-alpha` under the old last-segment split, which the allow-list rejects.

### ⬜ 7.2 Caller changes

Branches are dropped entirely (Q3). All four repositories become:

```yaml
on:
  workflow_dispatch:
  push:
    tags: ["deploy-to-*"]

jobs:
  BuildAndDeployToSandboxVM:
    uses: SurePassId/github-workflows/.github/workflows/build-deploy-sandboxvm.yaml@main
    secrets:
      SUBMODULE_APP_ID: ${{ secrets.SUBMODULE_APP_ID }}
      SUBMODULE_APP_PRIVATE_KEY: ${{ secrets.SUBMODULE_APP_PRIVATE_KEY }}
      SANDBOX_VM_USERNAME: ${{ secrets.SANDBOX_VM_USERNAME }}
      SANDBOX_VM_PASSWORD: ${{ secrets.SANDBOX_VM_PASSWORD }}
      SANDBOX_VM_HOSTNAME: ${{ secrets.SANDBOX_VM_HOSTNAME }}
```

`IdentityProvider` keeps its `with: DEPLOY_APP_NAME:` and its two jobs. Nothing else passes `DEPLOYMENT_ENVIRONMENT` at all.

The glob is the point: `deploy-to-*` matches whatever environments exist, so adding or renaming one is a change to the allow-list in 7.1 and nowhere else. An unknown environment — `deploy-to-prod` — still triggers a run, but it fails in the shared workflow's validation with a message naming the value, which is the correct place for that decision to be made once.

**`workflow_dispatch` keeps no inputs, and does not need any.** The **Run workflow** ref selector lists tags as well as branches, so choosing `deploy-to-alpha` there produces `refs/tags/deploy-to-alpha` — the same ref a push produces, resolved by the same code in 7.1. That is the manual re-deploy path: it replays the tag's current commit without moving anything.

Two consequences of that:

- The workflow file must exist on the **default branch** for the option to appear in the UI at all; the version that runs is the one on the selected ref.
- Dispatching from `main`, or any ordinary branch, fails in 7.1 with "cannot derive a deployment environment". That is the intended behavior — it fails closed rather than guessing — but it is worth saying out loud, because the old workflow accepted a dispatch from `DEPLOY/alpha`.

If an explicit override is ever wanted, add a `type: string` input passed to `DEPLOYMENT_ENVIRONMENT` and let 7.1 validate it. Avoid `type: choice`: the option list is not shareable, so it would put the environment names back into four files, which is the thing 7.1 exists to prevent.

Once all four have moved, delete the `refs/heads/DEPLOY/` branch of the regex in 7.1.

### ➖ 7.3 Operating the moving tag (Q3)

Deploying becomes:

```bash
git tag --force deploy-to-alpha <sha>
git push --force origin deploy-to-alpha
```

Things that follow from that choice, worth setting up alongside it:

- **Force-push is the deploy verb.** Anyone with push access can deploy, with no approval gate and no audit trail beyond the reflog and the run history. The `environment:` protection rules that phase 8 unlocks are the counterweight; until then, a repository ruleset restricting who may update `deploy-to-*` is the only gate.
- **Protect the release tags separately.** A ruleset that blocks force-push and deletion on the `<env>-<version>` tags this workflow creates, while explicitly allowing it on `deploy-to-*`, keeps the deployment record immutable while the pointer stays movable.
- **No loop today.** Tags created with `GITHUB_TOKEN` do not trigger workflows, and `deploy-to-*` would not match a release tag anyway. The first half of that guarantee disappears if tagging ever moves to a PAT or App token.
- **Concurrency keys shift.** The group in phase 1.2 uses `github.ref_name`, which becomes `deploy-to-alpha` instead of a branch name. That still separates environments, so no change is needed — but re-pointing the same tag twice in quick succession queues rather than cancels, which is the intended behavior.
- **The tag is also the record.** `git show deploy-to-alpha` answers "what is running in alpha" without a separate mechanism, which was the original motivation.

---

## ⬜ Phase 8 — Split into separate jobs (F5, F8, F9, F10, Q13)

Deferred by decision, and gated on the runner count from phase 0 — which came back as **one**. Four jobs then mean four sequential acquisitions of the same runner, and a deploy job can queue behind an unrelated repository's build, turning one wait into three. Treat registering a second runner as a prerequisite for this phase, and note that doing so also removes the accidental cross-repository serialization phase 1 currently relies on. The target shape and its two constraints are in the review's _Recommended target structure_. The mechanical work:

| Item                        | Detail                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `$GITHUB_ENV` → job outputs | Every `echo "X=..." >> $GITHUB_ENV` becomes a `validate` job output.                                                                                                                                                                                                                                                                                                                            |
| Context change              | The `env` context is **not available** in a job-level `if:` or in `runs-on`. Every `if: ${{ env.DOT_NET_TYPE == 'framework' }}` becomes `needs.validate.outputs.dotnet_type`.                                                                                                                                                                                                                   |
| Artifact handoff            | `upload-artifact` / `download-artifact` between build and deploy — affordable only because of phase 4.                                                                                                                                                                                                                                                                                          |
| `environment:`              | On the deploy job. Unlocks approvals, environment-scoped VM secrets, and deployment history.                                                                                                                                                                                                                                                                                                    |
| `permissions:`              | `contents: write` narrows from the whole job to the tag job alone.                                                                                                                                                                                                                                                                                                                              |
| Toolchain separation        | Optional: move the MSBuild and `dotnet` paths into composite actions referenced as `SurePassId/github-workflows/.github/actions/<name>@<sha>`. Prefer this over two build _jobs_, which would require `if: ${{ !cancelled() && (needs.build-framework.result == 'success' \|\| needs.build-core.result == 'success') }}` on deploy — omit that and the run reports green with nothing deployed. |

---

## 🔄 Phase 9 — Tooling (F5, F13)

- ⬜ Pester tests for `Deploy-IisSite.ps1` from phase 6. Needs the script split into functions first — as written it is a single top-to-bottom sequence.
- ☑️ `actionlint` and PSScriptAnalyzer in CI for this repository, via [.github/workflows/lint.yaml](../.github/workflows/lint.yaml). Both run on GitHub-hosted `ubuntu-latest`; move them to the self-hosted runner if hosted minutes are not available.
- ☑️ Dependabot for action updates, which is what makes SHA pinning sustainable, in [.github/dependabot.yml](../.github/dependabot.yml):

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

- 🔄 Log groups (`::group::`) and `$GITHUB_STEP_SUMMARY` in place of the `====` separator lines. The groups are in `Deploy-IisSite.ps1`; the step summary is not written yet.

---

## Verification checklist

Run per phase, on `alpha` first. **Nothing below has been run yet** — this checklist is what moves a phase from ☑️ to ✅.

- [ ] Workflow parses; `actionlint` is clean.
- [ ] `alpha` deploys and the site serves.
- [ ] A deliberately failed run leaves the site **running** and no `PSSession` or temp archive behind.
- [ ] A re-run of a successful job is a no-op at the tagging step.
- [ ] Two runs queued together serialize rather than interleave.
- [ ] Deployed directory size dropped substantially after phase 4.
- [ ] Checkout resolves submodules on the App token after phase 5.
- [ ] Downtime window measured after phase 6 is limited to the swap.
- [ ] `dev` and `sandbox` follow only after `alpha` is confirmed.

## Deferred by decision

- Post-deployment HTTP health check (Q9). Until it exists, phase 6's rollback is the only protection against a release that deploys cleanly but does not serve.

---

## Appendix A — Registering the GitHub App

**Status: ✅ Completed manually on 2026-08-12.** Retained as the reference for re-registration and revocation.

Expands the first row of phase 0. Requires **organization owner** rights on `SurePassId`.

### ✅ A.1 Create the App

1. Go to `https://github.com/organizations/SurePassId/settings/apps/new`.
   Equivalent navigation: organization **Settings → Developer settings → GitHub Apps → New GitHub App**. Register it under the **organization**, not your personal account, so it survives you leaving and can use organization secrets.
2. **GitHub App name** — `SurePassID Submodule Reader`. Must be globally unique across GitHub; append something if it is taken.
3. **Homepage URL** — required by the form but unused. `https://github.com/SurePassId/github-workflows` is fine.
4. **Callback URL / Setup URL** — leave blank. There is no user-facing OAuth flow here.
5. **Webhook** — **uncheck "Active"**. Nothing listens for events, and leaving it on forces a URL and secret you would then have to manage.
6. **Repository permissions** — set **Contents: Read-only**. Leave every other permission at _No access_. **Metadata: Read-only** is mandatory and is selected automatically.

   > `Contents: Read-only` is the entire authorization surface of this App. It is what makes it a smaller credential than the PAT it replaces (F5a).

7. **Organization permissions** and **Account permissions** — none.
8. **Where can this GitHub App be installed?** — **Only on this account**.
9. Click **Create GitHub App**.

### ✅ A.2 Collect the credentials

10. On the App's settings page, record the **App ID** (a number, near the top). This becomes `SUBMODULE_APP_ID`.
11. Scroll to **Private keys → Generate a private key**. A `.pem` file downloads immediately. **GitHub does not keep a copy** — if you lose it, generate a new one and revoke the old.
12. Open the `.pem` in a text editor and copy the whole file, including the `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` lines and all newlines. This becomes `SUBMODULE_APP_PRIVATE_KEY`.

### ✅ A.3 Install the App

13. In the App's left sidebar, click **Install App**, then **Install** next to `SurePassId`.
14. Choose **Only select repositories** and select:
    - every private repository referenced as a submodule, at any depth;
    - `SurePassIdLegacyMfaServer`, `SurePassIdApiServer`, `SurePassIdPushServer`, `IdentityProvider` — checkout uses the same token for the top-level clone, so omitting these breaks the checkout outright.
15. Click **Install**. Returning to this page later shows the current repository list, which is the fastest way to diagnose a submodule that will not resolve.

### ✅ A.4 Store the secrets

16. Organization **Settings → Secrets and variables → Actions → New organization secret**, twice:

    | Name                        | Value                             | Repository access                                         |
    | --------------------------- | --------------------------------- | --------------------------------------------------------- |
    | `SUBMODULE_APP_ID`          | The App ID from step 10           | Selected repositories — the four application repositories |
    | `SUBMODULE_APP_PRIVATE_KEY` | Full `.pem` contents from step 12 | Selected repositories — the four application repositories |

    They must be **organization** secrets: a reusable workflow invoked with `secrets: inherit` receives the caller's secrets, and organization secrets reach all four callers without editing each one.

    `github-workflows` itself does not need access — it never runs these workflows directly.

17. Securely delete the downloaded `.pem` from your machine.

### ⬜ A.5 Confirm before phase 5

- The App's **Permissions & events** page lists only `Contents: Read-only` and `Metadata: Read-only`.
- The **Install App** page lists the submodule repositories _and_ the four application repositories.
- Both organization secrets exist and are scoped to the four application repositories.

Only then apply phase 5.1, and roll it out on `alpha` first.

### ➖ Revocation

If the private key is ever exposed: App settings → **Private keys** → delete the compromised key, generate a new one, update `SUBMODULE_APP_PRIVATE_KEY`. Installation tokens minted from it expire within the hour on their own — which is the point of the change.
