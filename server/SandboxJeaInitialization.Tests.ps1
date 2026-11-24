[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('sandbox-jea-tests-' + [guid]::NewGuid().ToString('N'))
$originalModulePath = $env:PSModulePath
try {
    $modulePath = Join-Path $fixture 'Modules'
    $moduleRoot = Join-Path $modulePath 'SandboxDeployment'
    $versionPath = Join-Path $moduleRoot '2.1.0'
    $rolesPath = Join-Path $moduleRoot 'RoleCapabilities'
    $null = [IO.Directory]::CreateDirectory($versionPath)
    $null = [IO.Directory]::CreateDirectory($rolesPath)
    foreach ($fileName in @('SandboxDeployment.psd1', 'SandboxDeployment.psm1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "SandboxDeployment\$fileName") -Destination $versionPath
    }
    $manifestPath = (Join-Path $versionPath 'SandboxDeployment.psd1').Replace("'", "''")
    $roleName = 'InitializationProbe' + [guid]::NewGuid().ToString('N')
    $rolePath = Join-Path $rolesPath "$roleName.psrc"
    $configPath = Join-Path $fixture 'Probe.pssc'
    New-PSSessionConfigurationFile -Path $configPath -SessionType RestrictedRemoteServer `
        -RoleDefinitions @{ 'Fixture-Principal' = @{ RoleCapabilities = $roleName } }
    $env:PSModulePath = $modulePath + ';' + $originalModulePath
    $roleFilter = [Func[string, bool]] { param($principalName) return $principalName -ceq 'Fixture-Principal' }
    foreach ($mode in @('RequiredVersion', 'ExactPath')) {
        $moduleExpression = if ($mode -eq 'RequiredVersion') {
            "@{ ModuleName = '$manifestPath'; RequiredVersion = '2.1.0' }"
        } else {
            "'$manifestPath'"
        }
        $roleContent = @"
@{
    GUID = '$([guid]::NewGuid())'
    ModulesToImport = @($moduleExpression)
    VisibleFunctions = @('New-SandboxUpload', 'Add-SandboxUploadChunk', 'Complete-SandboxDeployment', 'Remove-SandboxUpload')
    VisibleCmdlets = @()
    VisibleExternalCommands = @()
    VisibleAliases = @()
}
"@
        if ($mode -eq 'ExactPath') {
            $roleContent = [IO.File]::ReadAllText(
                (Join-Path $PSScriptRoot 'SandboxDeployment\RoleCapabilities\SurePassIDSandboxDeployer.psrc')).Replace(
                    'C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\2.1.0\SandboxDeployment.psd1',
                    $manifestPath)
        }
        [IO.File]::WriteAllText($rolePath, $roleContent)
        $state = [Management.Automation.Runspaces.InitialSessionState]::CreateFromSessionConfigurationFile(
            $configPath, $roleFilter)
        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($state)
        $caught = $null
        try {
            try { $runspace.Open() } catch { $caught = $_ }
            if ($mode -eq 'RequiredVersion') {
                if (-not $caught -or $caught.Exception.ToString() -notlike "*'Test-ModuleManifest' is not recognized*") {
                    throw "Expected missing Test-ModuleManifest during constrained initialization; actual: $caught"
                }
                Write-Host 'PASS native constrained runspace reproduces RequiredVersion initialization failure.'
            } else {
                if ($caught) { throw $caught }
                $pipeline = [Management.Automation.PowerShell]::Create()
                try {
                    $pipeline.Runspace = $runspace
                    $null = $pipeline.AddCommand('Get-Command')
                    $commands = @($pipeline.Invoke())
                    if ($pipeline.HadErrors) { throw ($pipeline.Streams.Error | Out-String) }
                    foreach ($expected in @('New-SandboxUpload', 'Add-SandboxUploadChunk',
                        'Complete-SandboxDeployment', 'Remove-SandboxUpload')) {
                        if ($expected -notin $commands.Name) { throw "Missing constrained command: $expected" }
                    }
                    foreach ($forbidden in @('Test-ModuleManifest', 'Import-Module', 'Invoke-Expression', 'Get-Content')) {
                        if ($forbidden -in $commands.Name) { throw "Unexpected exposed command: $forbidden" }
                    }
                    if ($runspace.SessionStateProxy.LanguageMode -ne 'NoLanguage') { throw 'Constrained language mode changed.' }
                    Write-Host 'PASS exact-path import opens actual constrained runspace with all four functions and no additional administrative commands.'
                } finally { $pipeline.Dispose() }
            }
        } finally { $runspace.Dispose() }
    }
    Write-Host 'RESULT: 2 native constrained-runspace initialization tests passed; actual module imported, no WinRM, upload or IIS operation.'
} finally {
    $env:PSModulePath = $originalModulePath
    if ([IO.Path]::GetDirectoryName($fixture) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
        [IO.Path]::GetFileName($fixture) -cnotmatch '^sandbox-jea-tests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup.' }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
