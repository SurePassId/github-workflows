# .NET 10+ reusable build workflow update

## Scope and recommendation

Assessment and implementation date: 2026-10-30. The
[modern builder](../.github/workflows/build-dot-net-modern.yaml) implements the
contract below. The companion API stage caller change in a separate repository
pins the published shared-workflow commit. Application code and Azure resources
are unchanged; deployment and hosting checks remain rollout prerequisites.

Keep [build-dot-net8.yaml](../.github/workflows/build-dot-net8.yaml) unchanged.
Create a separate, version-parameterized reusable workflow named
`.github/workflows/build-dot-net-modern.yaml` for .NET 10 and later applications.
Update the API Server's
[deploy-stage.yaml](https://github.com/SurePassId/SurePassIdApiServer/blob/release/2026.4/.github/workflows/deploy-stage.yaml)
to call the new workflow once it has been published.

Use an explicit SDK input rather than hardcoding .NET 10 in the new workflow.
Future callers can choose a newer released SDK without creating another builder
for every .NET major version. This is reusable plumbing, not a guarantee of
compatibility with unreleased SDKs, future runner images, or hosting runtimes.

## Baseline behavior and findings

Before this update, the stage caller pinned both shared workflows to commit
`4f6623ea4d687bed1c8d5ed3c690311970d306ca`. Its build and deployment workflow
contents were inspected as the baseline.

| Surface | Observed behavior | Implication |
| --- | --- | --- |
| API project | [SurePassIdApiServer.csproj](https://github.com/SurePassId/SurePassIdApiServer/blob/release/2026.4/SurePassIdApiServer/SurePassIdApiServer.csproj) already targets `net10.0`. Both API and database test projects also target `net10.0`. | This task does not require changing those target frameworks. |
| SDK setup | The builder installs `8.0.x` using a pinned `actions/setup-dotnet` action. | .NET 8 SDK cannot build `net10.0`. If a hosted runner happens to select a newer preinstalled SDK, apparent success is accidental, not a reliable SDK contract. |
| SDK selection | No `global.json` was found in the inspected API repository. | Installation and selection are different: without an SDK pin, the CLI normally selects the newest installed SDK. |
| Restore | `dotnet restore --source https://api.nuget.org/v3/index.json` runs at repository root, without a project argument. | It restores the root solution, potentially bringing unrelated test projects into a deployment build. |
| Publish | Publishes `BUILD_PROJECT` with `BUILD_CONFIG` into a unique temporary directory; implicit restore remains enabled. | The publish-directory pattern is reusable. An explicit project restore can eliminate the redundant implicit restore. |
| Configuration | Creates a `bin` destination and calls the pinned `copy-web-env-files` action with `DEPLOY_ENV`. | Preserve the layout and overlay contract until artifact inspection proves a change is needed. The custom action implementation was not inspected. |
| Artifact | Uploads `app-${{ inputs.APP }}-${{ inputs.SLOT }}`. | Preserve this exact name so existing deployment jobs continue to work. |
| Build job ID | The .NET 8 file still uses `build-dot-net6`. | Use a neutral job ID in the new file; do not rename the legacy job as part of this update. |
| Deployment | [deploy-to-app-service.yaml](../.github/workflows/deploy-to-app-service.yaml) downloads and deploys an artifact using a self-hosted Windows runner. It does not build the application. | No .NET-version-specific deployment workflow fork is required for the existing artifact contract. |

Installing .NET 10 is the immediate build requirement. Reliable SDK selection,
matching hosting support, and application validation are separate requirements.

## New reusable workflow contract

Implemented file: [build-dot-net-modern.yaml](../.github/workflows/build-dot-net-modern.yaml).

Retain `workflow_call`, `windows-latest`, recursive submodule checkout with
`SSH_KEY`, the unique temporary publish directory, environment overlay, artifact
upload with `if-no-files-found: error`, and cleanup guarded by `always()`.
Keep existing action commit pins initially; do not bundle unrelated action upgrades.

| Input or secret | Behavior |
| --- | --- |
| `APP`, `SLOT`, `DEPLOY_ENV`, `BUILD_CONFIG`, `BUILD_PROJECT` | Retain the existing required string inputs and meanings. |
| `DOTNET_VERSION` | Add a required string input, with no silent default. Initially accept stable major channels in the form `N.0.x`, where `N >= 10`; for this caller use `'10.0.x'`. |
| `SSH_KEY` | Retain the existing required secret and caller mapping. |

The deliberately narrow SDK format avoids ambiguous values such as `latest`,
multiline SDK lists, or an accidental .NET 8 request. Expand this contract later
if exact SDK pins are required. Preview SDKs are not part of the initial deployment
contract; do not automatically opt production or stage builds into previews.

### SDK installation and selection

1. Validate `DOTNET_VERSION` before installation. Reject values outside the
   documented channel format or below major version 10 with a clear error.
2. Pass the validated channel into the existing pinned `actions/setup-dotnet`
   action's `dotnet-version` input.
3. Run `dotnet --info` and `dotnet --version` from the same directory used for
   restore and publish. Fail if SDK resolution fails, resolves a prerelease, or
   resolves a major version different from the requested channel. Print the
   requested channel and resolved version in the diagnostic output.
4. Treat an incompatible caller `global.json` as a configuration error, not
   something the reusable workflow silently overwrites.

The selected-major check is important when `windows-latest` gains a newer SDK.
Failing clearly is safer than silently building with that new major.
For long-term selection stability, add a caller-owned root `global.json` in a
separate implementation decision: use an actual full SDK version, restrict
roll-forward within the selected major, and set `allowPrerelease: false`.
Keep it aligned with `DOTNET_VERSION`. A channel such as `10.0.x` is not valid
as `sdk.version` in that file. If exact-version installation is later needed,
consider a `global-json-file` contract instead of two competing version sources.

### Restore and publish

Scope restore to `BUILD_PROJECT` rather than the whole solution. Preserve the
existing NuGet.org-only source policy initially; changing private-feed behavior
is a separate concern.

Use quoted environment variables for caller-provided values in PowerShell,
rather than inserting expressions directly into executable command text.
The intended commands, in separate steps, are:

```powershell
dotnet restore "$env:BUILD_PROJECT" --source https://api.nuget.org/v3/index.json
```

```powershell
dotnet publish "$env:BUILD_PROJECT" --configuration "$env:BUILD_CONFIG" --no-restore --output "$env:PUBLISH_PATH"
```

Map `BUILD_PROJECT` and `BUILD_CONFIG` from workflow inputs, and `PUBLISH_PATH`
from the initialized directory output. Preserve native command failures; if a
step runs multiple native commands, check their exit codes immediately.
If future callers introduce a runtime identifier or restore-affecting MSBuild
properties, pass matching values to restore and publish.

Do not force `net10.0` with `--framework` in this generic builder. The application
project remains responsible for its target framework. Shared libraries can keep
older compatible targets. Multi-targeted executable applications would require
an explicit framework-selection extension before onboarding.

Preserve the current deployment model. Do not silently add self-contained,
single-file, trimming, Native AOT, or a runtime identifier. These change output
and hosting assumptions and are not necessary for this workflow split.

## Stage caller change

Only the `build` job needs to switch reusable builders and supply the SDK input.
After the new workflow is published to `SurePassId/github-workflows`, use the
actual full commit SHA containing that file:

```yaml
  build:
    needs: [env-vars]
    uses: SurePassId/github-workflows/.github/workflows/build-dot-net-modern.yaml@REPLACE_WITH_PUBLISHED_40_CHARACTER_COMMIT_SHA
    with:
      APP: ${{ needs.env-vars.outputs.app }}
      SLOT: ${{ needs.env-vars.outputs.slot }}
      DEPLOY_ENV: ${{ needs.env-vars.outputs.deploy_env }}
      BUILD_CONFIG: ${{ needs.env-vars.outputs.build_config }}
      BUILD_PROJECT: ${{ needs.env-vars.outputs.build_project }}
      DOTNET_VERSION: '10.0.x'
    secrets:
      SSH_KEY: ${{ secrets.AZURE_SSH_KEY }}
```

This is a non-runnable template until the SHA placeholder is replaced.
GitHub requires the reusable workflow reference to be literal; do not attempt
to calculate its ref from an expression or job output. The current pinned SHA
does not contain the new file and cannot be reused for this new path.

Leave these caller behaviors unchanged:

- The `stage-*` tag trigger and repository-scoped concurrency policy.
- `APP=api`, `SLOT=stage`, `DEPLOY_ENV=prod`, `BUILD_CONFIG=Release`, and the
  existing build project path. `prod` selects production configuration and app
  naming while `stage` selects the deployment slot; do not conflate them.
- Both `deploy-eus2` and `deploy-wus3`, including their dependencies and
  region-specific publish-profile secrets.
- Both deployment jobs' existing reusable workflow commit pins. They can consume
  the new builder's artifact without moving to the new shared-repository commit.

## Hosting and application prerequisites

For framework-dependent publishing, both destination stage slots must have a
compatible .NET 10 / ASP.NET Core runtime and matching platform architecture.
Installing an SDK on a GitHub build runner does not update App Service runtimes.
Confirm the runtime stack, startup behavior, and runtime availability in both
regions before the first deployment; Azure resource settings were not queried
as part of this document.

The self-hosted deployment runner needs to support its pinned download and
deployment actions. It does not need the .NET 10 SDK merely to transfer the
artifact. A future IIS/VM target must separately provision the appropriate
ASP.NET Core Hosting Bundle; this builder does not configure target servers.

The API project still references older packages and a third-party licensing
assembly. Changing the SDK does not establish their .NET 10 compatibility.
Rebuild and test first, then address demonstrated failures; do not bundle a
broad dependency migration into this workflow update. Include referenced
submodules and required native or licensing dependencies in validation.

## Implementation validation

The implementation was validated locally before publishing:

- Actionlint 1.7.12 passed for the new reusable workflow and stage caller.
- 64 targeted assertions passed, covering accepted and rejected SDK channels,
  wrong-major and preview SDK rejection, SDK command failures, PowerShell syntax,
  literal argument handling, directory creation and cleanup, required inputs,
  unchanged checkout/configuration/artifact contracts, and publish output.
- The legacy .NET 8 workflow was verified unchanged.
- Project-scoped restore using NuGet.org and Release publish with `--no-restore`
  succeeded with SDK 10.0.403. The output contains the API assembly, dependency
  file, runtimeconfig, and `web.config`. Runtimeconfig targets `net10.0` and
  requests .NET and ASP.NET Core 10.0.0.
- Existing package pruning, package advisory, and obsolete API warnings were
  observed; no application or package changes were made in this workflow update.

These are local checks, not a live GitHub build or deployment. Recursive checkout,
the custom environment overlay, artifact transfer, application test suites, and
both deployed slots' health still require the rollout checks below. No deployment
tag was created, and no Azure settings were changed.

## Implementation and rollout checklist

1. Add the new reusable workflow in the shared repository, leaving the .NET 8
   file byte-for-byte unchanged. Update the shared repository
   [README](../README.md) with the new input contract and usage example.
2. Validate workflow syntax with the repository's existing tooling, if available,
   and GitHub's reusable-workflow checks. Test valid and invalid SDK input cases.
3. Exercise the new builder through a build-only caller before deploying:
   confirm checkout/submodules, selected SDK major 10, successful project restore
   and publish, environment overlay, artifact upload, and temporary cleanup.
4. Inspect the artifact: require the API assembly, dependency and runtimeconfig
   files, generated `web.config` for the intended Windows/IIS deployment, and
   expected production configuration. Confirm runtimeconfig targets `net10.0`
   and requests the intended .NET / ASP.NET Core shared framework versions.
   Verify actual overlay destinations, not merely that the copy step succeeded.
5. Run the existing API and database test suites under .NET 10 with their required
   dependencies. Project-only restore is not a substitute for application tests;
   the legacy builder itself does not run them.
6. Publish the shared workflow commit. Confirm caller repository access to the
   reusable workflow and private submodules, then update the API caller using
   that real SHA and `DOTNET_VERSION: '10.0.x'`.
7. Verify hosting prerequisites for both regions. Create a new `stage-*` tag
   pointing at the API commit containing the caller change; rerunning a workflow
   for an older tag does not pick up a newer caller file.
8. Confirm both deployment jobs succeed. Check the stage slots' `/status`
   responses and expected dependency health, and smoke-test representative API,
   authentication, database, FIDO, and licensing behavior. Deployment upload
   success alone is not evidence that the application started successfully.
9. For a future released .NET major, reuse this builder with the new channel,
   align project targets and any SDK pin, validate dependencies and runner/action
   compatibility, provision matching hosting support, and repeat these checks.

### Rollback

Retain the previous known-good artifact or release and record the slot settings
before rollout. If validation fails, redeploy that known-good application and
restore compatible runtime settings as needed. Simply pointing a `net10.0`
application back at the .NET 8 builder is not a viable rollback.
If rolling back via source, restore a mutually compatible application version,
caller workflow, shared-workflow pin, and runtime configuration, then deploy
through a new tag. Do not move an existing release tag.

## References

- [actions/setup-dotnet inputs and SDK installation](https://github.com/actions/setup-dotnet#usage)
- [Microsoft: .NET SDK and runtime version selection](https://learn.microsoft.com/en-us/dotnet/core/versions/selection)
- [Microsoft: global.json SDK selection](https://learn.microsoft.com/en-us/dotnet/core/tools/global-json)
- [Microsoft: dotnet publish and implicit restore](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-publish)
- [Microsoft: ASP.NET Core deployment to Azure App Service](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/azure-apps/?view=aspnetcore-10.0)
- [GitHub: calling a reusable workflow](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#calling-a-reusable-workflow)
