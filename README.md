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
| [build-dot-net-modern.yaml](.github/workflows/build-dot-net-modern.yaml) | .NET 10+ applications | Caller-selected stable `N.0.x` | windows-latest |

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

### .NET 10+ Build

Use the [modern builder](.github/workflows/build-dot-net-modern.yaml) for .NET 10
and later released SDKs. The .NET 8 builder is unchanged.
Replace the placeholder below with the full published commit SHA containing the
modern builder before using this example.

```yaml
jobs:
  build:
    uses: SurePassId/github-workflows/.github/workflows/build-dot-net-modern.yaml@REPLACE_WITH_PUBLISHED_40_CHARACTER_COMMIT_SHA
    with:
      APP: "api"
      SLOT: "stage"
      DEPLOY_ENV: "prod"
      BUILD_CONFIG: "Release"
      BUILD_PROJECT: 'SurePassIdApiServer\SurePassIdApiServer.csproj'
      DOTNET_VERSION: '10.0.x'
    secrets:
      SSH_KEY: ${{ secrets.AZURE_SSH_KEY }}
```

All six inputs and `SSH_KEY` are required. `DOTNET_VERSION` accepts only stable
channels in `N.0.x` form with a major version of at least 10. The builder fails
if the selected SDK is a preview or does not match the requested major. Keep any
caller-owned `global.json` aligned with that channel; it is never overwritten.
Restore targets only `BUILD_PROJECT` using NuGet.org, and publish uses
`--no-restore`. Project files determine target frameworks and publishing mode.

The artifact remains `app-{APP}-{SLOT}`, so existing App Service deployment jobs
can consume it unchanged. The hosting target must separately support the
application's runtime. See the [implementation and rollout guide](docs/dotnet-10-plus-workflow-update.md)
for SDK selection details, validation, and rollback.

### Sandbox VM Deployment

```yaml
name: Deploy to Sandbox VM
on:
  push:
    branches: [sandbox]

jobs:
  build-and-deploy:
    uses: SurePassId/github-workflows/.github/workflows/build-deploy-sandboxvm.yaml@main
    with:
      DEPLOY_APP_NAME: "oidc"
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

### Sandbox VM Credentials

- `SANDBOX_VM_USERNAME` - Windows VM username
- `SANDBOX_VM_PASSWORD` - Windows VM password
- `SANDBOX_VM_HOSTNAME` - Windows VM hostname/IP

### API Testing

- `POSTMAN_API_KEY` - Postman API key for test automation

## Infrastructure Requirements

### Self-Hosted Runners

- **Tags**: `[self-hosted, windows-build-vm]`
- **Pre-installed**: MSBuild, 7-Zip, PowerShell Core
- **Network Access**: SurePassID internal networks

### Sandbox VM Structure

- **IIS Path**: `E:\iis_sites\{env}\{app}-{env}.surepassid.com`
- **Backup System**: Automatic 7z backups with 3-backup retention
- **Service Management**: IIS `appcmd` for site/pool control

## Development

### Adding New Repository Support

1. Add repository case in workflow switch statements
2. Define build type (`framework` vs `core`), solution/project paths
3. Configure environment variables and assembly names
4. Update Postman test configurations if applicable

### Adding New .NET Version

For .NET 10 and later, reuse
[build-dot-net-modern.yaml](.github/workflows/build-dot-net-modern.yaml) with the
new stable `DOTNET_VERSION` channel. Validate SDK selection, application
compatibility, and target hosting support before deployment.

For legacy version-specific builders:

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
