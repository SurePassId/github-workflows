[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Install-SandboxDeployment.ps1')
$passed = 0
foreach ($scenario in @('success', 'validation-failure', 'missing-prepared', 'retired-collision', 'rollback-failure')) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('module-switch-tests-' + [guid]::NewGuid().ToString('N'))
    $moduleRoot = Join-Path $fixture 'Modules\SandboxDeployment'
    $preparedPath = Join-Path $fixture 'PrivateBackup\Prepared'
    $retiredPath = Join-Path $fixture 'PrivateBackup\Retired'
    $null = [IO.Directory]::CreateDirectory($moduleRoot)
    $null = [IO.Directory]::CreateDirectory($preparedPath)
    [IO.File]::WriteAllText((Join-Path $moduleRoot 'version.txt'), 'v1')
    [IO.File]::WriteAllText((Join-Path $preparedPath 'version.txt'), 'v2')
    try {
        if ($scenario -eq 'missing-prepared') {
            Remove-Item -LiteralPath (Join-Path $preparedPath 'version.txt')
            [IO.Directory]::Delete($preparedPath)
        }
        if ($scenario -eq 'retired-collision') { $null = [IO.Directory]::CreateDirectory($retiredPath) }
        $caught = $null
        try {
            Invoke-SandboxModuleSwitch $preparedPath $moduleRoot $retiredPath {
                if ([IO.File]::ReadAllText((Join-Path $moduleRoot 'version.txt')) -cne 'v2') { throw 'Wrong new module.' }
                if ($scenario -eq 'validation-failure') { throw 'Injected validation failure.' }
                if ($scenario -eq 'rollback-failure') {
                    $null = [IO.Directory]::CreateDirectory($preparedPath)
                    throw 'Injected failure with a blocked rollback destination.'
                }
            }
        } catch { $caught = $_ }
        if ($scenario -eq 'success') {
            if ($caught -or [IO.File]::ReadAllText((Join-Path $moduleRoot 'version.txt')) -cne 'v2' -or
                [IO.File]::ReadAllText((Join-Path $retiredPath 'version.txt')) -cne 'v1') {
                throw 'Successful switch did not preserve v1 and install v2.'
            }
        } elseif ($scenario -eq 'rollback-failure') {
            if (-not $caught -or $caught.Exception.Message -notlike '*Module rollback failed:*' -or
                [IO.File]::ReadAllText((Join-Path $retiredPath 'version.txt')) -cne 'v1' -or
                [IO.File]::ReadAllText((Join-Path $moduleRoot 'version.txt')) -cne 'v2') {
                throw 'Rollback failure was not explicit or original files were lost.'
            }
        } else {
            if (-not $caught -or [IO.File]::ReadAllText((Join-Path $moduleRoot 'version.txt')) -cne 'v1') {
                throw 'Failed switch did not preserve or restore original module.'
            }
            if ($scenario -eq 'validation-failure' -and
                [IO.File]::ReadAllText((Join-Path $preparedPath 'version.txt')) -cne 'v2') {
                throw 'Failed candidate was not retained.'
            }
        }
        $passed++
        Write-Host "PASS module switch $scenario"
    } finally {
        if ([IO.Path]::GetDirectoryName($fixture) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
            [IO.Path]::GetFileName($fixture) -cnotmatch '^module-switch-tests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup.' }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
foreach ($scenario in @('success', 'validation-failure', 'sharing-violation', 'backup-collision', 'rollback-failure', 'hash-mismatch')) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('module-switch-tests-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($fixture)
    $candidatePath = Join-Path $fixture 'candidate.psrc'
    $installedPath = Join-Path $fixture 'installed.psrc'
    $backupPath = Join-Path $fixture 'original.psrc'
    [IO.File]::WriteAllText($candidatePath, 'new role')
    [IO.File]::WriteAllText($installedPath, 'old role')
    $oldHash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash
    $newHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
    $lock = $null
    try {
        if ($scenario -eq 'backup-collision') { [IO.File]::WriteAllText($backupPath, 'do not overwrite') }
        if ($scenario -eq 'sharing-violation') { $lock = [IO.File]::Open($installedPath, 'Open', 'Read', 'Read') }
        $requestedHash = if ($scenario -eq 'hash-mismatch') { '0' * 64 } else { $newHash }
        $caught = $null
        try {
            Set-SandboxRoleCapability $candidatePath $installedPath $backupPath $oldHash $requestedHash {
                if ($scenario -eq 'validation-failure') { throw 'Injected validation failure.' }
                if ($scenario -eq 'rollback-failure') {
                    $null = [IO.Directory]::CreateDirectory($candidatePath)
                    throw 'Injected failure with a blocked rollback destination.'
                }
            }
        } catch { $caught = $_ }
        if ($scenario -eq 'success') {
            if ($caught -or (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash -cne $newHash -or
                (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -cne $oldHash) {
                throw 'Atomic role replacement failed to preserve the original bytes.'
            }
        } elseif ($scenario -eq 'rollback-failure') {
            if (-not $caught -or $caught.Exception.Message -notlike '*Role rollback failed:*' -or
                (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash -cne $newHash -or
                (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -cne $oldHash) {
                throw 'Role rollback failure was not explicit or original bytes were lost.'
            }
        } else {
            if (-not $caught -or (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash -cne $oldHash -or
                (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash -cne $newHash) {
                throw 'Rejected/failed role replacement did not preserve original and candidate bytes.'
            }
            if ($scenario -eq 'backup-collision' -and [IO.File]::ReadAllText($backupPath) -cne 'do not overwrite') {
                throw 'Existing backup was overwritten.'
            }
        }
        $passed++
        Write-Host "PASS atomic role replacement $scenario"
    } finally {
        if ($lock) { $lock.Dispose() }
        if ([IO.Path]::GetDirectoryName($fixture) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
            [IO.Path]::GetFileName($fixture) -cnotmatch '^module-switch-tests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup.' }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
$entrySource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-SandboxDeployment.ps1') -Raw
foreach ($required in @('ShouldProcess', 'Assert-InstallIdle', 'Assert-InstallPrivateDirectory',
    '47B0669C18C32AF041147F49CEF64B303AFDA057D6E2317202FCEDE45F525D56',
    'Test-ModuleManifest', 'Endpoint.pssc')) {
    if (-not $entrySource.Contains($required)) { throw "Required installer safety gate missing: $required" }
}
Write-Host "RESULT: $passed filesystem switch/role replacement tests passed; host, admin, package, idle, ACL and confirmation gates present. No server/IIS/WinRM changes."
