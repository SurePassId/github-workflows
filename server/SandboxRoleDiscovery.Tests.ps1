[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Install-SandboxDeployment.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('sandbox-role-tests-' + [guid]::NewGuid().ToString('N'))
$originalModulePath = $env:PSModulePath
try {
    $modulePath = Join-Path $fixture 'Modules'
    $moduleRoot = Join-Path $modulePath 'ProbeModule'
    $versionPath = Join-Path $moduleRoot '2.0.0'
    $versionedRoles = Join-Path $versionPath 'RoleCapabilities'
    $null = [IO.Directory]::CreateDirectory($versionedRoles)
    [IO.File]::WriteAllText((Join-Path $versionPath 'ProbeModule.psd1'),
        "@{ ModuleVersion = '2.0.0'; GUID = '$([guid]::NewGuid())' }")
    $roleName = 'ProbeRole' + [guid]::NewGuid().ToString('N')
    $rolePath = Join-Path $versionedRoles "$roleName.psrc"
    [IO.File]::WriteAllText($rolePath, "@{ GUID = '$([guid]::NewGuid())' }")
    $configPath = Join-Path $fixture 'Probe.pssc'
    New-PSSessionConfigurationFile -Path $configPath -SessionType RestrictedRemoteServer `
        -RoleDefinitions @{ 'Fixture-Principal' = @{ RoleCapabilities = $roleName } }
    $env:PSModulePath = $modulePath + ';' + $originalModulePath
    $roleFilter = [Func[string, bool]] { param($principalName) return $principalName -ceq 'Fixture-Principal' }
    $rejectedVersionedRole = $false
    try {
        $null = [Management.Automation.Runspaces.InitialSessionState]::CreateFromSessionConfigurationFile(
            $configPath, $roleFilter)
    } catch {
        if ($_.Exception.Message -notlike '*Could not find the role capability*') { throw }
        $rejectedVersionedRole = $true
    }
    if (-not $rejectedVersionedRole) { throw 'Versioned-only role unexpectedly resolved; do not assume the proposed layout fix is needed.' }
    Write-Host 'PASS actual JEA loader rejects role only inside module version directory.'
    $rootRoles = Join-Path $moduleRoot 'RoleCapabilities'
    $null = [IO.Directory]::CreateDirectory($rootRoles)
    [IO.File]::Move($rolePath, (Join-Path $rootRoles "$roleName.psrc"))
    $state = [Management.Automation.Runspaces.InitialSessionState]::CreateFromSessionConfigurationFile(
        $configPath, $roleFilter)
    if (-not $state) { throw 'Root-level role did not produce an initial session state.' }
    Write-Host 'PASS actual JEA loader resolves root-level role alongside a versioned manifest.'
    $stagePath = Join-Path $fixture 'Stage'
    $stagedVersion = Join-Path $stagePath 'SandboxDeployment\2.0.0'
    $stagedRoles = Join-Path $stagedVersion 'RoleCapabilities'
    $null = [IO.Directory]::CreateDirectory($stagedRoles)
    [IO.File]::WriteAllText((Join-Path $stagedVersion 'SandboxDeployment.psd1'),
        "@{ ModuleVersion = '2.0.0'; GUID = '$([guid]::NewGuid())' }")
    [IO.File]::WriteAllText((Join-Path $stagedVersion 'SandboxDeployment.psm1'), '')
    [IO.File]::WriteAllText((Join-Path $stagedVersion 'DoNotInstall.ps1'), 'throw "unexpected extra file"')
    [IO.File]::WriteAllText((Join-Path $stagedRoles 'SurePassIDSandboxDeployer.psrc'),
        "@{ GUID = '$([guid]::NewGuid())' }")
    $records = @(foreach ($relative in @('SandboxDeployment.psd1', 'SandboxDeployment.psm1',
        'RoleCapabilities\SurePassIDSandboxDeployer.psrc')) {
        [pscustomobject]@{
            Path = 'SandboxDeployment/2.0.0/' + $relative.Replace('\', '/')
            Sha256 = (Get-FileHash -LiteralPath (Join-Path $stagedVersion $relative) -Algorithm SHA256).Hash
        }
    })
    $installedRoot = Join-Path $modulePath 'SandboxDeployment'
    New-SandboxModuleCandidate $stagePath $installedRoot
    Assert-InstallFiles $installedRoot @(Get-SandboxInstalledFileRecords $records)
    if (@(Get-ChildItem -LiteralPath $installedRoot -File -Recurse).Count -ne 3) {
        throw 'Candidate did not install exactly the three verified files.'
    }
    $deploymentConfig = Join-Path $fixture 'Deployment.pssc'
    New-PSSessionConfigurationFile -Path $deploymentConfig -SessionType RestrictedRemoteServer `
        -RoleDefinitions @{ 'SANDBOX-APP\github-deploy' = @{ RoleCapabilities = 'SurePassIDSandboxDeployer' } }
    Assert-SandboxRoleDiscovery $deploymentConfig
    Write-Host 'PASS actual candidate layout installs only approved files, preserves hashes and resolves through the native JEA loader.'
    $rootRole = Join-Path $installedRoot 'RoleCapabilities\SurePassIDSandboxDeployer.psrc'
    $oldRoleDirectory = Join-Path $installedRoot '2.0.0\RoleCapabilities'
    $null = [IO.Directory]::CreateDirectory($oldRoleDirectory)
    $oldRole = Join-Path $oldRoleDirectory 'SurePassIDSandboxDeployer.psrc'
    $roleHash = (Get-FileHash -LiteralPath $rootRole -Algorithm SHA256).Hash
    [IO.File]::Move($rootRole, $oldRole)
    Move-SandboxRoleCapability $installedRoot $roleHash {
        Assert-SandboxRoleDiscovery $deploymentConfig
        Assert-InstallFiles $installedRoot @(Get-SandboxInstalledFileRecords $records)
    }
    if (Test-Path -LiteralPath $oldRole) { throw 'Repair left duplicate roles.' }
    Write-Host 'PASS repair moves the same verified role bytes and restores native JEA discovery without a duplicate.'
    $rejected = $false
    try { Move-SandboxRoleCapability $installedRoot $roleHash {} }
    catch {
        if ($_.Exception.Message -notlike '*Root-level role already exists*') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Repair overwrote an existing destination.' }
    Write-Host 'PASS duplicate destination is refused without overwriting.'
    [IO.File]::Move($rootRole, $oldRole)
    $rejected = $false
    try { Move-SandboxRoleCapability $installedRoot $roleHash { throw 'Injected validation failure.' } }
    catch {
        if ($_.Exception.Message -notlike '*Original role location preserved or restored*') { throw }
        $rejected = $true
    }
    if (-not $rejected -or (Test-Path -LiteralPath $rootRole) -or
        (Get-FileHash -LiteralPath $oldRole -Algorithm SHA256).Hash -cne $roleHash) { throw 'Repair rollback failed.' }
    Write-Host 'PASS validation failure restores the original file and location.'
    $rejected = $false
    try { Move-SandboxRoleCapability $installedRoot ('0' * 64) {} }
    catch {
        if ($_.Exception.Message -notlike '*Installed role bytes do not match*') { throw }
        $rejected = $true
    }
    if (-not $rejected -or (Test-Path -LiteralPath $rootRole)) { throw 'Hash mismatch was not refused.' }
    Write-Host 'PASS unverified role bytes are refused before moving.'
    $lock = [IO.File]::Open($oldRole, 'Open', 'Read', 'Read')
    try {
        $rejected = $false
        try { Move-SandboxRoleCapability $installedRoot $roleHash {} }
        catch {
            if ($_.Exception.Message -notlike '*Role layout repair failed:*') { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Test-Path -LiteralPath $rootRole) -or -not (Test-Path -LiteralPath $oldRole)) {
            throw 'Sharing violation did not preserve the source.'
        }
    } finally { $lock.Dispose() }
    Write-Host 'PASS sharing violation fails explicitly and preserves the source role.'
    $rejected = $false
    try {
        Move-SandboxRoleCapability $installedRoot $roleHash {
            [IO.File]::WriteAllText($oldRole, 'Injected rollback obstruction.')
            throw 'Injected validation failure.'
        }
    } catch {
        if ($_.Exception.Message -notlike '*Role rollback failed:*') { throw }
        $rejected = $true
    }
    if (-not $rejected -or (Get-FileHash -LiteralPath $rootRole -Algorithm SHA256).Hash -cne $roleHash) {
        throw 'Rollback failure was hidden or the original role bytes were lost.'
    }
    Write-Host 'PASS rollback failure is explicit and retains the original role bytes.'
    Write-Host 'RESULT: 9 discovery/layout/repair tests passed; native JEA lookup used, no session opened, endpoint registered, or WinRM connection made.'
} finally {
    $env:PSModulePath = $originalModulePath
    if ([IO.Path]::GetDirectoryName($fixture) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
        [IO.Path]::GetFileName($fixture) -cnotmatch '^sandbox-role-tests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup.' }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
