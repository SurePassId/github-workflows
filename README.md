# GitHub Workflows Repository

Centralized reusable GitHub Actions workflows for the SurePassID organization, handling building, testing, and deploying .NET applications across multiple environments and hosting platforms.

## Overview

This repository contains workflow templates that are called from other SurePassID repositories to standardize CI/CD processes. All workflows are designed as `workflow_call` reusable workflows and support multiple .NET versions and deployment targets.

## Workflows

### Build Workflows

| Workflow                 | Purpose                   | .NET Version  | Runner         |
| ------------------------ | ------------------------- | ------------- | -------------- |
| `build-dot-net-fwk.yaml` | .NET Framework 4.8 builds | Framework 4.8 | windows-2019   |
| `build-dot-net6.yaml`    | .NET 6 applications       | 6.0.x         | windows-latest |
| `build-dot-net8.yaml`    | .NET 8 applications       | 8.0.x         | windows-latest |

### Deployment Workflows

| Workflow                      | Purpose                      | Target                 |
| ----------------------------- | ---------------------------- | ---------------------- |
| `deploy-to-app-service.yaml`  | Azure App Service deployment | Azure Cloud            |
| `build-deploy-sandboxvm.yaml` | Complete build and deploy    | Self-hosted Windows VM |

### Testing Workflows

| Workflow                 | Purpose                | Tool        |
| ------------------------ | ---------------------- | ----------- |
| `run-postman-tests.yaml` | API testing automation | Postman CLI |

## Supported Repositories

The workflows automatically detect the calling repository and configure build parameters accordingly:

- **SurePassId/SurePassIdLegacyMfaServer** - Legacy .NET Framework MFA Server
- **SurePassId/SurePassIdMfaServer** - .NET 8 MFA API Server
- **SurePassId/SurePassIdPushServer** - .NET Framework Push Server
- **SurePassId/IdentityProvider** - .NET 8 OIDC Server (multi-app support)

## Environment Strategy

### Branch-Based Environments

Environments are determined by branch names with strict validation:

- `alpha` - Alpha testing environment
- `dev` - Development environment
- `sandbox` - Sandbox testing environment

### Environment-Specific Configuration

Post-build, the `SurePassId/copy-web-env-files@main` action overlays environment-specific configuration files, enabling single builds with runtime-specific configs.

## Usage Examples

### Basic Build and Deploy

```yaml
name: Deploy to Sandbox
on:
  push:
    branches: [sandbox]

jobs:
  build:
    uses: SurePassId/github-workflows/.github/workflows/build-dot-net8.yaml@main
    with:
      APP: "api"
      SLOT: "sandbox"
      DEPLOY_ENV: "sandbox"
      BUILD_CONFIG: "Release"
      BUILD_PROJECT: "./SurePassIdMfaServer/SurePassIdMfaServer.csproj"
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}

  deploy:
    needs: build
    uses: SurePassId/github-workflows/.github/workflows/deploy-to-app-service.yaml@main
    with:
      APP: "api"
      SLOT: "sandbox"
      DEPLOY_ENV: "sandbox"
      REGION: "eastus"
    secrets:
      PUBLISH_PROFILE: ${{ secrets.PUBLISH_PROFILE }}
```

### Sandbox Sites Deployment

```yaml
name: Deploy to Sandbox Sites
on:
  push:
    branches: [sandbox]

jobs:
  build-and-deploy:
    uses: SurePassId/github-workflows/.github/workflows/build-deploy-sandboxvm.yaml@main
    with:
      DEPLOY_APP_NAME: "oidc"
      RUNNER_LABEL: "windows-build-vm-validation"
    secrets:
      GH_ACTIONS_PAT: ${{ secrets.GH_ACTIONS_PAT }}
      SANDBOX_VM_USERNAME: ${{ secrets.SANDBOX_VM_USERNAME }}
      SANDBOX_VM_PASSWORD: ${{ secrets.SANDBOX_VM_PASSWORD }}
      SANDBOX_VM_HOSTNAME: ${{ secrets.SANDBOX_VM_HOSTNAME }}
```

## Required Secrets

Configure these organization/repository secrets for workflows to function:

### Universal Secrets

- `GH_ACTIONS_PAT` - GitHub Actions token for private repo access
- `SSH_KEY` - SSH key for submodule checkout

### Azure App Service

- `PUBLISH_PROFILE` - Azure App Service publish profile

### Sandbox Sites Credentials

- `SANDBOX_VM_USERNAME` - `SANDBOX-APP\github-deploy`
- `SANDBOX_VM_PASSWORD` - This account's unique password from the approved vault
- `SANDBOX_VM_HOSTNAME` - `SANDBOX-APP`, resolving to `10.10.30.10` on the runner

The existing secret names and workflow filename are retained for caller compatibility. Replace their old VM values before running this workflow; never put secret values in YAML. Use only trusted calling workflows and repositories. The workflow defaults to the validation runner label; select `windows-build-vm` through `RUNNER_LABEL` only after cutover approval.

### API Testing

- `POSTMAN_API_KEY` - Postman API key for test automation

## Infrastructure Requirements

### Self-Hosted Runners

- **Sandbox validation tags**: `[self-hosted, Windows, windows-build-vm-validation]`
- **Pre-installed**: PowerShell Core and MSBuild/.NET Framework targeting packs for Framework builds; .NET 8 SDK setup is performed by the workflow for Core builds
- **Network access**: Approved GitHub/NuGet HTTPS egress and WinRM TCP `5985` to `SANDBOX-APP`; no SMB, Web Deploy, RDP, or database access is required
- **WinRM client**: Exact hostname resolution and TrustedHosts entry for `SANDBOX-APP`; Negotiate supplies encrypted messages over the existing HTTP listener

### Sandbox Deployment Endpoint

Install the matching `scripts/SandboxDeployment.psm1` and `scripts/Install-SandboxDeploymentEndpoint.ps1` from the Azure VM Migration repository on `SANDBOX-APP`. Run the installer once in elevated, 64-bit Windows PowerShell 5.1. It validates all 12 approved live site/pool/path mappings, refuses existing installation directories or an existing endpoint, and does not restart WinRM automatically. Activate the registered endpoint with a separately acknowledged WinRM restart; existing remoting sessions disconnect, but RDP and IIS are not restarted.

- **Endpoint**: `SurePassID.SandboxDeploy`, a JEA `RestrictedRemoteServer` endpoint mapped only to `SANDBOX-APP\github-deploy`, with a virtual administrator account for its trusted internal operations
- **Commands**: `New-SandboxUpload`, `Add-SandboxUploadChunk`, `Complete-SandboxDeployment`, `Remove-SandboxUpload`; no unrestricted remote script blocks or generic filesystem/IIS commands are exposed
- **Site scope**: MFA/API/Push in `alpha`, `dev`, and `sandbox`; OIDC in `alpha` and `sandbox`; OIDC client in `alpha` only. Other combinations fail closed
- **Paths**: Live IIS paths must match the server allowlist, including `E:\iis_sites\sandbox\oidc\oidc-sandbox.surepassid.com`. Client-supplied destination paths and preservation lists are not accepted
- **Transfer**: Built-in .NET ZIP, 192 KiB chunks, SHA-256 verification, maximum 4 GiB compressed/8 GiB expanded and 100,000 entries. Unsafe paths, symlinks, duplicate names and empty packages are rejected before stopping IIS; 7-Zip is not required
- **Deployment**: Stop site then pool, back up, replace content, start pool then site; native exit codes and IIS states are checked. Failures attempt content rollback and restoration of previous IIS states. Successful deployment starts the selected site, including previously stopped sites
- **Preservation**: OIDC `keys`, `logs`, and `spidp_log.txt` are neither deleted nor overwritten. Other content is replaced; child IIS applications or reparse points require separate review
- **Backups**: Three successful-deployment ZIP backups per site under `C:\ProgramData\SurePassID-SandboxDeploy\Backups`; failed-deployment backups are retained until later successful retention pruning. Existing `.7z` backups are untouched. Backups contain all site data, including sensitive preserved data, and inherit admin/SYSTEM-only access
- **Cleanup**: Workflow `finally` cleanup removes its package, upload, proxy module and session. Interrupted/disconnected uploads may need operator cleanup; upload IDs expire after 24 hours

Do not add `github-deploy` to Administrators or Remote Management Users, grant blanket folder access, or change remote UAC filtering. Endpoint restriction does not sandbox deployed application code: trusted releases can execute with the IIS application-pool identity. No live deployment or endpoint installation is implied by local tests. Health checks and actual job-context WinRM/IIS verification remain acceptance steps.

## Development

### Adding New Repository Support

1. Add repository case in workflow switch statements
2. Define build type (`framework` vs `core`), solution/project paths
3. Configure environment variables and assembly names
4. Update Postman test configurations if applicable

### Adding New .NET Version

1. Copy existing `build-dot-net{X}.yaml` workflow
2. Update `dotnet-version` in setup step
3. Add version logic to repository switch statements

## Troubleshooting

### Common Issues

- **Artifact Mismatch**: Ensure artifact names match between build and deploy jobs using `app-{APP}-{SLOT}` convention
- **Environment Files**: Verify `copy-web-env-files` action succeeded for environment-specific configs
- **Sandbox VM**: Check PowerShell session connectivity and IIS service states
- **App Service**: Verify publish profile and deployment slot configurations

### Debugging Steps

1. Check workflow inputs and secrets are properly configured
2. Verify repository is in the supported list with correct switch logic
3. Confirm branch name matches environment validation (`alpha`, `dev`, `sandbox`)
4. Review artifact upload/download between build and deploy jobs

## Contributing

When modifying workflows:

1. Test changes in a fork before merging
2. Update both the workflow file and this documentation
3. Verify compatibility with all supported repositories
4. Follow the established patterns for input/secret handling
