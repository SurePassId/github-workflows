# Sandbox VM workflow hardening implementation plan

Review date: 2026-11-04.
Remaining-work checklist refreshed: 2026-11-09.

> **Direction change (2026-11-23), superseding conflicting text below:**
> Current focus is `api-dev`, `mfa-dev` and `saml2-dev`. At the user's direction,
> environment-specific configuration comes from each application repository
> (`environment-files/<env>/`), not `SANDBOX_CONFIGURATION_*` secret bundles.
> `site.lic` may live outside the deployment folder via application configuration.
> HTTP health checks are deferred: SandboxDeployment v2.1.0 stops, backs up,
> replaces and starts the site, with unchanged journaled rollback, but neither
> requires a healthy baseline nor probes health. SAML2 is added, and MFA's four
> known virtual directories are allowlisted. Server v2.1.0 and the action are at
> `035aafcec81af492af217d3d601e78a4f34b7c91`; v2.1.0 is not yet installed on
> sandbox-app and callers are not yet repinned.

## Scope and current status

Implement the reviewed hardening in the
[canonical reusable workflow](../.github/workflows/build-deploy-sandboxvm.yaml)
and its callers. The separate hardening draft has been deleted at the user's
request; do not maintain a parallel workflow or recreate that file.
The review findings below retain the draft's historical design decisions.
This document is a plan, not authorization to change GitHub
App installations, repository secrets, runner configuration, or live IIS sites.

Phases 1 and 2 are complete for API and MFA. The canonical builder uses
`SUBMODULE_APP_CLIENT_ID` as a required string input supplied by a caller variable,
and `SUBMODULE_APP_PRIVATE_KEY` as the required secret. Their checkout App token
has explicit read-only contents access scoped to the caller and two dependencies.
No private-key values were read or changed. Phase 3 is partially implemented:
the tested IIS action prerequisite and warning-only workflow updates are
published, but the full hardening workflow remains local and inactive.
API/MFA health endpoints and normal non-production canary targets are known.
Activation is blocked on restricted-endpoint integration, configuration policy,
and deployment/recovery qualification. Intentional live failure tests still
require an explicitly isolated disposable IIS target; use mocks otherwise.

Primary callers inspected:

- [API sandbox caller](../../SurePassIdApiServer/.github/workflows/deploy-sandboxvm.yaml)
- [MFA sandbox caller](../../SurePassIdLegacyMfaServer/.github/workflows/deploy-sandboxvm.yaml)

Both now pin the sandbox builder to warning-only revision
`710df18b7011bd792ea09d95c2af82968fb52060`. Postman references use the same
commit with the required Client ID input and private-key secret contract.
MFA's Postman job remains commented out.
The active builder also supports
PushServer and IdentityProvider; their callers are outside this workspace and
must be inventoried before a shared contract migration is declared complete.
No sandbox builder references were found in the inspected SAML2 or ServicePass
workflow directories.

### Next executable work and boundaries

**Corrected by the user on 2026-11-09:** the WinRM path is `gh-runner-windows`
to `sandbox-app`, not PRODUCT-SUP-01. The registered runner is
`windows-build-vm (gh-runner-windows)`; its observed Windows `COMPUTERNAME`
is `GH-RUNNER-WIN`. Host guards must compare that Windows machine name,
not the descriptive runner name. The development PC is not a WinRM client for
this VM. Do not test its connectivity, request workstation credentials/network
changes, or modify its WinRM trust. Use the existing runner identity and
restricted endpoint, confirming the machine before any remote check.
An authorized operator may alternatively collect source locally on `sandbox-app`
without WinRM. No new runner or PRODUCT-SUP-01 execution route is required.

**Steps 1a and 1b are complete locally:** deployed-source identity and the
source-backed contract are recorded below; the restricted client passes isolated
transport tests. Step 1c also passed a real upload-only run from GH-RUNNER-WIN,
without activating deployment. **Step 2 is implemented and tested locally**
using secure environment-specific provisioning, not live-file retention.
**Step 3's server implementation and isolated qualification are now local**, not
installed or live-qualified. The next gate is approved installation of the pinned
v2 module and an isolated-site/reconnected-runner qualification, followed by Step 4.
Secret installation, caller forwarding and real configuration qualification remain
activation gates under Steps 4/5; no live deployment is authorized by local tests.
Step 1 is qualified for restricted transfer and cleanup, not live deployment.
The initial host-only check found the correct runner but rejected it under the
now-withdrawn PRODUCT-SUP-01 assumption. That is not a routing/authentication
blocker. The corrected guard continues to reject all other hosts.

| Work | Prerequisite | Completion evidence |
| --- | --- | --- |
| 1a. Collect deployed contract (complete) | Operator-supplied sources and deployed hashes | Four matching SHA-256 hashes, successful static parsing, source-backed contract below |
| 1b. Implement restricted transport and mocks (complete locally) | Verified 1a contract | Corrected guard and harness pass 81 PowerShell 7 tests and 74 PowerShell 5.1 helper/transport tests; syntax/diagnostic/whitespace checks passed |
| 1c. Validate non-deploying transfer (passed) | 1b and existing GH-RUNNER-WIN execution | Run 42706187393: 450809 bytes in three chunks; owned upload and local fixture removed; completion not attempted |
| 2. Configuration/license policy (implemented locally) | Explicit environment-specific secure provisioning | 56 exact-workflow payload tests; API/MFA reject live-file retention; runner secret-file cleanup |
| 3. Server transaction safety (implemented/tested locally; live gate pending) | Operator-approved v2 installation and isolated site | 55 server-safety tests on both PS5.1 and PS7; production IIS/TLS/ACL/runner qualification still required |
| 4 and 5. Workflow integration and activation | Qualified transport and server transaction | Published compatible pins, successful API/MFA sandbox deployment canaries |

Step 1 does not authorize module installation, endpoint re-registration, role
changes, a call to `Complete-SandboxDeployment` against a live site, or caller-pin
activation. Those remain separate approved operations. If server behavior must
change, specify and test those changes under Steps 2/3 before live deployment;
do not compensate by granting the runner unrestricted remoting.

## Review of the hardening changes

This section records the original draft review, not the current completion
checklist. Later Phase 3 evidence supersedes statements here about missing
action files or unverified pins. The remaining-steps checklist governs new work.

| Change in draft | Assessment and implementation decision |
| --- | --- |
| Replace checkout PAT with `actions/create-github-app-token` and recursively check out using its token | Implemented in Phase 1. The canonical builder requests read-only contents permission and explicit caller/dependency scope rather than installation-wide access. |
| `SUBMODULE_APP_CLIENT_ID` input and private-key secret | Adopt a required string input supplied by the caller's `vars.SUBMODULE_APP_CLIENT_ID`. Store the GitHub App **Client ID**, not its numeric App ID or installation ID. Only the private key is a secret. The pinned action exposes `client-id`; its `app-id` input is deprecated. This is a GitHub App installation token, not an Entra application credential. |
| `persist-credentials: false` | Preserve. The App token must not become a persistent Git credential for later build/deployment steps. Keep automatic token revocation enabled. |
| Explicit `pwsh`, 45-minute timeout, `contents: write` | Adopt after runner validation. PowerShell 7 avoids Windows PowerShell 5.1's environment-file encoding behavior. Job-token write permission is for release tagging, not cross-repository checkout. |
| Environment/app-based concurrency instead of per-tag grouping | Implemented in Phase 2 with exact tag prefixes. Callers serialize their full build/test pipeline per environment; the reusable builder separately serializes deployments per normalized app/environment. Distinct caller/deploy group prefixes avoid nesting the same concurrency group. |
| Optional `DEPLOYMENT_ENVIRONMENT` input | Implemented for manual dispatch, with allowed-value validation and rejection of tag/input mismatches. |
| Draft's previous timestamp-only or bare-tag regex | Replaced in Phase 2. The canonical builder and Postman workflow preserve `^refs/tags/deploy2(?<siteEnv>alpha|dev|sandbox)-.*$`, including arbitrary or empty suffix text after the required hyphen. |
| Remove full workspace deletion; clean publish output after checkout | Adopt. Let checkout clean the repository and remove only the explicit publish directory before building. This prevents stale publish files without deleting the runner workspace wholesale. |
| Pin action revisions and upgrade action versions | Adopt pins only after validating each revision's metadata and runner requirements. The App-token revision's `client-id`, `permission-contents`, `repositories`, and default revocation inputs were inspected; other pins still need verification. |
| Drop `fetch-depth: 0` | Conditional. Release tagging uses `context.sha` and does not require full history, but verify build/versioning tools before changing checkout depth. |
| Restore with `--runtime win-x64`, publish with `--no-restore` | Adopt with consistent restore/publish properties. Verify assets for the chosen runtime and deployment model. |
| Change modern publish from self-contained to framework-dependent | Do not bundle into the authentication migration. Preserve `--self-contained true` initially. The draft's `false` requires compatible .NET and ASP.NET Core hosting on every target. |
| Restrict environment-file overlay to .NET Framework | Do not copy without artifact comparison. The active workflow overlays every app; prove modern configuration is equivalent before removing that behavior. |
| Read assembly version without loading the assembly; fail if missing | Adopt. Test both the Framework `bin` layout and the modern application's root assembly layout. |
| Replace inline IIS deployment with `deploy-iis-site` composite action | Separate deployment-safety phase. The action is absent on the current branch and referenced by a mutable feature branch in the draft. Import/review its files and pin an independently published commit. |
| Await release-tag creation after deployment; handle an existing identical tag | Adopt with explicit reporting. A different-SHA conflict must fail; an existing same-SHA tag may succeed. Consider preflight collision checks before modifying IIS. |

### Deployment action review and remaining gaps

The remote feature branch contains
[action.yaml](https://github.com/SurePassId/github-workflows/blob/a255bc2af00999cf88b22dd93c33a2820b8fd5b3/.github/actions/deploy-iis-site/action.yaml)
and
[Deploy-IisSite.ps1](https://github.com/SurePassId/github-workflows/blob/a255bc2af00999cf88b22dd93c33a2820b8fd5b3/.github/actions/deploy-iis-site/Deploy-IisSite.ps1),
reviewed from local `origin/feat/sandboxvm-hardening` at
`a255bc2af00999cf88b22dd93c33a2820b8fd5b3`. GitHub also confirmed the two files
exist on that feature branch. No deployment was executed.

The script validates assembly presence, stages/extracts before stopping IIS,
checks native-command results, waits for IIS state, retains a previous directory,
creates backups, and uses `finally` for recovery/session/archive cleanup.
These are useful improvements, but not a complete rollback guarantee:

- Recovery restores the previous directory only when the live directory is
  absent. Startup failure after the swap leaves the new live release in place.
  Add deployment-state-aware rollback and verify the restored application.
- Keep-list entries are moved out of the live tree before the directory swap.
  A later failure can delete staging, losing those preserved entries from both
  live and previous releases. Copy them or explicitly restore them on failure.
- Free-space estimation uses compressed archive size times three, not the
  actual extracted release and backup requirements. Treat this as a heuristic,
  not a guarantee; improve sizing and test low-space failure.
- Recovery restart commands discard output and do not check exit codes.
  Make recovery errors visible without concealing the original deployment error.
- A cleanup error must not prevent `Remove-PSSession` or local archive cleanup.
  Test nested cleanup failure paths and cancellation; abrupt runner termination
  can bypass `finally`, requiring an operator recovery procedure.
- Validate and contain all computed paths and keep-list entries before removals
  or renames. Clean only site-specific staging/backup paths; never trust an
  unchecked app/environment/run-id/path value.
- IIS reporting `Started` does not prove application health. Add a documented,
  bounded application probe and rollback decision before creating a release tag.
- Serialize by actual site across all participating callers. Repository-scoped
  concurrency alone cannot coordinate different repositories targeting one site.
- Backing up files while the app serves traffic does not guarantee consistent
  mutable data. Establish the backup/keep-list consistency contract.

## Phase 1: GitHub App prerequisites and checkout migration

### Completion evidence

- [x] Verified the organization-owned "SurePassID Submodule Reader" installation
  is active, has read-only code/metadata permissions, and includes both callers
  and the two dependency repositories. The user confirmed all selected
  installation repositories are intentional; none were removed.
- [x] Verified the organization Client ID variable matches the App, and the
  private-key secret exists. Both are available to private/internal repositories;
  both callers are private. Successful token creation verified the key works.
- [x] Published the shared builder at
  `3b8f4826a81432aa171ac4e023aa76359d4f9cad`, then updated API at
  `738ee7f1c09a860442ded1cfa2ebdf33b4abe5ce` and MFA at
  `67908ce2c66ef1996f65aca761da9eac2199ece5` on `release/2026.4`.
- [x] Passed a
  [checkout-only validation run](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/41914931960)
  for API and MFA on the actual self-hosted Windows runner. Each job minted its
  own scoped App token, checked out the expected root and recursive submodule
  commits, found no persisted local Git authentication settings, and logged
  successful post-job token revocation. The isolated test branch is removed
  after validation; no test workflow is added to either release branch.
- [x] Parsed all changed workflow YAML, checked editor diagnostics and caller
  input/secret contracts, tested blank/whitespace Client ID rejection, and
  verified the existing build, release-tagging, and deployment blocks are
  unchanged. Kept full-history checkout and existing recursive SSH-URL handling.
- [x] Set `contents: write` explicitly for the existing builder job and both
  caller jobs. Inspected inherited/current rulesets: the active rules restrict
  updates/deletions of `stage-*` tags, not sandbox release-tag creation.

At Phase 1 completion only builder checkout PAT replacement was complete.
Postman migration is now recorded under Phase 2 below; full build/deployment
canaries and IIS recovery testing remain rollout gates. No build, deployment,
or release-tag creation was performed by the checkout-only test.

### Implemented steps

1. Configure or verify a GitHub App installation under `SurePassId`.
   Grant repository **Contents: read** and required metadata access only.
   No Actions-write, administration, or contents-write permission is needed
   for recursive checkout.
2. Limit installation access to the approved caller/dependency repositories.
   For API and MFA, inspected root
   [.gitmodules](../../SurePassIdApiServer/.gitmodules) and
   [.gitmodules](../../SurePassIdLegacyMfaServer/.gitmodules) reference:
   - `SurePassIdApiServer` or `SurePassIdLegacyMfaServer` (the calling repository)
   - `SurePassIdDotNetLibs`
   - `SurePassIdFidoMDS`
   Inventory recursive dependencies at the exact deployed commits. No nested
   `.gitmodules` files were found in the currently available API/MFA submodule
   trees; that is not proof that all future commits have the same dependency set.
   Include PushServer/IdentityProvider dependencies before migrating them.
3. Provision `SUBMODULE_APP_CLIENT_ID` as a caller-accessible repository or
   selected-repository organization variable. Provision `SUBMODULE_APP_PRIVATE_KEY`
   as a corresponding secret. Use the GitHub App Client ID value and its PEM
   private key. Never put the private key in YAML, logs, or this document.
   Define responsibility for key replacement as described below.
4. In the active builder, replace required `GH_ACTIONS_PAT` with a required
   `SUBMODULE_APP_CLIENT_ID` string input and required
   `SUBMODULE_APP_PRIVATE_KEY` secret. Reject an empty or whitespace-only
   client ID before token creation. Mint a token immediately before checkout with:

   ```yaml
   uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1
   with:
     client-id: ${{ inputs.SUBMODULE_APP_CLIENT_ID }}
     private-key: ${{ secrets.SUBMODULE_APP_PRIVATE_KEY }}
     owner: ${{ github.repository_owner }}
     repositories: |
       ${{ github.event.repository.name }}
       SurePassIdDotNetLibs
       SurePassIdFidoMDS
     permission-contents: read
   ```

   This scope is for the two inspected callers only. Extend the verified
   dependency set explicitly for other supported apps; do not silently fall
   back to installation-wide scope or a PAT. Retain default post-job revocation.
5. Pass `steps.submodule_token.outputs.token` to the pinned checkout action,
   retain `submodules: recursive` and `persist-credentials: false`.
   Root submodule URLs use SSH form; verify checkout's token-based HTTPS
   conversion works recursively on the actual self-hosted runner. Do not
   depend on an ambient SSH key, cached PAT, or global credential helper.
6. Keep the App token distinct from `GITHUB_TOKEN`. Use `GITHUB_TOKEN` with
   `contents: write` for release tags in the caller repository only, never
   the submodule repositories. Keep release tagging in the existing reusable
   build/deploy job; do not split it into a separate job as part of permission
   hardening. The authentication migration must not change release-tag behavior.
   Set that permission explicitly on the caller's reusable build job as well
   as the reusable job; a called workflow cannot elevate the caller's permissions.
   The checkout App token remains Contents: read for all scoped repositories,
   including the caller, and is not used to create release tags.
   Check repository tag rules before rollout.
7. Publish the shared builder commit first, then migrate each caller's SHA
   and secret mappings together. Existing pinned callers remain compatible
   with the old contract until they are deliberately updated.

Caller mapping for the reusable build job:

```yaml
permissions:
  contents: write
with:
  SUBMODULE_APP_CLIENT_ID: ${{ vars.SUBMODULE_APP_CLIENT_ID }}
secrets:
  SUBMODULE_APP_PRIVATE_KEY: ${{ secrets.SUBMODULE_APP_PRIVATE_KEY }}
  SANDBOX_VM_USERNAME: ${{ secrets.SANDBOX_VM_USERNAME }}
  SANDBOX_VM_PASSWORD: ${{ secrets.SANDBOX_VM_PASSWORD }}
  SANDBOX_VM_HOSTNAME: ${{ secrets.SANDBOX_VM_HOSTNAME }}
```

### Self-hosted runner trust: practical checks

This workflow already uses a self-hosted runner. This is not a requirement to
switch to GitHub-hosted runners. It means checking who can execute code on the
existing machine, which can retain files and processes between jobs.

- Restrict the deployment runner/group to approved repositories and, where
  supported, approved workflows. A runner label alone is routing, not an
  access-control boundary.
- Do not run untrusted pull-request code on the same persistent machine.
  Even a job without secrets could leave a process that reads credentials
  during a later deployment. Builds also execute repository/dependency code.
- Review who can create deployment tags, invoke manual deployments, and change
  the workflow or deployed code. Use repository rules and approvals appropriate
  to the team's deployment policy.
- Confirm runner account permissions and machine access are appropriate.
  Remove job-specific archives and credentials; repository cleanup alone does
  not prove the whole machine is clean. Dedicated or fresh runners provide
  stronger isolation, but rebuilding the runner is not an automatic prerequisite.

Verify the existing controls first. These are operational checks, not evidence
that the current runner is compromised.

### Credential lifecycle: what needs maintenance

There are two different credentials:

- The **installation token** is generated per job, expires after one hour, and
  is revoked by the action after the job by default. The workflow handles this;
  operators do not need to replace the token for each run.
- The **App private key** remains valid until revoked and can generate new
  tokens. Keep it in GitHub secrets and assign an owner for replacing it.
  For planned replacement: generate a new key, update the secret, verify a
  checkout-only run, then revoke the old key. If a key is exposed, revoke it
  promptly and follow the incident procedure rather than leaving it active
  for a convenient transition.

Agree on a key-review/replacement policy; this plan does not assume a mandatory
rotation interval. The Client ID is an identifier, not a rotating credential.
HTTPS checkout with the App token works with user MFA enabled; no interactive
MFA prompt or disabling MFA is required. Organization App policies still apply.

## Phase 2: Callers, manual deployment, and Postman continuity

### Completion evidence

- [x] Both callers retain their existing push tag filters and now offer a
  required manual-dispatch environment choice. They pass
  `DEPLOYMENT_ENVIRONMENT` to the builder and, for API, the Postman workflow.
- [x] Builder and Postman consistently derive environments
  from valid tags, accept arbitrary suffixes, require an explicit environment
  for branch runs, reject invalid tags and tag/input mismatches, and normalize
  allowed environments to lowercase.
- [x] Added `cancel-in-progress: false` concurrency at the caller level so
  a subsequent same-environment deployment does not overtake Postman tests.
  Added a distinct reusable deployment group scoped to repository, normalized
  app, and environment. Keys are independent of unique deployment-tag suffixes.
- [x] The user added `PostmanFiles` to the App installation; verified it is
  selected. The Postman job mints its own Contents: read token scoped only to
  `PostmanFiles`, uses pinned checkout with no persisted credentials, and
  validates the globals file. No installation permissions were changed by
  this implementation.
- [x] Removed `GH_ACTIONS_PAT` from both sandbox callers, including MFA's
  commented Postman example, and from the active Postman reusable workflow.
  Kept `POSTMAN_API_KEY`; it authenticates to Postman, not GitHub.
  MFA's unconfigured Postman job remains disabled.
- [x] Published the shared workflows at
  `92a2b41c1a4ca03bb6bb21dbe606ff10f50c5cc0`, then pinned API at
  `d654346eb80f6d41e2124d96a6a03af28b7e9253` and MFA at
  `04428b86a482ac5884f85e8ce0ede640f340149c` on `release/2026.4`.
- [x] Local script tests passed 25 environment cases for each of the builder,
  Postman workflow, and the draft before it was deleted. Tests covered arbitrary/empty suffixes, manual
  branch runs, invalid inputs, missing hyphens, and mismatches. Checked
  concurrency expressions from the YAML for same-site collisions, independent
  environments/apps, and distinct IdP sites.
- [x] Verified caller input/secret contracts, tag filters, permission levels,
  explicit skip notices, globals-file validation, and exact alpha Postman CLI
  arguments using a mock CLI. Editor diagnostics and YAML parsing passed.
- [x] The
  [self-hosted runner validation](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/41919184342)
  successfully checked out private `PostmanFiles`, parsed its globals JSON
  without logging its contents, found no persisted Git authentication, and
  revoked the token. Actual published reusable-workflow calls for dev and
  sandbox explicitly skipped token creation, checkout, installation, login,
  and tests. Temporary validation helpers are removed after testing.

Alpha command selection/invocation was tested with a mock, not against live
Postman/API services. No deployment, release-tag creation, or live API tests
were performed. These remain controlled integration/canary checks.
The existing single-job release tagging and all build/publish/IIS deployment
blocks remain unchanged.

The tag parser accepts slash-containing suffixes, but the preserved caller
filters use `*`, which does not match `/` in GitHub ref filters. Such tags do
not automatically trigger these callers; manual dispatch against a matching
tag still validates its environment. No automatic-trigger scope was broadened.

### Implemented steps

1. Preserve both callers' explicit `deploy2alpha-*`, `deploy2dev-*`, and
   `deploy2sandbox-*` push filters. Keep manual dispatch.
2. Add a manual-dispatch environment choice (`alpha`, `dev`, `sandbox`) and pass
   it as `DEPLOYMENT_ENVIRONMENT`. Tag pushes derive the target from the ref;
   manual branch dispatch requires an explicit valid input. Any tag/input
   disagreement fails before checkout or deployment.
3. Use exact tag prefixes with hyphens in concurrency expressions. Key on the
   normalized app/site and environment, with `cancel-in-progress: false`.
   Test different timestamp/custom suffixes colliding for the same site and
   different sites remaining independent. Invalid refs must fail, not deploy
   through a fallback group.
4. The API's active `RunPostmanTests` job calls
   [run-postman-tests.yaml](../.github/workflows/run-postman-tests.yaml),
   now using the App-token and tag/manual input contracts. Its previous
   branch-only parser and checkout PAT dependency have been removed.
5. For complete sandbox PAT retirement, migrate Postman's checkout too:
   provision read-only App installation access to `PostmanFiles`, mint a
   separate job-local token scoped only to that repository, and use the
   required client-ID input/private-key secret contract. Supply the input from
   the caller variable. Do not share the builder's short-lived
   token across jobs. Keep `POSTMAN_API_KEY`; it serves a different purpose.
   Pass only necessary credentials and grant the Postman job `contents: read`.
6. Preserve alpha-only Postman configuration and explicitly report unconfigured
   dev/sandbox tests as skipped. Do not turn skips into claims of test coverage.
   Preserve MFA's commented-out Postman job unless tests are actually configured.
7. If Postman migration is deferred, retain its existing PAT mapping and label
   the milestone "builder checkout PAT removed", not "all PATs removed".
   Do not delete/revoke `GH_ACTIONS_PAT` until every remaining consumer has
   been inventoried and migrated.

## Phase 3: Remaining hardening and deployment safety

Apply all remaining workflow changes to
[build-deploy-sandboxvm.yaml](../.github/workflows/build-deploy-sandboxvm.yaml).
It is the sole maintained workflow and the final destination for hardening;
no separate hardening YAML is retained.

### Progress and activation gate

- [x] Prepared explicit `pwsh` and a 45-minute job timeout locally, retaining
  the existing permissions and Phase 2 concurrency.
- [x] Replaced broad workspace deletion with publish-directory-only cleanup
  after checkout. Cleanup refuses redirected/reparse-point publish directories.
  Local tests verified consecutive cleanups remove stale output without
  removing other workspace files.
- [x] Pinned the currently used actions to verified Node 24 commits:
  checkout v7.0.1, MSBuild v3, setup-dotnet v6.1.0, and github-script v9.0.0.
  Verified action metadata, unchanged MSBuild x86 defaults, and the supported
  writable SDK-directory override. Kept restore, self-contained publishing,
  and environment overlays unchanged.
- [x] Replaced assembly loading with metadata-only version extraction and an
  explicit missing-output error. Local tests passed for root and Framework
  `bin` layouts and rejected a missing assembly.
- [x] Installed .NET SDKs into `${{ runner.temp }}\dotnet`, not the protected
  `C:\Program Files\dotnet` directory. Actual runner validation exposed the
  service account's missing installation permissions; the job-local override
  was verified against the pinned setup-dotnet action and passed on retry.
- [x] Added explicit published `web.config` validation before deployment.
  An incomplete payload cannot replace the running site; configuration is not
  silently borrowed from another environment or copied from production.
- [x] Tested the actual workflow scripts locally: 24 environment cases,
  18 health-URL cases, 16 release-tag cases, and configuration preflight.
  Tag tests covered awaited creation, lightweight/annotated same-SHA reruns,
  conflicting SHAs, denied permissions, API errors, and caller-only scope.
- [x] In the historical published prerequisite, implemented staging, rollback, preserved-file handling,
  native-command checks, exact-200 health probe, and explicit cleanup/recovery
  failures. Mocked tests passed: 61 under PowerShell 7 and 52 under Windows
  PowerShell 5.1. This unrestricted remote implementation was superseded locally
  by Step 1b's restricted transport; it is not evidence that the actual server
  module implements those guarantees.
- [x] Implemented the restricted ZIP/chunk client and isolated transport tests
  locally. The action is explicitly upload-only; normal deployment fails closed
  until the server preservation/health/rollback contract is qualified.
- [x] Prepared awaited/idempotent release tagging locally after the deployment
  action, including tag-collision preflight. This ordering is not proof of
  restricted-endpoint health verification.
- [ ] Qualify the restricted deployment/health contract, publish compatible
  action/workflow prerequisites, and activate caller pins after the rollout gates.

The tested IIS action prerequisite
`941d610198019171a5104a41e1403561bb44266a` is now published as an ancestor of
warning-only shared commit `710df18b7011bd792ea09d95c2af82968fb52060`.
The remaining IIS-hardening workflow/plan edits and Step 1b action changes
remain uncommitted.
The canonical workflow's local full-SHA action pin references that prerequisite,
prepares health URLs, preflights tag collisions, and places awaited, idempotent
release tagging after deployment. Both callers use the warning-only revision,
which retains Phase 1/2 deployment behavior rather than activating Phase 3.
Activation still requires complete configuration/access validation, publication
of the full hardening workflow, and successful canaries.

### Build warning remediation

Published shared commit `710df18b7011bd792ea09d95c2af82968fb52060` changes only
the sandbox/Postman action pins and the job-local .NET SDK installation path.
It does not activate the staged IIS changes. API caller commit
`008b6fb4bbd514dea7a7be7ef2d3d5c751944959` and MFA caller commit
`224c3d9163d0e7b18fc896de58ff864d2f65b405` pin this shared revision.

API's .NET 10 FIDO submodule now records
`ed919828a10dfa697a9f699f400f7e010df5bd5c`, replacing the two obsolete
`X509Certificate2(byte[])` constructors with
`X509CertificateLoader.LoadCertificate`. These inputs are DER X.509
certificates, not PKCS12 containers. Regression checks verified unchanged
leaf/root certificate identities and rejection of malformed or wrong-format
input. The local library rebuild passed with `SYSLIB0057` treated as an error.
MFA's .NET 8 submodule remains unchanged; adopting the .NET 10 revision would
be an unrelated and incompatible framework migration.

[Runner validation 41936361350](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/41936361350)
successfully checked out the corrected submodule, published the API with
`SYSLIB0057` as an error, and exercised Node 24 github-script with a read-only
`git.getRef` call. The completed check had zero warning annotations. It did not
use WinRM, alter IIS, run live Postman tests, or create release tags.

### Current restricted action contract and recovery limitations

The implementation and fixture tests are:

- [action.yaml](../.github/actions/deploy-iis-site/action.yaml).
- [Deploy-IisSite.ps1](../.github/actions/deploy-iis-site/Deploy-IisSite.ps1).
- [Deploy-IisSite.Tests.ps1](../.github/actions/deploy-iis-site/Deploy-IisSite.Tests.ps1).
- [Test-SandboxUpload.ps1](../.github/actions/deploy-iis-site/Test-SandboxUpload.ps1):
  standalone operator harness for Step 1c, using generated inert content only.

Required inputs are `computer-name`, `username`, `password`, `site-env`,
`app-name`, `source-path`, `app-assembly`, `run-id`, and `health-check-url`.
Optional `keep-list` contains comma-separated direct child names only.
For API/MFA it must be empty: Step 2 provisions configuration/licenses into the
package rather than retaining live files. Other application contracts are unchanged.
New optional `upload-only` defaults to the string `false`, which fails before
source access or any connection. The explicit string `true` enables only package
upload/removal, never deployment. Invalid boolean strings fail explicitly.
Values are passed through environment variables, not interpolated into script
source. Health URLs must use HTTPS on the exact app/environment hostname.
The run identifier includes the numeric GitHub run ID and attempt.

Upload-only validates assembly, run ID, keep-list and health intent, but does not
apply preservation or probe the application. Nested keep entries, duplicate names
and entries overwriting the application assembly/parent are rejected. No input
is silently treated as a server guarantee. Only `GH-RUNNER-WIN` may connect,
to `sandbox-app` (or its FQDN) using the dedicated account and the
`SurePassID.SandboxDeploy` endpoint with Negotiate. No fallback or trust/TLS
configuration changes are implemented.

From the shared repository root, verified test commands are:

```powershell
& {
    pwsh -NoProfile -File .github\actions\deploy-iis-site\Deploy-IisSite.Tests.ps1
    if ($LASTEXITCODE -ne 0) {
        throw 'PowerShell 7 transport tests failed.'
    }
    powershell -NoProfile -File .github\actions\deploy-iis-site\Deploy-IisSite.Tests.ps1
    if ($LASTEXITCODE -ne 0) {
        throw 'PowerShell 5.1 helper/transport tests failed.'
    }
}
```

The suites use isolated fixtures and mocks; they do not operate real IIS,
WinRM, HTTP endpoints, or server functions. PowerShell 7 is required by the
actual action entry; 5.1 exercises compatible helpers/transport only. The older
61/52-case staged-IIS fixture suite has been replaced, not counted as current
server recovery qualification. Server transaction tests belong to Step 3.

The client logs its owned upload ID. Before completion, an available session may
remove only that upload; cleanup failures fail the job. A lost session retains
the upload and reports operator follow-up. Creation with a lost/invalid response
requires inspecting staging without guessing an ID. Any attempted completion,
including an IIS Started response or malformed/lost result, retains upload
recovery data and fails rather than claiming qualified application success.
The action entry cannot request completion; that primitive is exercised only
with mocks in this phase.

Cancellation can bypass cleanup. Operators must inspect the specific upload,
external backup, site state and any active server worker before recovery or
removal. The deployed module's lock file is not a persistent failed-recovery
barrier. Do not assume the historical action's previous-tree/lock procedure
applies to the current in-place server transaction; Step 3 must qualify it.

### Actual-runner evidence and current blockers

- API build-only validation passed:
  [run 41927040763](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/41927040763).
  It published 654 files, assembly version `26.4.9804.26408`, and `web.config`;
  an injected stale publish file was removed. No deployment or release tagging
  was performed.
- MFA compilation/publishing and assembly extraction succeeded:
  [run 41926620637](https://github.com/SurePassId/SurePassIdLegacyMfaServer/actions/runs/41926620637).
  Final artifact validation failed because root `web.config` was absent.
  The repository does not track its root `web.config`; the inspected
  non-production overlays do not supply it. Provide environment-specific
  runtime configuration through an approved secure mechanism. Do not commit
  credentials or reuse the production configuration. Explicitly approving a
  tested server-side configuration retention policy is an alternative, but
  is not silently enabled by this implementation.
- A strictly read-only MFA sandbox IIS inventory failed at `New-PSSession`:
  [run 41927705895](https://github.com/SurePassId/SurePassIdLegacyMfaServer/actions/runs/41927705895).
  WinRM returned **Access is denied** with the current `SANDBOX_VM_*` secrets.
  The operator must verify the target, account/password, and that the account
  is authorized for the remote PowerShell endpoint and required IIS/filesystem
  operations. Do not resolve this by disabling authentication, broadening
  access indiscriminately, or printing secrets.

### Restricted endpoint verification: 2026-11-06

The earlier authentication failure is now explained: `github-deploy` can access
the dedicated `SurePassID.SandboxDeploy` endpoint, not the default endpoint used
by the workflow. Windows PowerShell 5.1 endpoint inspection confirmed
`RestrictedRemoteServer`, `RunAsVirtualAccount = true`, and the
`SurePassIDSandboxDeployer` role from the server-side `SandboxDeployment` module.
Do not replace this with unrestricted remoting or weaken UAC restrictions.

[Actions run 42253705055](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/42253705055)
passed using the real GitHub secrets and Windows runner service context:
the dedicated session opened, all four deployment functions were visible,
`New-SandboxUpload` created an empty API sandbox upload, `Remove-SandboxUpload`
removed it, and the session closed. No deployment, IIS state change, package
payload, or release tagging occurred.

The role exposes `New-SandboxUpload`, `Add-SandboxUploadChunk`,
`Complete-SandboxDeployment`, and `Remove-SandboxUpload`. At this verification,
the inline deployment and prepared IIS action used arbitrary remote scripts/native
commands and could not be migrated by changing the endpoint name alone.
Step 1b now replaces that local client implementation with permitted-function
transport; the published pins remain unchanged. Preserve the endpoint's
restrictions during subsequent integration.

The inspected server deployment function accepts a ZIP upload and SHA-256,
stops IIS for backup/content replacement, attempts rollback, and preserves
existing MFA `web.config` when absent from the package. However, its shown
success criterion is IIS Started state, not exact HTTP 200 application health.
Chunk upload, full server-side recovery behavior, health-checked rollback,
configuration/license preservation, and safe workflow integration still need
validation before rollout. The initial local builder rejected an MFA payload
without `web.config`. Step 2 below now provisions that file securely before
validation; it does not bypass the check or depend on the old server fallback.

`prod-product-sup-01` has not been inspected or contacted by these Actions.
Its deployment account and endpoint require a separate read-only inventory
before any production configuration changes or remote test.

Rollout remains blocked by restricted-endpoint integration and deployment
qualification, not sandbox credential authentication. The real API/MFA caller
pins include the warning-only updates but retain Phase 1/2 deployment behavior.
Phase 3 must not be marked complete or activated yet.

### Health-check contract and approved targets

The user supplied the existing readiness endpoints and authorized normal
canary deployments to the actual non-production sandbox/dev/testing sites:

- API: `https://api-<env>.surepassid.com/status`.
- MFA: `https://mfa-<env>.surepassid.com/server/HealthCheck.aspx`.

Both endpoints must return exactly HTTP 200; redirects are not success.
API checks include database, configuration, and license readiness. MFA checks
include its heartbeat/database/configuration status; credentials can be
required if credential verification is enabled. Do not print response bodies
or disable TLS validation.

Read-only baseline probes returned API alpha 500, API dev 503, API sandbox 200,
and MFA alpha/dev/sandbox 200. Use sandbox for normal API/MFA canaries; the API
alpha/dev failures predate this work and must not be masked by weaker checks.
An explicit `HEALTH_CHECK_PATH` is required before PushServer or IdentityProvider
adopts the new workflow revision; their existing pins remain unaffected.

Intentional failure-path tests use mocks or an explicitly isolated disposable
site, not deliberate corruption of the shared sites. No live deployment has
occurred yet. The separate hardening draft was deleted; maintain only the
canonical workflow.

### Remaining implementation steps

The earlier implementation list is superseded by this ordered checklist.
The completed/local work in "Progress and activation gate" remains evidence,
not proof that the restricted endpoint or live deployment has been qualified.
Do not repeat the already completed cleanup, metadata extraction, or action-pin
work unless integration changes require regression testing.

#### Step 1 investigation: 2026-11-09

An existing restricted-endpoint client is available in
[the candidate workflow at 6337ada](https://github.com/SurePassId/github-workflows/blob/6337ada638c842d641c98a91e4de92ef5ed67de1/.github/workflows/build-deploy-sandboxvm.yaml)
on `sandbox-app-constrained-deploy`. Reuse its protocol after verifying the
deployed server contract; do not merge its unrelated older workflow behavior.
The candidate client:

- Connects with Negotiate to `SurePassID.SandboxDeploy` and imports only the
  four deployment functions.
- Creates a ZIP without a containing root directory, computes SHA-256, and
  calls `New-SandboxUpload -SiteName`, expecting an upload identifier.
- Sends base64-encoded chunks using
  `Add-SandboxUploadChunk -UploadId -Offset -Base64`, expecting the cumulative
  received-byte count. It uses 192 KiB decoded chunks and a 4 GiB package cap.
- Calls `Complete-SandboxDeployment -UploadId -Sha256` and reads `SiteName`,
  `Destination`, `Backup`, and `State` from the result.
- Calls `Remove-SandboxUpload -UploadId` in cleanup.

These were initially client-side assumptions. The supplied source now verifies
the signatures and limits, as recorded below. Unconditional cleanup after
ambiguous completion must not be copied: removal has no recovery-state guard.
Chunk acknowledgement failure must stop the upload without blindly retrying an
append. The earlier missing-source blocker is resolved; no action code, caller
pins, endpoint configuration, or live sites were changed during collection.

#### Step 1a: read-only contract collection

**Operator discovery evidence: 2026-11-09.** The user ran the guarded read-only
discovery block locally on `sandbox-app` and supplied:

- Registered endpoint: `SurePassID.SandboxDeploy`.
- Endpoint configuration:
  `C:\Windows\System32\WindowsPowerShell\v1.0\SessionConfig\SurePassID.SandboxDeploy_d4517f78-9898-47cf-9d4c-0e8b23d34464.pssc`.
- Discovered module: `SandboxDeployment`, version `1.0.0`.
- Module directory: `C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment`.
- Manifest:
  `C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\SandboxDeployment.psd1`.

The user also supplied SHA-256 hashes from the guarded read-only collection
block on `sandbox-app`. These identify the deployed originals, not redacted
copies. On 2026-11-09 the four source copies supplied under `Z:\RDP\winrm`
were hashed locally and all four matched the deployed-file hashes exactly.
All four files passed static PowerShell parsing without importing the module
or invoking any deployment function. The three data/configuration files use
UTF-16LE; the original supplied bytes were not modified.

| File | SHA-256 |
| --- | --- |
| `C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\SandboxDeployment.psd1` | `06AC0727A59A18CDE8BCCD1C33D6F6B0F67C2850890E6900BDE1C9659022091D` |
| `C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\SandboxDeployment.psm1` | `E9695B825D354B1FF622794EFF99CD992300A5601230D53B95E43EC1EEA48D6F` |
| `C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\RoleCapabilities\SurePassIDSandboxDeployer.psrc` | `3503791ADC81E07D4CA65E13F412E55E4DF559519938C5AB215A59F12EBC0E58` |
| `C:\Windows\System32\WindowsPowerShell\v1.0\SessionConfig\SurePassID.SandboxDeploy_d4517f78-9898-47cf-9d4c-0e8b23d34464.pssc` | `6F0A9DF55ECD5EDBA468D87902D3CD24FBD95E1DC0067C569A46EB0BAB933885` |

Endpoint registration, module discovery, source identity, and the source-backed
function contract are now recorded for the correct server. Step 1a is complete
for implementation planning. This is static source verification, not a new
live remoting/deployment qualification. The role imports the module by name,
without a version/path pin; verify effective command/module resolution again
from the approved execution host before live use rather than assuming these
copies prove future session resolution.

**Correction: 2026-11-09.** The development-workstation WinRM attempts used the
wrong execution host and are not Step 1a validation evidence. Their trust/DNS
errors are not deployment blockers and do not justify workstation configuration
changes. No inventory script ran remotely, no deployed files or hashes were
collected, and no trust, endpoint, role, or IIS settings were changed.
Those attempts did not advance contract collection. The later operator-supplied
files and hash verification, not workstation connectivity, completed Step 1a.

Continue through `GH-RUNNER-WIN` for permitted remote metadata inspection,
or have an authorized operator collect the source locally on `sandbox-app`.
Do not run the administrative discovery commands below through the restricted
endpoint: its permitted deployment functions do not imply administrative source
read access. If that role cannot expose the required evidence, use local operator
collection rather than widening its permissions.

**Owner:** an authorized operator with local read access on `SANDBOX-APP`.
The implementation author consumes the reviewed evidence; the GitHub runner
must not be given additional privileges to collect it. The operator should use
an existing approved local administrative session, not the restricted deployment
endpoint, and run these discovery commands in Windows PowerShell 5.1:

```powershell
& {
    $ErrorActionPreference = 'Stop'
    if ($env:COMPUTERNAME -ine 'sandbox-app') {
        throw 'Run this directly on sandbox-app.'
    }
    Get-PSSessionConfiguration -Name 'SurePassID.SandboxDeploy' |
        Select-Object Name, ConfigFilePath, Permission
    $deploymentModules = @(Get-Module -ListAvailable -Name SandboxDeployment)
    if ($deploymentModules.Count -eq 0) {
        throw 'SandboxDeployment was not found; inspect the registered endpoint configuration for its module path.'
    }
    $deploymentModules | Select-Object Name, Version, ModuleBase, Path
    foreach ($deploymentModule in $deploymentModules) {
        Get-ChildItem -LiteralPath $deploymentModule.ModuleBase -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1', '.psrc', '.pssc') } |
            Select-Object FullName
    }
}
```

These commands discover metadata and paths, not source contents. A module found
on disk is not automatically the version used by the endpoint. Follow the
registered endpoint configuration's module paths/version constraints and the
role capability resolution to identify the effective files. If its configuration
file path is not returned, the operator must locate it through the approved
server configuration inventory; do not assume a path or change registration.

The operator then reviews and supplies:

1. The effective module script, manifest, and any helper scripts/configuration
   used by the four deployment functions.
2. The effective `SurePassIDSandboxDeployer` role capability and relevant endpoint
   configuration, including allowed-site restrictions and role/module mappings.
3. Module version, source paths, collection time, and SHA-256 hashes of the
   effective files, computed locally with `Get-FileHash -Algorithm SHA256`.
   Distinguish original deployed-file hashes from hashes of redacted copies.

Inspect files locally before sharing. Exclude credentials, keys, application
configuration values, and transcript contents. Supply reviewed non-secret copies
or accessible paths through an approved channel; keep raw server evidence outside
Git. Record only the non-secret contract and evidence references in this plan.
Do not upload raw definitions or sensitive configuration into Actions logs.
Source collection must not invoke deployment functions or change IIS state.

If full source cannot be shared, the operator can review it locally and supply
the following complete contract record with source/version evidence. Command
syntax alone is insufficient because it does not establish authorization,
integrity verification, or recovery-safe cleanup.

| Contract item | Required verified detail | Current evidence |
| --- | --- | --- |
| Endpoint and authorization | Effective role, permitted functions/sites, identity and upload ownership rules | PSSC maps `SANDBOX-APP\github-deploy` to `SurePassIDSandboxDeployer`, with `RestrictedRemoteServer` and virtual-account execution. PSRC imports `SandboxDeployment` and exposes the four deployment functions; no external commands are added. Upload metadata has no per-caller owner. |
| `New-SandboxUpload` | Exact parameters/types, identifier/result shape, collision behavior, staging ownership and expiry | Mandatory string `SiteName`; validates approved IIS mapping/tree before creating a GUID-N upload directory and empty `package.zip`. Returns one 32-hex-character string. Metadata stores site and UTC creation time only; GUID collision is not explicitly rejected. |
| `Add-SandboxUploadChunk` | Parameters/types, decoded/encoded limits, package cap, offset/retry behavior, exact acknowledgement type/meaning | Mandatory string `UploadId`, long `Offset` in 0..4294967296, string `Base64` length 1..262144. Decodes base64, exclusively opens package, requires exact current-length offset, caps total at 4 GiB, writes and returns one long cumulative byte count. 192 KiB decoded chunks encode to the 262144-character ceiling. No idempotent retry contract. |
| `Complete-SandboxDeployment` | Hash format, server-side SHA-256 verification before extraction/IIS changes, result shape, failure/rollback semantics | Mandatory string `UploadId` and 64-hex-character string `Sha256`. Revalidates site, takes an exclusive site file handle, verifies package hash before extraction/IIS changes, extracts, backs up stopped content, replaces in place, starts IIS. Returns `SiteName`, `Destination`, `Backup`, `State = Started`; no application health guarantee. |
| `Remove-SandboxUpload` | Idempotency, ownership checks, allowed lifecycle states, whether removal touches recovery data | Mandatory 32-hex string `UploadId`; validates staging tree then recursively removes its directory if present. No expiry, caller-ownership, completion-state or active-deployment lock check. Absent upload is a no-op when the staging root is valid. Deletes package, expanded and restore trees; external site backup is outside this directory. |
| Ambiguous outcomes | State/artifact handling after lost responses, interrupted append/completion, session loss and cancellation | No status/query/resume function. Create with a lost response leaves an unknown ID; append may have persisted bytes before the response is lost. Completion can leave changed content/recovery data. Do not blindly retry or remove uploads after attempted completion; retain identifiers/artifacts and require operator inspection. |

#### Verified server details and required follow-ups

Source references below use the supplied original file names and 1-based lines.
Raw server files remain outside Git; do not copy them into the repository merely
to implement the client.

- **Module/role chain:** `SandboxDeployment.psd1:13-16,40,76-80` identifies root
  script `SandboxDeployment.psm1`, module `1.0.0`, PowerShell `5.1`, and the four
  function exports. `SurePassIDSandboxDeployer.psrc:16,28` imports that module and
  exposes those functions. The PSSC selects the role by name; this establishes
  the supplied configuration chain, not an inventory of all possible duplicate
  role/module names on the server.
- **Sites:** `SandboxDeployment.psm1:5-16,68-83` permits API/MFA/Push for
  alpha/dev/sandbox, OIDC alpha/sandbox, and OIDC-client alpha only. IIS physical
  path and app-pool name must match the fixed map; child applications and reparse
  points are rejected. OIDC sandbox has the special path
  `E:\iis_sites\sandbox\oidc\oidc-sandbox.surepassid.com`; do not recompute it using
  the client's generic layout.
- **Upload lifecycle:** `SandboxDeployment.psm1:85-142` uses
  `%ProgramData%\SurePassID-SandboxDeploy\<UploadId>`. Add/completion reject
  uploads older than 24 hours; this is validation, not automatic deletion.
  Remove does not apply the age check. Neither metadata nor removal binds an
  upload to a caller/run ID. The client must track only its returned ID, never
  enumerate/remove other uploads. Server-side ownership and removal/deployment
  coordination need explicit Step 3 review before deployment qualification.
- **Archive limits:** `SandboxDeployment.psm1:18-48` rejects more than 100000 ZIP
  entries, more than 8 GiB expanded content, no-file packages, duplicate paths,
  unsafe Windows/traversal paths and encoded symbolic links. Backup extraction
  skips entry-count/expanded-size/no-file limits, not path validation. Upload
  transport must enforce the 4 GiB package cap before creating remote staging.
- **Preservation:** `SandboxDeployment.psm1:166-174,242-251` retains existing MFA
  root `web.config` only when the package lacks one; otherwise package content
  replaces it. OIDC server keeps `keys`, `logs`, `spidp_log.txt`. There is no
  configurable keep-list, assembly check, run-ID or health-URL parameter, and no
  general license-preservation guarantee. Step 2 must reconcile these semantics
  with the existing action inputs/preflight; do not silently ignore those inputs.
- **Completion/recovery:** `SandboxDeployment.psm1:219-300` holds an exclusive
  site lock handle through completion and rollback, but releases it in `finally`
  even after failed recovery. The lock file's existence alone does not block the
  next deployment. Content is replaced in place, not via a staged-directory swap.
  Rollback re-extracts the backup and reapplies the same keep-list, then restores
  prior IIS states without checking HTTP health. Step 3 must add health-qualified
  success/rollback, verified recovery blocking, capacity/worker-drain checks,
  and isolated failure-path tests before live completion is enabled.
- **Backup/cleanup:** backups are timestamp-named ZIPs beside the live site,
  created after IIS stop with SYSTEM/Administrators ACLs; an existing timestamp
  backup causes failure before stop. Successful completion prunes matching
  backups to three; prune failures are warnings. Upload removal is separate,
  does not check transaction state, and can delete recovery working directories.
  Client cleanup must be conservative after completion is attempted, including
  malformed results or lost responses; a later client health probe cannot make
  server rollback atomic or recover discarded state.

**Step 1a result:** source collection and contract inspection are complete.
The Step 1b client and local mocks have now been implemented against these exact
limits and response shapes. Subsequent Step 1c qualification from GH-RUNNER-WIN
is documented below. No live server functions were invoked for this inspection;
server upgrades and live deployment remain gated by Steps 2/3.

**Exit gate:** each row has a source-backed answer or an explicit server change
required under Steps 2/3. Transport implementation can proceed once the upload
contract is verified. Live completion remains blocked until server safety is
qualified; unsupported required guarantees must fail explicitly.

#### Step 1b/1c: transport acceptance and non-deployment validation

**Step 1b implementation evidence: 2026-11-09.** The current local action script
replaces arbitrary remote bootstrap/native deployment with four fixed,
parameterized `Invoke-Command` calls on the restricted session. No implicit
remoting proxy module is created, so only session cleanup is needed.
ZIP generation includes hidden files, nested files and empty directories without
an extra root; source/ancestor reparse points and unsafe names are rejected.
The client hashes the same exclusively held ZIP stream it uploads, checks the
4 GiB/8 GiB/100000-entry ceilings before remote staging, sends 192 KiB decoded
chunks, and requires a single Int64 cumulative acknowledgement for every chunk.
No blind append retry is implemented.

The action adds `upload-only: 'true'` for the approved non-deployment check;
the default `false` deliberately fails closed until Steps 2/3 are complete.
Do not set upload-only in the normal deployment workflow: a passing upload
must never advance that workflow to release tagging as if deployment occurred.
Keep caller pins and the canonical builder's published action pin unchanged
until the later integration/activation steps.

Local validation passed:

- 77 isolated tests under PowerShell 7, including entry orchestration, partial ZIP
  cleanup, exact limits, full/short chunks, byte/hash identity, denied operations,
  malformed responses, interrupted reads/calls, ambiguous completion retention,
  original-error preservation, and independent remote/local cleanup.
- 73 helper/transport tests under Windows PowerShell 5.1; the four PS7-only entry
  cases are excluded. Both PowerShell files passed static syntax parsing.
- Action, canonical workflow and API/MFA caller YAML parsed. Metadata forwards
  all existing inputs through environment variables and adds only `upload-only`.
  The existing action prerequisite pin and warning-only caller pins were verified
  unchanged. No server source, configuration, secrets or GitHub settings changed.
- Editor diagnostics reported no errors in the action and both PowerShell files.
  The scoped Windows-aware action whitespace check passed. The pre-existing
  modified canonical workflow was not reformatted or otherwise changed here.

**At the end of Step 1b, Step 1c was still pending:** no live connection, upload,
completion, HTTP probe, IIS operation or release tagging was performed by Step 1b
tests or the subsequent host-only Actions check. The real upload result follows.

#### Step 1c execution-host correction and qualification: 2026-11-09

The user approved proceeding with upload-only qualification. Before using
credentials or connecting, an isolated secrets-free Actions workflow checked the
existing `[self-hosted, Windows, windows-build-vm]` routing:

- [Host-check run 42704627322](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/42704627322),
  job `129458081527`, ran on `GH-RUNNER-WIN` with PowerShell 7.
- Runner name: `windows-build-vm (gh-runner-windows)`, group `default`.
  The original `PRODUCT-SUP-01` guard stopped before WinRM. The user subsequently
  corrected that host assumption: GH-RUNNER-WIN is the intended client.
- No secrets were referenced, no checkout/build/application code was executed,
  and there were no connections, uploads, IIS operations or release tags.
- The temporary API validation branch was deleted after verifying its owned
  commit and completed run; the release branch/caller pins were not changed.
  No new runner, label, organization permission or trust setting was configured.

The obsolete PRODUCT-SUP-01 operator bundle is withdrawn. All client/harness
guards and tests now use the confirmed machine name GH-RUNNER-WIN; no runner,
network, role or trust settings were changed.

The corrected check **passed** as
[run 42706187393](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/42706187393)
from an isolated API validation revision
`03126c4da353021bec2e7fe46ccf85ec89f7af94`. It copies the exact tested client
into that temporary revision, sparse-checks out only the validation action files,
and runs `Test-SandboxUpload` on the existing runner using the existing secrets
without reading their values locally. This temporary local-action copy is
qualification scaffolding, not a change to the canonical shared-action contract.
Normal API/MFA callers and shared prerequisite pins remain unchanged.

The harness generates an inert 450000-byte fake assembly plus configuration,
hidden-file and empty-directory markers; uploads only to API sandbox staging;
then removes its owned upload, ZIP and fixture. It never calls completion or
probes the health URL. Success requires `ExecutionHost = GH-RUNNER-WIN`,
`Mode = UploadOnly`, at least three chunks, more than 393216 acknowledged bytes,
`UploadRemoved = true`, `InertFixtureRemoved = true`, and
`CompletionAttempted = false`. Its JSON receipt is emitted only after cleanup.
The receipt includes upload ID, local ZIP/client SHA-256 and UTC timestamps.
This tests transfer and cleanup, not server-side hash rejection or deployment.
The completed run and its actual JSON receipt were retrieved and independently
checked against every acceptance field and the exact local client SHA-256:

| Evidence | Actual result |
| --- | --- |
| Job | `129463489204`, succeeded in 25 seconds |
| Execution host / mode / site | `GH-RUNNER-WIN` / `UploadOnly` / `api-sandbox.surepassid.com` |
| Upload ID | `9f9f1f38936d44f195c3a0b9a146854f` |
| Acknowledged bytes / chunks | `450809` / `3` |
| ZIP SHA-256 | `06BE740218A484449332B82F6142DEF478DC50628470E77F26C0838235C26F7D` |
| Executed client SHA-256 | `24C45260A9BBCE946D4D1C8FAEE9AF09B12CC5D9D64312B22D6C82E7297575F4` |
| Owned remote upload removed | `true` |
| Inert local fixture removed | `true` |
| Completion attempted | `false` |
| Harness started / completed UTC | `2026-11-09T21:50:09.9488719Z` / `2026-11-09T21:50:12.3277065Z` |

No application deployment, completion call, HTTP probe, IIS operation or release
tag occurred. Source contract identities recorded in Step 1a remain the server
module evidence; this upload-only test does not re-inventory or execute completion.
Normal deployment remains fail-closed pending Steps 2/3 and shared-workflow
integration. Corrected local validation passes 81 PowerShell 7 tests and 74
PowerShell 5.1 helper/transport tests; all three scripts passed static parsing and
editor diagnostics, and the scoped action whitespace check passed.

After confirming completion and the owned commit, temporary API branch
`verify/step1c-upload-20261109-1647` was deleted and its absence verified.
The obsolete manual bundle/artifact and scratch workflow were removed. The run
retains the qualification evidence; the API release branch, normal caller and
shared-action pins were not changed. **Step 1c is complete.**

Implement against the verified contract and reuse the candidate's compatible
parts only. Keep the existing action input contract unless a necessary change
is documented and tested. Do not silently drop `keep-list`, assembly, run-ID,
or health requirements just because the server function lacks matching inputs.

- Use ZIP with relative payload paths and no extra containing root; include hidden
  payload files and reject unsafe/reparse-point source trees. Hash the exact
  bytes uploaded, enforce verified size limits before creating a remote upload,
  and pass SHA-256 to server-side verification.
- Validate the returned upload identifier and each cumulative-byte acknowledgement
  without accepting missing, multiple, malformed, or unexpected results.
  Stop on acknowledgement mismatch; no blind append retry or PAT/default-endpoint
  fallback. Pass values as parameters, never interpolate them into remote code.
- Track the upload owned by this invocation and whether completion was attempted.
  Before completion, remove it only when the verified server contract permits.
  After attempted completion with failure or a lost response, retain possible
  recovery data unless the contract proves removal safe. Report the upload ID
  and required operator follow-up without claiming successful deployment.
- Attempt independent stream, session/proxy-module, and owned local ZIP cleanup
  even when another cleanup fails. Surface cleanup failures without hiding the
  original error. Never remove unrelated uploads, site trees, or backups.

The isolated transport suite must cover successful multi-chunk transfer and a
short final chunk; exact package/chunk limits and oversized rejection; ZIP content
and hash identity; denied session/create/append/completion access; invalid IDs;
missing/malformed/wrong acknowledgements; corrupt/incomplete upload rejection;
interrupted calls; and original-error preservation when cleanup also fails.
Assert that incomplete uploads never call completion, every remote operation
uses the restricted endpoint, and completion-ambiguous recovery data is retained.
Mocks establish client behavior, not deployed server guarantees.

Step 1c acceptance gate (satisfied above): after local tests pass, obtain approval
for an upload-only validation from
`GH-RUNNER-WIN`, confirming that the selected job/session executes on that host,
using an inert multi-chunk ZIP for an approved sandbox site. Exercise only
create, append, and contract-safe remove; never call completion, change IIS,
or create a release tag. Record run URL, module evidence, byte acknowledgements,
cleanup outcome, and absence of deployment calls. Server-side hash rejection and
completion failures remain mocked or isolated-site tests under Step 3.

1. **Integrate the restricted endpoint.**
   - [x] Complete Step 1a collection and its source-backed contract record.
   - [x] Inspect and document the deployed `SandboxDeployment` module's exact
     function parameters, upload limits, return values, authorization boundaries,
     and error behavior before changing the client or server contract.
   - [x] Adapt the deployment action locally to open `SurePassID.SandboxDeploy` and use
     only `New-SandboxUpload`, `Add-SandboxUploadChunk`,
     `Complete-SandboxDeployment`, and `Remove-SandboxUpload`.
     Do not bootstrap arbitrary scripts, invoke unrestricted native commands,
     or fall back to the default endpoint.
   - [x] Implement ZIP upload and SHA-256 verification against that contract.
     Fail explicitly on incomplete, corrupt, unauthorized, or interrupted
     uploads; clean up only the upload owned by the current deployment when
     safe. Never discard artifacts needed for recovery.
   - [x] Pass the Step 1b isolated transport acceptance suite; record evidence
     without activating deployment.
   - [x] Pass approved Step 1c upload-only runner validation from `GH-RUNNER-WIN`;
     run `42706187393` verified three chunks, 450809 acknowledged bytes, successful
     cleanup and no completion call.

2. **Agree and enforce configuration/license preservation.**
   - [x] Select secure environment-specific provisioning for the requested
     implementation, not server-side retention. Reconcile the builder's
     preflight by supplying MFA `web.config` before validating the payload.
   - [x] Define required API/MFA configuration/license files, precedence and
     backup consistency. Enforce staged-payload validation before remoting;
     forbid live-file retention, old binaries and cross-environment fallback.

   **Step 2 implementation and provisioning contract (2026-11-09):**

   The canonical builder now prepares configuration **after** the existing
   environment overlay and **before** assembly/tag validation or any WinRM
   action. The user's Step 2 implementation request is implemented using secure
   provisioning; it does not authorize installing real secret values or changing
   the running server. No endpoint/module/role changes are needed for this policy.
   The restricted client's normal deployment mode remains blocked.

   | Application | Required configuration | License policy |
   | --- | --- | --- |
   | MFA | Complete root `web.config` supplied by the selected secret | Nonempty `bin/site.lic`, supplied by that same secret; license references explicitly bound to this site's `bin` and inline code explicitly cleared |
   | API | Published `web.config`, `appsettings.json`, matching `appsettings.mfa-{environment}.json`, `logging.config`; secret-supplied `appsettings.local.json` | Explicit local `AppSettings.MfaServerLicense.ValidationKey`; either supplied root `site.lic` or a nonempty inline `LicenseCode`, never both |

   API local settings must explicitly supply nonempty `ConnectionStrings.MFA`
   and the license section. Local license defaults are normalized to the exact
   selected site's root and `site.lic`; absent/whitespace inline codes become
   empty so a lower-priority build setting cannot override file licensing.
   MFA's `SurePassClassLib.Utility.MfaServerLicense.ReadLicenseFile` and existing
   license-management pages still read the physical license file, so this policy
   deliberately requires file licensing for MFA rather than accepting an
   inline-only configuration that would break that UX. MFA license keys are
   explicitly overridden in the staged XML, including inherited machine values.
   No entire `bin` directory or old application assembly is retained.

   The workflow exposes three optional `workflow_call` secrets:
   `SANDBOX_CONFIGURATION_ALPHA`, `SANDBOX_CONFIGURATION_DEV`,
   `SANDBOX_CONFIGURATION_SANDBOX`. Only the secret matching `SITE_ENV` enters
   the preparation step's environment. For API/MFA that selected secret is
   mandatory at execution; missing values fail closed with no fallback to another
   environment or to a live/production site. Other apps retain their existing
   published-configuration validation and do not require these secrets.

   Each secret is a JSON object with exactly three fields:

   ```json
   {
     "application": "mfa",
     "environment": "sandbox",
     "files": {
       "web.config": "BASE64_OF_COMPLETE_ENVIRONMENT_SPECIFIC_XML",
       "bin/site.lic": "BASE64_OF_ENVIRONMENT_SPECIFIC_LICENSE_BYTES"
     }
   }
   ```

   For API use `"application": "api"` and only `appsettings.local.json` plus
   `site.lic` in `files`; omit `site.lic` only when the local settings deliberately
   contain the inline license. Application/environment must be scalar strings
   matching the target exactly. File names use the exact case and slash spelling
   shown, and values are base64-encoded bytes. API local JSON is UTF-8. These
   placeholders are schema examples, not deployable secret values. Provision
   each bundle securely from that environment's approved configuration and
   license, never by borrowing production files or pasting credentials into chat.
   Bundles must fit GitHub's 48-KB secret limit; oversize inputs require a separately
   reviewed secure-provisioning mechanism, not a plaintext artifact or fallback.

   Preflight rejects duplicate case-insensitive/flattened JSON keys, malformed or
   empty files, arbitrary paths/binaries, reparse-point trees, mismatched API IIS
   environment variables, and off-site/custom license paths. JSON comments and
   trailing commas used by .NET configuration are supported. IIS XML must be
   self-contained: external sections, encrypted machine-bound sections and DTDs
   are not supported by this provisioning policy and fail explicitly. API's
   unselected `appsettings.*.json` files are removed from the owned publish output.
   The selected API JSON files are reserialized as UTF-8 strict JSON without
   comments/trailing commas so the v2 Windows PowerShell 5.1 server can validate
   the same staged settings. Values are preserved; parser/serializer errors fail
   before remoting rather than falling back to an older configuration.
   Parser diagnostics suppress configuration contents; no secret values or
   license contents are logged, summarized or uploaded as workflow artifacts.

   **Precedence and mutable-file consistency:** the selected secret wins over
   published/overlay configuration at its allowlisted paths. The old live site's
   configuration/license never wins and is never read into a new package.
   API/MFA `KEEP_LIST` must be empty in both builder and action. The builder's
   clean-publish step and the client's exclusive, hashed ZIP ensure each upload
   carries newly built code plus the single selected configuration/license
   snapshot. In the verified v1 server contract, supplying MFA root `web.config`
   selects no retention, just like API; backup and rollback therefore include
   the **whole prior release**, including its configuration and any license
   updates made by the application before shutdown. Never restore old code with
   a new license/configuration retained over it. Step 3 must still qualify worker
   drain, actual backup/restore failures, startup/HTTP health and interruption;
   this policy is not proof of those server guarantees.

   An `always()` final step removes the allowlisted secret configuration/license
   files from the runner after success or failure, with owned-path, file-type
   and reparse checks. Unexpected targets and cleanup failures are surfaced,
   not recursively deleted or treated as successful cleanup.

   Local evidence: [SandboxPayload.Tests.ps1](../.github/actions/deploy-iis-site/SandboxPayload.Tests.ps1)
   executes the **actual inline workflow preparation and cleanup code**, not a
   separate implementation. Its 56 inert tests cover all three environments,
   the originally missing MFA root configuration, application/environment
   mismatches, missing secrets/files, file/inline licensing, exact ZIP inclusion,
   precedence, malformed/duplicate/type-confused inputs, forbidden paths and
   cleanup on success/failure. Updated restricted-client regressions pass
   83 PowerShell 7 and 76 PowerShell 5.1 cases. Workflow/action YAML and editor
   diagnostics passed. No real credentials, WinRM, HTTP, IIS or deployment
   operations were used for Step 2 qualification. The SHA-256 recorded in the
   Step 1c receipt identifies that earlier transport revision, before Step 2
   added the API/MFA keep-list rejection; it is not the current modified client
   hash. The current pipeline still requires actual runner qualification under
   Step 4.

   **Activation is still pending:** configure the selected environment's real
   secrets in each caller repository and forward them only alongside a published
   shared workflow revision that declares them. Current API/MFA caller pins and
   secret mappings have not changed. Do not add these secrets to a caller still
   pinned to the older contract, and do not set `upload-only` on a normal release
   workflow as a substitute for deployment/health success.

3. **Qualify server-side deployment safety.**
   - [x] Implement and isolate-test a restricted deployment transaction verifying exact HTTPS 200
     application health before declaring success or discarding rollback state.
     IIS Started state alone is insufficient. Preserve TLS validation, reject
     redirects, bound probe duration, and avoid logging response bodies.
   - [x] Implement and isolate-test restoring the previous release on startup/health failure and verifying
     its health. Surface original, rollback, and cleanup failures distinctly.
     Retain recovery artifacts and block overlapping deployment when recovery
     cannot be verified.
   - [x] Isolate-test path containment, site-scoped locking across callers, actual-volume
     storage requirements, backup/extraction/replacement failures, partial IIS
     stops, preserved files, and cleanup failures against the server contract.
     Use mocks or an explicitly approved isolated site for intentional failures,
     never deliberate corruption of the shared sandbox sites.
   - [x] Document and exercise mocked operator recovery after cancellation, runner loss,
     or WinRM interruption, including safe lock ownership/clearance and health
     verification before another deployment.
   - [ ] Validate actual runner-to-endpoint chunk transfer, archive tooling,
     required IIS/filesystem permissions, server-local TLS/readiness and cleanup
     after approved v2 installation. Step 1c transferred a real three-chunk inert
     ZIP against **v1**; it does not qualify v2 installation or deployment/recovery.
   - [ ] Qualify the installed v2 transaction and interrupted-operation recovery
     on an explicitly approved isolated disposable IIS site before normal canaries.
     Do not deliberately break the shared API/MFA sandbox sites for these tests.

   **Step 3 implementation (2026-11-10):**

   Versioned source is now maintained in
   [server/SandboxDeployment](../server/SandboxDeployment), with manifest version
   `2.0.0` and the original module GUID. The supplied/deployed v1 source remains
   unchanged. The new
   [role capability](../server/SandboxDeployment/RoleCapabilities/SurePassIDSandboxDeployer.psrc)
   imports the **absolute versioned manifest path** as a plain path string,
   removing name-only module-resolution ambiguity without triggering the
   constrained initializer's broken `RequiredVersion` manifest lookup. The
   version is fixed by the exact `2.0.0` path and reviewed manifest bytes, not a
   name-based fallback. It still exposes exactly the
   four original commands, no new cmdlets, external programs or recovery command.
   The existing PSSC restricted session, virtual account and account-to-role
   mapping must not be broadened.

   | Surface | v2 contract |
   | --- | --- |
   | Transport | Original create/add/complete/remove parameter and output shapes retained; creation returns one lowercase GUID-N string, append returns one cumulative Int64 count |
   | Ownership/coordination | Versioned metadata binds uploads to the authenticated remoting caller, not its temporary JEA virtual account; exclusive upload handle then exclusive site handle serializes append/completion/removal and other uploads targeting that site |
   | Supported completion | API/MFA alpha/dev/sandbox only; fixed `/status` or `/server/HealthCheck.aspx` on the exact HTTPS site hostname; Push/OIDC remain upload-only until independently health-qualified |
   | Pre-stop validation | Same approved IIS physical path, dedicated pool with no other site sharing it, no child apps/virtual directories/reparse points; package hash, entry/path/link/collision/size checks; staged assembly/config/license policy; capacity and healthy Started baseline |
   | Package consistency | Package read handle excludes writers throughout hashing, extraction and completion; actual extracted writes cannot exceed validated entry lengths |
   | Capacity | Aggregate conservative staging/site requirements by actual drive root, including ZIP header/DEFLATE overhead and rollback; recheck current live-tree reservation after stop; recovery checks its own space |
   | Quiescence/backup | Stop site and pool, require Stopped states and zero app-pool workers before backup/replacement; backup the full stopped release including mutable configuration/license, hidden files and directories |
   | Health | Baseline, deployed release and recovered release must each return exact HTTPS 200; ten attempts, five-second request timeout, 500-ms inter-attempt delay (at most about 55 seconds per health gate, excluding scheduling) |
   | TLS/HTTP | TLS 1.2 with platform certificate/hostname validation, no callback bypass, proxy, cookies or redirects; headers-only response disposal, no response-body logging |
   | Failure | Health/start/content failure restores the complete prior release with no keep-list, then verifies health; deployment still throws even when rollback succeeds |
   | Persistent blocking | Private, flushed, atomically replaced site journal records intent **before** the first IIS stop and replacement intent before content changes; interrupted/unverified transactions block create/append/complete/remove even after all handles are released |
   | Success | Receipt extends the old fields with `HealthVerified`, `HealthStatus`, `HealthUrl`, `ModuleVersion`, `UploadId`; only returned after health and journal cleanup succeed |
   | Cleanup/retention | Journal-cleanup failure is not success; uploads/backups needed for ambiguous or failed completion are retained; v2 deliberately does not auto-prune backups |

   The staging root must already have a protected SYSTEM/Administrators-only ACL;
   v2 checks this and refuses inherited or broader allow rules rather than
   repairing permissions remotely. New backup and journal files are created with
   private SYSTEM/Administrators ACLs from the outset. Their names/content do not
   contain configuration secrets. Packages, expanded content, backups and any
   Windows remoting/audit transcripts must nevertheless be treated as sensitive.
   Verify audit-log access as an operational gate; do not disable auditing to hide
   configuration transport. No ACL, endpoint, listener, trust or account setting
   was changed on the VM by this implementation.

   ZIP recovery covers in-site file content and directory layout, not NTFS
   per-file ACLs, alternate data streams, databases or external mutable stores.
   The existing site root stays in place and copied children inherit destination
   permissions. The installation inventory must identify any custom per-file ACL
   or external-data dependency and qualify its recovery separately before use.

   **Qualification evidence and remaining limits:**

   [SandboxDeployment.Tests.ps1](../server/SandboxDeployment.Tests.ps1) executes the
   actual module with real local ZIPs, files, hashes, extraction, backup,
   replacement, journals and exclusive handles. **55 tests pass on Windows
   PowerShell 5.1 and PowerShell 7.** They include API and MFA transactions; healthy
   baseline/new release; replacement/start/backup/partial-stop/drain failures;
   rollback and failed rollback; stale/tampered recovery metadata/backup;
   interrupted Prepared/Replacing/Committed journal cases; cleanup failure;
   missing staged files; no live-file fallback; owner/expiry/offset checks;
   concurrent upload/site locks; traversal, duplicate/link/file-directory archive
   rejection; bounded actual extraction; exact 4-GiB/8-GiB/100000-entry thresholds;
   pre-stop/rechecked storage and same-volume aggregation; health redirects,
   non-200s, timeout/TLS exceptions and bounded retries. The request safety settings
   are also asserted directly.

   These tests **mock IIS, network and privileged ACL creation**, not their
   production correctness. The worker-drain timeout path is exercised, but real
   WAS workers, certificates, DNS/hairpin routing, platform TLS validation and the
   virtual account's real permissions require the installed-server gate below.
   The coupled builder JSON-normalization change passes all 56 payload-policy
   tests; unchanged client regressions pass 83 PS7 and 76 PS5.1 cases. The client
   still refuses normal completion and does not treat the new receipt as activated
   deployment. Step 4 must reconcile its exact health URL/receipt checks before
   enabling it; no caller or prerequisite pins were changed.

   **Installation walkthrough status (operator-reported; v2 installed, live qualification pending):**

   The operator confirmed local elevated Windows PowerShell 5.1 on sandbox-app,
   an eight-file verified v1 backup plus the registered endpoint configuration,
   and four verified v2 source files extracted outside `PSModulePath`. The source
   ZIP SHA-256 is
   `47B0669C18C32AF041147F49CEF64B303AFDA057D6E2317202FCEDE45F525D56`.
   The operator backed up the staging-root ACL and removed its extra individual
   allow rule; it now has protected SYSTEM/Administrators-only FullControl.
   The final local inventory reported zero WinRM shells, upload directories and
   recovery journals. These are point-in-time preflight results, not installation
   or live qualification evidence.

   The first switch attempt encountered a Windows sharing violation. Follow-up
   inventory confirmed v1 version 1.0.0, all eight original files matching their
   backup, and the unchanged endpoint configuration. After the operator released
   module-directory handles, the guarded retry reported version 2.0.0 installed
   at the exact versioned manifest path below, with
   `EndpointConfigurationUnchanged = True` and `LiveQualificationPending = True`.
   The successful switch identifier is `f06aa5d2163e43d8b5c3cb447465abbb`:
   v1 remains in `RetiredModule-v1-<identifier>` and the reviewed recovery script
   in `Repair-SandboxDeployment-v2-<identifier>.ps1`, both under the private
   backup root. Retain the earlier candidate and all original backups.
   The installed source hashes, private module ACL, manifest and local import
   passed the installer's post-move validation. Fresh JEA capability resolution,
   a new GH-RUNNER-WIN upload/removal receipt, and live transaction/recovery
   qualification are still pending. No normal client deployment was enabled.

   The subsequent local inventory confirmed only version 2.0.0 available.
   `Get-PSSessionCapability` failed resolving the local account as
   `github-deploy@SANDBOX-APP`, before returning capabilities. Direct local SAM/SID
   lookup then confirmed the deployment account is enabled and maps to
   `SurePassIDSandboxDeployer` in the registered PSSC. This verifies account and
   configuration identity, not effective commands in a live restricted session;
   no endpoint or account changes were made to bypass the inspection failure.

   For the next runner-host check, a source-only `sandbox-v2-upload-check.zip`
   was prepared with the existing client and operator harness plus a hash
   manifest. ZIP SHA-256:
   `51253BE65D2A6103150F3C0393C8FAD6983D45BEF04296F615CA93EF8163CB36`.
   Client SHA-256:
   `156505D9B8A5B08F347A7C146D3C58659A9AE5C4C925CF3BD8430CF93A087579`;
   harness SHA-256:
   `3E3467CFBDC9F4EF45A7F8875B201A673DF2011C3E9B0B36BF40640687AC3503`.
   The archive entries match maintained source and manifest; all 83 isolated PS7
   client/harness tests pass. No credentials or application payloads are bundled.
   Preparation does not open WinRM; only run the harness on GH-RUNNER-WIN in
   PowerShell 7. Record whether execution is interactive or under the Actions
   service: an interactive host check does not qualify the Actions service
   context. Keep the fresh Actions upload-only receipt and real transaction
   qualification as activation gates.

   The first interactive v2 upload check on GH-RUNNER-WIN failed during fresh
   session initialization: JEA could not find `SurePassIDSandboxDeployer`.
   No upload command was reached. The original installer incorrectly placed
   the role under `SandboxDeployment\2.0.0\RoleCapabilities`; native Windows
   PowerShell 5.1 lookup does not resolve that location. The required location
   is `SandboxDeployment\RoleCapabilities`, alongside the version directory.
   The manifest/module remain inside `SandboxDeployment\2.0.0`, and the same
   role bytes at that stage still used `RequiredVersion = '2.0.0'` for that exact
   manifest; the subsequent constrained-initialization correction is below.
   This is an installer layout defect, not an account/password or role-content
   change. Local module import alone did not test JEA discovery.

   The corrected installer now constructs that split layout and validates
   native role discovery before accepting the switch. For the already-installed
   v2 instance, use its explicit `-RepairRoleLayout` mode with the existing
   verified stage/backup/package paths: first `-WhatIf`, then an approved actual
   run. It requires the old versioned role as the sole active copy, verifies all
   installed v2 bytes against the original pinned package, checks unchanged
   endpoint/private ACLs/idleness, and moves only the verified role file.
   Post-move validation uses the real JEA configuration loader with a fixed
   role-selection predicate; it avoids the separate username-inspector failure
   but does not replace authentication/session qualification. Failed validation
   moves the file back, while a failed rollback is explicit. No service restart,
   endpoint registration, code/config replacement or permission expansion is
   required. The source ZIP and runner bundle remain unchanged. The operator
   subsequently completed the targeted repair locally on sandbox-app:
   `InstalledVersion = 2.0.0`, the role at the module-root `RoleCapabilities`
   path, `NativeRoleDiscoveryPassed = True`,
   `EndpointConfigurationUnchanged = True`, and `LiveQualificationPending = True`.
   The installed bytes and endpoint passed repair validation; fresh runner
   upload/removal, Actions-context and live transaction/recovery qualification
   remain pending. Retry only the existing inert upload harness from
   GH-RUNNER-WIN; normal deployment remains blocked.

   The next fresh runner session progressed beyond role discovery, but failed
   during constrained initialization because `Test-ModuleManifest` was not
   available. Native local runspace tests reproduced this: the module
   specification's `RequiredVersion` lookup invokes that hidden cmdlet before
   importing the module. The maintained role now imports the same absolute
   versioned manifest as a plain string, without exposing `Test-ModuleManifest`
   or any other administrative command. A real constrained runspace now opens
   with the actual module, all four functions and unchanged `NoLanguage`;
   manifest-only and initial-session-state-only checks did not cover this.

   For the current server snapshot, the installer's dot-sourced operator helper
   `Update-SandboxRoleImport -SourcePath <reviewed-role.psrc> -BackupRoot <verified-backup>`
   performs a separate hash-bound role-only correction. It accepts only the
   original v2 core hashes and old role fingerprint
   `CEF1AB6E32DD0DAEB5343E005158768569AFBB7D8285A5460BDC63525840D0C9`,
   and the reviewed replacement role fingerprint
   `D291405AEC00B4E80496D7D5A41C2972EB99CE7E43AB11758872F82834FE69F2`.
   It requires local elevated Windows PowerShell 5.1 on sandbox-app, unchanged
   endpoint configuration, one root-level role, private ACLs and idleness.
   First use `-WhatIf`, then an approved actual run. The old role is backed up
   privately during atomic replacement; failed native constrained initialization
   restores it, with explicit failure if rollback itself fails. No module code,
   PSSC, permissions, service state or runner bundle is changed. The operator
   then applied this correction locally on sandbox-app: `InstalledVersion = 2.0.0`,
   `NativeConstrainedInitializationPassed = True`,
   `EndpointConfigurationUnchanged = True`, `LiveQualificationPending = True`.
   The previous role was saved privately as
   `RoleBeforeImportFix-v2-6e3a0457231c4cf987d65d257cc3f0c8.psrc` under the
   backup root.

   **Interactive v2 upload/removal receipt (2026-11-10, passed):** run locally
   on GH-RUNNER-WIN in a non-elevated PowerShell 7 session using the verified
   runner bundle (`sandbox-v2-upload-check.zip`). This was an interactive
   operator session, not the GitHub Actions service context.

   | Field | Value |
   | --- | --- |
   | Execution host / mode / site | `GH-RUNNER-WIN` / `UploadOnly` / `api-sandbox.surepassid.com` |
   | Upload ID | `c8e7f5823a544c46bfc02de964c57b06` |
   | Acknowledged bytes / chunks | 450809 / 3 |
   | Local ZIP SHA-256 | `6394FFB0D9995746A4740AA2EA503F5B08969E14271C0C3073741016221BAA41` |
   | Client SHA-256 | `156505D9B8A5B08F347A7C146D3C58659A9AE5C4C925CF3BD8430CF93A087579` |
   | Upload removed / completion attempted / fixture removed | True / False / True |
   | Window (UTC) | 2026-11-10T18:30:29.0504708Z – 18:30:31.1486323Z |

   This qualifies v2 JEA discovery, constrained initialization, authenticated
   owner binding, Int64 chunk acknowledgements and owner removal through a real
   restricted session. The two earlier failed attempts stopped during session
   initialization, before any upload was created.

   **GitHub Actions service-context v2 upload/removal receipt (2026-11-23, passed):**
   [Run 45228073398](https://github.com/SurePassId/SurePassIdApiServer/actions/runs/45228073398)
   (job `137879867179`, succeeded in 21 seconds) executed from isolated temporary
   branch `verify/step3-v2-upload-20261123-1228` (`a95dad28e3276370b7dcb8080148154801869089`)
   using sparse checkout of the verified client/harness copies and the existing
   `SANDBOX_VM_*` secrets, under the real GitHub Actions service account on
   `GH-RUNNER-WIN`. The temporary branch was deleted remotely and locally after
   verifying the receipt; `SurePassIdApiServer` `release/2026.4` and all caller
   pins were unchanged.

   | Field | Value |
   | --- | --- |
   | Runner / group / machine | `windows-build-vm (gh-runner-windows)` / `default` / `GH-RUNNER-WIN` |
   | Runner Windows identity | `NT AUTHORITY\NETWORK SERVICE` |
   | Execution host / mode / site | `GH-RUNNER-WIN` / `UploadOnly` / `api-sandbox.surepassid.com` |
   | Upload ID | `e1d8ec86e0c0448c91e22bfda7315146` |
   | Acknowledged bytes / chunks | 450809 / 3 |
   | Local ZIP SHA-256 | `0C68B79A590F747F0A9117BF3CC7E8A708BB48D043DC2C2A98A59C66F1E0676D` |
   | Client SHA-256 | `156505D9B8A5B08F347A7C146D3C58659A9AE5C4C925CF3BD8430CF93A087579` |
   | Harness SHA-256 | `3E3467CFBDC9F4EF45A7F8875B201A673DF2011C3E9B0B36BF40640687AC3503` |
   | Upload removed / completion attempted / fixture removed | True / False / True |
   | Window (UTC) | 2026-11-23T17:28:52.9450857Z – 17:28:55.5562840Z |

   Both interactive and GitHub Actions service-context upload-only checks have
   now passed against the installed v2.0.0 endpoint. Still pending: real
   completion/fault/recovery qualification on an approved disposable IIS site
   (or an explicitly approved qualification decision). Normal deployment remains
   blocked.

   [Install-SandboxDeployment.ps1](../server/Install-SandboxDeployment.ps1)
   provides the guarded transition for reviewed source bundles and a verified
   eight-file v1 installation. The original frozen source ZIP remains historical
   evidence and contains the superseded role import; do not reuse it for a fresh
   install. A new source bundle must contain the corrected role and have its
   reviewed hash explicitly supplied with `-ExpectedPackageSha256`. Do not
   silently replace the original ZIP or its recorded hash.
   Run the installer locally as administrator in Windows
   PowerShell 5.1 with the previously verified `-StagePath` and `-BackupRoot`;
   `-PackagePath` defaults to
   `C:\Windows\Temp\sandbox-deployment-v2-stage.zip`. First use `-WhatIf`, then
   run without it and approve the installation confirmation while deployment
   jobs remain quiesced. It rechecks source hashes against the manifest inside
   the pinned ZIP, v1/endpoint backups, role uniqueness, private ACLs and idleness.
   It prepares protected files outside `PSModulePath`, retires the entire v1
   root into the private backup directory, and moves v2 into place without
   overlapping role copies. Post-move validation checks hashes, private ACL,
   manifest, local import/exports and full native constrained-runspace
   initialization; a failed move or validation restores v1,
   retaining candidate files and reporting rollback failures explicitly.
   A hash-verified operator recovery script is copied into the private backup
   directory separately; no endpoint re-registration, service restart, IIS action
   or remote connection is performed. The installer cannot prevent newly queued
   deployment jobs; keep them paused throughout.

   [Install-SandboxDeployment.Tests.ps1](../server/Install-SandboxDeployment.Tests.ps1)
   exercises real directory moves for success, failed post-move validation,
   missing candidate, retirement-path collision and an explicitly reported
   rollback failure that retains both versions. Six additional atomic role
   replacement cases cover success, failed validation/restoration, real sharing
   violation, backup collision, explicit rollback failure and hash mismatch.
   All eleven tests pass under
   Windows PowerShell 5.1 and PowerShell 7. These local filesystem tests do not
   qualify the live server's privileged ACLs, module import or JEA.

   [SandboxRoleDiscovery.Tests.ps1](../server/SandboxRoleDiscovery.Tests.ps1)
   adds nine passing tests on both Windows PowerShell 5.1 and PowerShell 7:
   actual native rejection of the versioned-only role and resolution of the
   root-level role; corrected installer candidate contents/hashes/native lookup;
   successful hash-preserving role repair; refusal of duplicate destinations
   and wrong hashes; rollback on failed validation; real file sharing violation;
   and explicit rollback failure with original bytes retained. These tests
   use initial session state and local constrained runspaces, without WinRM,
   endpoint registration or application deployment.

   [SandboxJeaInitialization.Tests.ps1](../server/SandboxJeaInitialization.Tests.ps1)
   adds two native initialization tests on both Windows PowerShell 5.1 and
   PowerShell 7: it reproduces the `RequiredVersion`/`Test-ModuleManifest`
   failure, then opens a real local constrained runspace using the actual
   maintained role and module (only the absolute path is redirected into an
   isolated fixture). It verifies all four deployment functions, `NoLanguage`,
   and that `Test-ModuleManifest`, `Import-Module`, `Invoke-Expression` and
   `Get-Content` remain hidden. Together with the 55 server-safety regressions,
   all 77 tests pass per runtime. No WinRM, upload or IIS operation is performed.

   **Approved installation/qualification procedure (remaining live gates):**

   1. Arrange an operator-approved maintenance/isolated-test window on
      **sandbox-app**, with deployment jobs quiesced. This development PC does not
      connect by WinRM. Only **GH-RUNNER-WIN** runs the restricted remote client.
   2. Locally inventory the registered PSSC, original module/role hashes, active
      sessions, module versions and every occurrence of the role capability name.
      Securely archive v1 outside `PSModulePath` and ensure only one active
      `SurePassIDSandboxDeployer.psrc` resolves. Do not overwrite or lose the
      operator-supplied originals or reuse an open v1 session.
   3. After approval, install the reviewed manifest/module at
      `C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\2.0.0`,
      and the sole role at
      `C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\RoleCapabilities\SurePassIDSandboxDeployer.psrc`,
      preserving administrator-only module write access. Compare deployed SHA-256
      hashes with the reviewed source and use local Windows PowerShell 5.1
      `Test-ModuleManifest`/`Import-Module` on the exact versioned path. Keep the
      existing PSSC role mapping and restricted language; no default-endpoint
      access, new visible commands or additional runner privileges are required.
   4. Review staging-root inheritance/access locally; provision only the private
      ACL above under operator approval. Inventory/quarantine legacy v1 staging
      and unexplained journals before use: v1 metadata has no authenticated owner
      and cannot safely be adopted or removed by the v2 runner. Do not clear any
      active transaction or recovery artifacts merely to make validation pass.
      Check sensitive content/audit ACLs, available space on both volumes,
      site/pool isolation and real server-local DNS/TLS/readiness for each site.
   5. Open a fresh restricted session from GH-RUNNER-WIN and repeat the existing
      inert three-chunk upload/removal harness. Record run URL, installed
      module/role identities, runner identity and receipt. This must not call
      completion, deploy an application, alter IIS or create a release tag.
      **Complete: interactive check passed 2026-11-10 and GitHub Actions
      service-context check passed 2026-11-23 (`45228073398`, `NT AUTHORITY\NETWORK SERVICE`;
      receipts above).**
   6. Separately approve an isolated disposable site and **server-owned** map
      entry/test health route with equivalent IIS/filesystem permissions for
      completion/fault-injection qualification. Do not add a caller-controlled
      path/health URL or weaken the production map. Exercise baseline, new-release
      and restored health; worker shutdown, capacity, extraction/backup/copy/start
      faults; journal/removal failures; process/session loss and reconnect.
      Record actual HTTP, recovery and ACL evidence. Do not enable the normal
      shared action or proceed to canaries until these gates pass.
   7. Define operator-approved retention after healthy/recovered releases are
      verified. V2 keeps backups rather than pruning potentially needed recovery
      data. Retained lock files are normal handle anchors, not recovery blockers;
      never delete/replace them to bypass an active handle. Capacity checks must
      continue to fail closed if retained data consumes the available reserve.

   **Operator recovery procedure (local elevated PS5.1 only):**

   The reviewed
   [Repair-SandboxDeployment.ps1](../server/Repair-SandboxDeployment.ps1) is
   deliberately **not** exported or visible through JEA. Stage a reviewed copy
   separately for a local administrator on sandbox-app. It validates host,
   elevation, site, upload ID and the expected journal SHA-256, imports the exact
   v2 path, and acquires upload/site handles before acting. A stale hash, active
   owner, invalid journal or backup mismatch refuses recovery and keeps the block.

   - Quiesce queued deployments and establish the interrupted run/upload/site.
     Inspect the private journal and backup without opening or publishing
     configuration/license content. Never blindly retry completion, delete the
     journal/lock, or remove retained upload data after a lost response.
   - Example **inspection/dry run**, directly on sandbox-app:

     ```powershell
     & {
         $ErrorActionPreference = 'Stop'
         if ($env:COMPUTERNAME -ine 'sandbox-app') {
             throw 'Run locally on sandbox-app in an elevated Windows PowerShell 5.1 window.'
         }
         $siteName = 'mfa-sandbox.surepassid.com'
         $journalPath = Join-Path $env:ProgramData "SurePassID-SandboxDeploy\$siteName.recovery.json"
         $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
         $journal | Select-Object Version, SiteName, UploadId, Phase, BackupName, BackupSha256, CreatedUtc
         $journalHash = (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash
         & 'C:\Ops\SurePassID\Repair-SandboxDeployment.ps1' `
             -SiteName $siteName -UploadId $journal.UploadId `
             -ExpectedJournalSha256 $journalHash -WhatIf
     }
     ```

   - After reviewing the exact site/upload/backup and receiving recovery approval,
     invoke that same command with the reviewed hash, without `-WhatIf`, and
     confirm its prompt. `Prepared` means content was not replaced: restart and
     health-check the prior release. `Replacing` or `Committed` conservatively
     restores the hash-verified full backup, restarts IIS and verifies health.
     Even a previously healthy new release is rolled back when an unresolved
     committed transaction is explicitly recovered. No arbitrary filesystem
     paths or health URLs are accepted.
   - If recovery/health/cleanup fails, keep the journal, upload and backup and
     repair the actual cause locally; new deployments remain blocked. If the
     original response was lost but no journal exists, inspect the actual release,
     health and audit evidence first rather than inventing a journal or declaring
     success. A stale/legacy/unknown state needs operator investigation.
   - After verified recovery, record the result and independently verify release
     identity and application readiness. Remove only the known owned upload
     through the approved runner (or an explicitly approved local investigation);
     keep the backup under the retention policy. Only then allow a new deployment.

4. **Complete workflow integration and regression validation.**
   - [x] Confirm the existing windows-build-vm route selects GH-RUNNER-WIN
     (gh-runner-windows), the user-corrected approved WinRM client. Keep its
     machine-name guard intact; no PRODUCT-SUP-01 routing change is required.
   - [x] Wire the compatible action into the canonical builder, preserving the
     existing build/runtime/overlay behavior and completed Phase 1/2 contracts.
     Re-run relevant local tests, YAML/metadata checks, and caller-contract checks
     after integration changes.
     **Updated 2026-11-23:** `deploy-iis-site` now validates the full v2.0.0
     health-verified receipt, enforces API/MFA completion scope and exact health
     URLs before WinRM, uses a 600-second completion `OperationTimeout`, and
     removes owned uploads only after verified success (99 PS7 / 90 PS5.1
     transport tests and 56 payload-policy tests passing). Pinned in
     `build-deploy-sandboxvm.yaml` to prerequisite commit
     `bcc236e8e6f970353716873a063bec801eaa1ded`. API/MFA callers remain on
     `710df18` until secrets are provisioned and canaries are approved.
   - [ ] Rebuild API and MFA on the actual runner and validate the final effective
     configuration/license policy and clean publish output before deployment.
     Provision the three environment-specific configuration secrets as needed,
     forward them explicitly in API/MFA callers when upgrading the shared pin,
     and verify the selected environment's actual configuration/license without
     exposing contents. Local policy fixtures do not satisfy this live gate.
   - [ ] Preserve the locally implemented tag-collision preflight and awaited,
     idempotent release tagging after deployment and health success. Verify
     same-SHA reruns, conflicting SHAs, denied permissions, and no new release
     tag on deployment failure. Preserve `TAG_REPOSITORY=false` for `oidc-client`;
     report tagging failure distinctly when the application is already live.

5. **Publish and activate with controlled canaries.**
   - [x] Publish any revised compatible action prerequisite first, then pin its
     full SHA in the shared workflow and publish that workflow. The previously
     published action is not restricted-endpoint compatible. Do not use a
     same-commit self-pin, mutable feature branch, or caller-local action path.
     **Published 2026-11-23 on `feat/sandboxvm-hardening-phase3`:** action
     prerequisite `bcc236e8e6f970353716873a063bec801eaa1ded`, then pinned in
     `build-deploy-sandboxvm.yaml` in a separate follow-up commit.
   - [ ] Update API/MFA caller pins and any required contract mappings atomically
     per repository. Keep rollback pins/contracts recorded.
   - [ ] Run normal API and MFA sandbox deployment canaries against fresh healthy
     baselines. Verify the deployed commit, application health, approved
     configuration/license preservation, cleanup, and release-tag behavior.
     Obtain approval before pushing a deployment tag. Do not mark Phase 3
     complete based only on build-only or empty-upload validation.
   - [ ] Verify live API alpha Postman execution when the environment is healthy.
     Track the pre-existing API alpha/dev failures separately; do not weaken
     health checks to pass them. Verify explicit dev/sandbox skips and leave
     MFA Postman disabled until it is actually configured.

6. **Close shared-consumer and operational gates.**
   - [ ] Inventory PushServer/IdentityProvider caller pins, recursive dependencies,
     App access, deployment targets, and readiness paths. Require an explicit
     `HEALTH_CHECK_PATH` before adoption; leave their existing pins unchanged
     until separately qualified. API/MFA completion alone is not shared-contract
     migration completion.
   - [ ] Verify runner/group access, trusted workflow/code execution, deployment
     tag/manual-dispatch controls, and runner account permissions. Record an
     App-key owner and agreed review/replacement procedure without reading or
     recording private-key material.
   - [ ] Inventory all remaining `GH_ACTIONS_PAT` consumers before approving
     credential retirement. Do not revoke a credential still needed elsewhere.
   - [ ] Record canary/recovery evidence and final pins here, refresh status and
     checkboxes, and persist the updated plan with the implementation.
     Production remains outside this rollout and requires its separate read-only
     account/endpoint inventory and approval.

## Validation and rollout gates

- Parse YAML and check editor diagnostics for every modified reusable workflow,
  composite action, and caller. Validate caller inputs/secrets and all action
  metadata at the exact pinned revisions.
- Execute environment parsing for alpha/dev/sandbox tags with timestamp,
  version, custom text, empty suffix, and slash-containing valid suffixes.
  Reject unknown environments, missing hyphens, branch refs without an input,
  and tag/input mismatches. Test manual dispatch and concurrency keys.
- In a checkout-only job, verify root and recursive submodule SHAs for both
  API and MFA. Test denied repository access and an invalid credential using
  controlled test configuration: fail explicitly, never fall back to a PAT.
  Verify credentials are not persisted or printed and revocation is enabled.
- Build API and MFA on the actual runner, inspect assembly/configuration
  output, and compare artifacts with the current workflow. Inject a stale
  publish file and confirm it is absent on the next build.
- Exercise intentional failures using mocks or an approved isolated disposable
  IIS site. Cover archive/extraction/backup failures, low space,
  partial stops, each rename failure, keep-list preservation, startup/probe
  failure, cleanup errors, and operator recovery after cancellation. Use the
  user-approved healthy sandbox sites for normal deployment/health canaries.
- Test release-tag creation, same-SHA reruns, different-SHA collisions, denied
  tag permissions, and no release tag after failed deployment.
- Verify API Postman alpha execution and explicit dev/sandbox skips.
- Publish prerequisites/shared workflows first; update API and MFA caller
  pins and secrets atomically per repository; canary the healthy sandbox sites.
  Obtain deployment approval before pushing a deployment tag.
- Roll back caller pins/contracts together if needed. Restoring an older
  workflow pin does not roll back a deployed app; use the tested IIS recovery
  procedure. Retain old credentials only for an explicitly bounded migration
  window, then retire them after consumer inventory is complete.

Overall hardening completion requires successful deployment caller runs, not
merely valid YAML. App checkout, token revocation, and Postman skip paths have
been verified on the self-hosted runner. Phases 1 and 2 implementation is complete;
full deployment canaries, live alpha Postman tests, and Phase 3 IIS recovery
hardening remain pending.
