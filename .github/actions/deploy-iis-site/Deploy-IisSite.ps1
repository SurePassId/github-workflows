<#
.SYNOPSIS
    Deploys a published .NET application to an IIS site on a remote Windows host.

.DESCRIPTION
    The new release is assembled in a staging directory while the site keeps serving.
    The site is only stopped for the two renames that swap staging into place, and the
    previous release is retained next to it so a failure can be rolled back by renaming
    it back.

.NOTES
    Runs on the build runner under PowerShell 7. The remote session is Windows PowerShell 5.1,
    so nothing sent to it may use 7-only syntax.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ComputerName,
    [Parameter(Mandatory)][string] $UserName,
    [Parameter(Mandatory)][string] $Password,
    [Parameter(Mandatory)][string] $SiteEnv,
    [Parameter(Mandatory)][string] $AppName,
    [Parameter(Mandatory)][string] $SourcePath,
    [Parameter(Mandatory)][string] $AppAssembly,
    [Parameter(Mandatory)][string] $RunId,
    [string] $KeepList = '',
    [string] $SiteRoot = 'E:\iis_sites',
    [string] $SevenZip = 'C:\Program Files\7-Zip\7z.exe',
    [string] $Appcmd = 'C:\Windows\System32\inetsrv\appcmd.exe',
    [int]    $BackupsToKeep = 3
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -ge [version]'7.3') {
    $PSNativeCommandUseErrorActionPreference = $true
}

function Invoke-Native {
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

# Declared global: so they persist for the life of the PSSession and every later Invoke-Command can call them.
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

$SiteDomainName = "$AppName-$SiteEnv.surepassid.com"
$EnvRoot        = Join-Path $SiteRoot $SiteEnv
$LivePath       = Join-Path $EnvRoot $SiteDomainName
$StagingPath    = "$LivePath.staging-$RunId"
$PreviousPath   = "$LivePath.previous"
$ArchiveName    = "deploy-$SiteDomainName-$RunId.7z"
$TempRoot       = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$LocalZipPath   = Join-Path $TempRoot $ArchiveName

$session    = $null
$iisStopped = $false

try {
    Write-Host "::group::Validate and compress the publish output"
    $localAssembly = Join-Path $SourcePath $AppAssembly
    if (-not (Test-Path -Path $localAssembly)) {
        throw "Expected assembly not found at $localAssembly. The publish step produced nothing usable."
    }
    if (Test-Path -Path $LocalZipPath) {
        Remove-Item -Path $LocalZipPath -Force
    }
    Invoke-Native -FilePath $SevenZip `
                  -ArgumentList @('a', '-t7z', $LocalZipPath, (Join-Path $SourcePath '*')) `
                  -Description 'Compressing the publish output'
    $archiveBytes = (Get-Item -Path $LocalZipPath).Length
    Write-Host "::endgroup::"

    $credential = [pscredential]::new(
        $UserName,
        (ConvertTo-SecureString $Password -AsPlainText -Force)
    )
    $session = New-PSSession -ComputerName $ComputerName -Credential $credential
    Invoke-Command -Session $session -ScriptBlock $RemoteHelpers

    Write-Host "::group::Prepare the staging directory on $ComputerName"
    Invoke-Command -Session $session -ScriptBlock {
        param ($LivePath, $StagingPath, $ArchiveBytes)
        # Abandoned staging directories from cancelled runs, plus the rollback source from the last deployment.
        Get-ChildItem -Path "$LivePath.staging-*" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -Path $_.FullName -Recurse -Force }

        $drive = (Split-Path -Qualifier $LivePath).TrimEnd(':')
        $free = (Get-PSDrive -Name $drive).Free
        # Archive, extracted tree, and the retained previous release all have to fit.
        $required = $ArchiveBytes * 3
        if ($free -lt $required) {
            throw "Drive ${drive}: has $free bytes free but the deployment needs at least $required."
        }

        New-Item -Path $StagingPath -ItemType Directory -Force | Out-Null
    } -ArgumentList $LivePath, $StagingPath, $archiveBytes
    Write-Host "::endgroup::"

    Write-Host "::group::Transfer and extract the release"
    Copy-Item -Path $LocalZipPath `
              -Destination (Join-Path $StagingPath $ArchiveName) `
              -ToSession $session `
              -Force

    Invoke-Command -Session $session -ScriptBlock {
        param ($StagingPath, $ArchiveName, $AppAssembly, $SevenZip)
        $remoteZipPath = Join-Path $StagingPath $ArchiveName
        Invoke-Native -FilePath $SevenZip `
                      -ArgumentList @('x', $remoteZipPath, "-o$StagingPath", '-y') `
                      -Description 'Extracting the release archive'
        Remove-Item -Path $remoteZipPath -Force

        $stagedAssembly = Join-Path $StagingPath $AppAssembly
        if (-not (Test-Path -Path $stagedAssembly)) {
            throw "Extraction left no $AppAssembly in $StagingPath. The archive is incomplete."
        }
    } -ArgumentList $StagingPath, $ArchiveName, $AppAssembly, $SevenZip
    Write-Host "::endgroup::"

    Write-Host "::group::Back up the live release"
    Invoke-Command -Session $session -ScriptBlock {
        param ($LivePath, $SevenZip, $BackupsToKeep)
        if (Test-Path -Path $LivePath) {
            $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
            # -ssw reads files that w3wp still holds open, which is what lets this run before the stop.
            Invoke-Native -FilePath $SevenZip `
                          -ArgumentList @('a', '-t7z', '-ssw', "${LivePath}_$stamp.7z", $LivePath, '-xr!Trace') `
                          -Description 'Backing up the live directory'
        }
        Get-ChildItem -Path "${LivePath}_*.7z" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $BackupsToKeep |
            ForEach-Object { Remove-Item -Path $_.FullName -Force }
    } -ArgumentList $LivePath, $SevenZip, $BackupsToKeep
    Write-Host "::endgroup::"

    # ---- downtime window opens ----
    Write-Host "::group::Stop $SiteDomainName"
    # Set before the stop, so a partial stop is still restarted by the finally block.
    $iisStopped = $true
    Invoke-Command -Session $session -ScriptBlock {
        param ($SiteDomainName, $Appcmd)
        # Exit codes ignored on purpose: stopping an already-stopped site is not an error. Wait-For is the real assertion.
        & $Appcmd stop site    $SiteDomainName 2>$null | Out-Null
        & $Appcmd stop apppool $SiteDomainName 2>$null | Out-Null

        Wait-For -Description "site $SiteDomainName to report Stopped" -TimeoutSeconds 90 -Condition {
            (& $Appcmd list site "$SiteDomainName" /text:state 2>$null) -eq 'Stopped'
        }
        Wait-For -Description "app pool $SiteDomainName to report Stopped" -TimeoutSeconds 90 -Condition {
            (& $Appcmd list apppool "$SiteDomainName" /text:state 2>$null) -eq 'Stopped'
        }
        Wait-For -Description 'worker processes to exit' -TimeoutSeconds 180 -Condition {
            -not (& $Appcmd list wp /apppool.name:"$SiteDomainName" /text:name 2>$null)
        }
    } -ArgumentList $SiteDomainName, $Appcmd
    Write-Host "::endgroup::"

    Write-Host "::group::Swap $StagingPath into place"
    Invoke-Command -Session $session -ScriptBlock {
        param ($LivePath, $StagingPath, $PreviousPath, $KeepList)
        if ([string]::IsNullOrWhiteSpace($KeepList)) {
            $keep = @()
        }
        else {
            $keep = $KeepList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }

        foreach ($entry in $keep) {
            $from = Join-Path $LivePath $entry
            if (-not (Test-Path -Path $from)) {
                continue
            }
            $to = Join-Path $StagingPath $entry
            if (Test-Path -Path $to) {
                Remove-Item -Path $to -Recurse -Force
            }
            Move-Item -Path $from -Destination $to
        }

        if (Test-Path -Path $PreviousPath) {
            Remove-Item -Path $PreviousPath -Recurse -Force
        }
        if (Test-Path -Path $LivePath) {
            Rename-Item -Path $LivePath -NewName (Split-Path -Leaf $PreviousPath)
        }
        Rename-Item -Path $StagingPath -NewName (Split-Path -Leaf $LivePath)
    } -ArgumentList $LivePath, $StagingPath, $PreviousPath, $KeepList
    Write-Host "::endgroup::"

    Write-Host "::group::Start $SiteDomainName"
    Invoke-Command -Session $session -ScriptBlock {
        param ($SiteDomainName, $Appcmd)
        Invoke-Native -FilePath $Appcmd `
                      -ArgumentList @('start', 'apppool', $SiteDomainName) `
                      -Description "Starting app pool $SiteDomainName"
        Invoke-Native -FilePath $Appcmd `
                      -ArgumentList @('start', 'site', $SiteDomainName) `
                      -Description "Starting site $SiteDomainName"
        Wait-For -Description "site $SiteDomainName to report Started" -TimeoutSeconds 90 -Condition {
            (& $Appcmd list site "$SiteDomainName" /text:state 2>$null) -eq 'Started'
        }
    } -ArgumentList $SiteDomainName, $Appcmd
    $iisStopped = $false
    # ---- downtime window closes ----

    Write-Host "Deployed $SiteDomainName. Rollback source retained at $PreviousPath."
}
finally {
    if ($session) {
        Invoke-Command -Session $session -ScriptBlock {
            param ($StagingPath, $LivePath, $PreviousPath, $SiteDomainName, $Appcmd, $IisStopped)
            if (Test-Path -Path $StagingPath) {
                Remove-Item -Path $StagingPath -Recurse -Force
            }
            # Only reachable if the run died between the two renames.
            if (-not (Test-Path -Path $LivePath) -and (Test-Path -Path $PreviousPath)) {
                Rename-Item -Path $PreviousPath -NewName (Split-Path -Leaf $LivePath)
                Write-Warning "Rolled $SiteDomainName back to the previous release."
            }
            if ($IisStopped -and (Test-Path -Path $LivePath)) {
                & $Appcmd start apppool $SiteDomainName 2>$null | Out-Null
                & $Appcmd start site    $SiteDomainName 2>$null | Out-Null
            }
        } -ArgumentList $StagingPath, $LivePath, $PreviousPath, $SiteDomainName, $Appcmd, $iisStopped `
          -ErrorAction Continue

        Remove-PSSession $session
    }
    if (Test-Path -Path $LocalZipPath) {
        Remove-Item -Path $LocalZipPath -Force
    }
}
