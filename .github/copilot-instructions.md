# GitHub Workflows Repository - AI Coding Agent Instructions

## Repository Purpose

This is a centralized repository containing reusable GitHub Actions workflows for the SurePassID organization. These workflows handle building, testing, and deploying various .NET applications across different environments (alpha, dev, sandbox) and hosting platforms (Azure App Service, self-hosted VMs).

## Architecture Overview

### Workflow Categories

1. **Build Workflows**: Platform-specific build processes for different .NET versions

   - `build-dot-net-fwk.yaml`: .NET Framework 4.8 builds (uses windows-2019, MSBuild)
   - `build-dot-net6.yaml`: .NET 6 builds (uses dotnet CLI)
   - `build-dot-net8.yaml`: .NET 8 builds (uses dotnet CLI)

2. **Deployment Workflows**: Target-specific deployment strategies

   - `deploy-to-app-service.yaml`: Azure App Service deployments with slot support
   - `build-deploy-sandboxvm.yaml`: Self-hosted Windows VM deployments with IIS

3. **Testing Workflows**: Automated API testing
   - `run-postman-tests.yaml`: Postman collection execution with environment-specific configs

### Key Patterns

#### Repository-Specific Configuration

All workflows use repository switching logic to determine build/deployment parameters:

```powershell
switch ("${{ github.repository }}") {
  "SurePassId/SurePassIdLegacyMfaServer" { /* Legacy .NET Framework */ }
  "SurePassId/SurePassIdMfaServer" { /* .NET 8 API */ }
  "SurePassId/SurePassIdPushServer" { /* .NET Framework Push */ }
  "SurePassId/IdentityProvider" { /* .NET 8 OIDC with multi-app support */ }
}
```

#### Environment Detection

Branch-based environment mapping with strict validation:

```powershell
$SiteEnv = ("${{ github.ref }}" -split "/")[-1]
if ("alpha", "dev", "sandbox" -notcontains "$SiteEnv") {
  Throw "Invalid branch: ${{ github.ref }}"
}
```

#### Artifact Naming Convention

Consistent artifact naming: `app-{APP}-{SLOT}` enables multi-slot deployments and environment promotion.

### Critical Dependencies

#### Required Secrets

- `GH_ACTIONS_PAT`: GitHub Actions token for accessing private repos/submodules
- `SSH_KEY`: For checking out repositories with submodules
- `PUBLISH_PROFILE`: Azure App Service publish profiles
- `POSTMAN_API_KEY`: For API testing automation
- Sandbox VM credentials: `SANDBOX_VM_USERNAME`, `SANDBOX_VM_PASSWORD`, `SANDBOX_VM_HOSTNAME`

#### External Actions

- `SurePassId/copy-web-env-files@main`: Custom action for environment-specific file deployment
- Standard GitHub Actions: `checkout@v4`, `setup-dotnet@v4`, `upload-artifact@v3`

### Infrastructure Assumptions

#### Self-Hosted Runners

- Tag: `[self-hosted, windows-build-vm]`
- Pre-installed: MSBuild, 7-Zip, PowerShell Core
- Access to SurePassID internal networks

#### Sandbox VM Structure

- IIS sites organized as: `E:\iis_sites\{env}\{app}-{env}.surepassid.com`
- Automatic backup system with 3-backup retention
- Service management via `appcmd` commands

## Development Workflows

### Adding New Repository Support

1. Add repository case in workflow switch statements
2. Define build type (`framework` vs `core`), solution/project paths
3. Configure environment variables and assembly names
4. Update Postman test configurations if applicable

### Environment File Strategy

Uses `copy-web-env-files` action to overlay environment-specific configurations post-build. This allows single builds with environment-specific runtime configs.

### Testing Integration

Postman tests are repository and environment specific. Collection/environment IDs are hardcoded in workflow logic. Tests run against deployed applications using separate PostmanFiles repository.

## Common Modification Patterns

### Adding .NET Version Support

1. Copy existing `build-dot-net{X}.yaml`
2. Update `dotnet-version` in setup step
3. Add version check in repository switch logic

### New Deployment Target

1. Create new workflow following input/secret patterns
2. Implement environment URL generation for GitHub Environments
3. Add artifact download step matching build naming convention

### Debugging Deployment Issues

- Check artifact names match between build and deploy jobs
- Verify environment-specific file copying succeeded
- For sandbox VM: check PowerShell session connectivity and IIS service states
- For App Service: verify publish profile and slot configurations

Remember: All workflows are `workflow_call` reusable workflows - they're designed to be called from other repositories, not run directly.
