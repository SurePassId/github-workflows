[CmdletBinding()]
param()

function Assert-ChildName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\\/:*?"<>|\x00-\x1f]' -or
        $Name -in @('.', '..') -or $Name -match '[. ]$' -or
        $Name -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
        throw 'Invalid direct child name.'
    }
}

function Convert-AssemblyPath {
    param([string]$Path)
    if (!$Path -or $Path -match '^[\\/]{2}' -or $Path -match ':') {
        throw 'Invalid assembly path.'
    }
    $relative = $Path.TrimStart([char[]]'\/')
    foreach ($part in ($relative -split '[\\/]')) {
        Assert-ChildName $part
    }
    return $relative.Replace('/', '\')
}

function Assert-SafeAncestors {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Reparse point rejected.'
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }
}

function Get-SafeSourceItems {
    param([string]$Path)
    Assert-SafeAncestors $Path
    foreach ($child in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        Assert-ChildName $child.Name
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Reparse point rejected.'
        }
        $child
        if ($child.PSIsContainer) {
            Get-SafeSourceItems $child.FullName
        }
    }
}

function Get-SandboxDestination {
    param([string]$App, [string]$SiteEnv)
    if ($SiteEnv -cnotin @('alpha', 'dev', 'sandbox') -or
        $App -cnotin @('api', 'mfa', 'saml2', 'push', 'oidc', 'oidc-client')) {
        throw 'Invalid app-name or site-env.'
    }
    if (($App -eq 'oidc' -and $SiteEnv -eq 'dev') -or
        ($App -eq 'oidc-client' -and $SiteEnv -ne 'alpha')) {
        throw 'Site is not authorized by the restricted endpoint.'
    }
    $domain = "$App-$SiteEnv.surepassid.com"
    if ($App -eq 'oidc' -and $SiteEnv -eq 'sandbox') {
        return "E:\iis_sites\sandbox\oidc\$domain"
    }
    return "E:\iis_sites\$SiteEnv\$domain"
}

function New-DeploymentConfig {
    if ($env:COMPUTERNAME -ine 'GH-RUNNER-WIN') {
        throw 'WinRM operations must execute on GH-RUNNER-WIN (gh-runner-windows), not this computer.'
    }
    if ($env:DEPLOY_COMPUTER_NAME -notmatch '^sandbox-app(?:\.[a-z0-9-]+)*$' -or
        $env:DEPLOY_USERNAME -ine 'SANDBOX-APP\github-deploy' -or
        [string]::IsNullOrWhiteSpace($env:DEPLOY_PASSWORD)) {
        throw 'Use the approved sandbox-app target and its dedicated github-deploy account.'
    }
    $destination = Get-SandboxDestination $env:DEPLOY_APP_NAME $env:DEPLOY_SITE_ENV
    $domain = "$env:DEPLOY_APP_NAME-$env:DEPLOY_SITE_ENV.surepassid.com"
    if ($env:DEPLOY_RUN_ID -cnotmatch '^[1-9][0-9]*-[1-9][0-9]*$') {
        throw 'Invalid numeric run-id-attempt.'
    }
    $healthUrlText = ''
    if (![string]::IsNullOrWhiteSpace($env:DEPLOY_HEALTH_CHECK_URL)) {
        $healthUri = $null
        if (![Uri]::TryCreate($env:DEPLOY_HEALTH_CHECK_URL, [UriKind]::Absolute, [ref]$healthUri) -or
            $healthUri.Scheme -ne 'https' -or $healthUri.Host -ne $domain -or
            !$healthUri.IsDefaultPort -or $healthUri.UserInfo -or $healthUri.Fragment) {
            throw 'Health URL must use HTTPS on the exact app/environment host, default port, without credentials or fragment.'
        }
        $healthUrlText = $healthUri.AbsoluteUri
    }
    $assembly = Convert-AssemblyPath $env:DEPLOY_APP_ASSEMBLY
    $keep = @()
    if ($env:DEPLOY_KEEP_LIST) {
        foreach ($childName in ($env:DEPLOY_KEEP_LIST -split ',')) {
            $childName = $childName.Trim()
            Assert-ChildName $childName
            if ($keep -contains $childName -or ($assembly -split '\\')[0] -eq $childName) {
                throw 'Duplicate keep-list entry or an entry that would overwrite application code.'
            }
            $keep += $childName
        }
    }
    if ($env:DEPLOY_APP_NAME -in @('api', 'mfa', 'saml2') -and $keep.Count) {
        throw 'API/MFA/SAML2 configuration comes from the repository; keep-list retention is forbidden.'
    }
    $source = $env:DEPLOY_SOURCE_PATH
    if (!$source -or $source -notmatch '^[a-zA-Z]:[\\/]' -or
        $source -match '(^|[\\/])\.\.?([\\/]|$)' -or $source -match '[*?"<>|]' -or
        $source.Substring(2).Contains(':')) {
        throw 'Source must be an absolute local safe directory path.'
    }
    $source = [IO.Path]::GetFullPath($source).TrimEnd('\', '/')
    if ($source -eq [IO.Path]::GetPathRoot($source).TrimEnd('\', '/') -or
        ($env:GITHUB_WORKSPACE -and
            $source -eq [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\', '/'))) {
        throw 'Source cannot be drive root or the entire workspace.'
    }
    if (!(Test-Path -LiteralPath $source -PathType Container)) {
        throw 'Source directory missing.'
    }
    $null = @(Get-SafeSourceItems $source)
    $assemblyFile = Get-Item -LiteralPath (Join-Path $source $assembly) -Force -ErrorAction Stop
    if ($assemblyFile.PSIsContainer -or $assemblyFile.Length -le 0) {
        throw 'Source assembly must be a nonempty file.'
    }
    return [pscustomobject]@{
        AppName = $env:DEPLOY_APP_NAME
        Domain = $domain
        Destination = $destination
        Source = $source
        Assembly = $assembly
        Keep = $keep
        HealthUrl = $healthUrlText
        RunId = $env:DEPLOY_RUN_ID
        ComputerName = $env:DEPLOY_COMPUTER_NAME
    }
}

function Assert-DeployableApp {
    param([string]$AppName)
    if ($AppName -cnotin @('api', 'mfa', 'saml2')) {
        throw 'Live completion is only enabled for API, MFA, and SAML2. Use upload-only for other applications.'
    }
}

function Assert-SandboxPackageLimits {
    param([long]$PackageBytes, [long]$ExpandedBytes, [long]$EntryCount)
    if ($PackageBytes -le 0 -or $PackageBytes -gt 4GB) {
        throw 'ZIP package must be nonempty and at most 4 GiB.'
    }
    if ($ExpandedBytes -lt 0 -or $ExpandedBytes -gt 8GB) {
        throw 'Expanded package exceeds 8 GiB.'
    }
    if ($EntryCount -le 0 -or $EntryCount -gt 100000) {
        throw 'ZIP package must contain 1..100000 entries.'
    }
}

function Write-SandboxArchive {
    param([string]$Source, [IO.Stream]$Stream)
    $items = @(Get-SafeSourceItems $Source)
    $expandedBytes = [long]0
    foreach ($item in $items) {
        if (!$item.PSIsContainer) {
            $expandedBytes += $item.Length
        }
    }
    Assert-SandboxPackageLimits 1 $expandedBytes $items.Count
    $archive = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($item in $items) {
            $relative = $item.FullName.Substring($Source.Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) {
                $null = $archive.CreateEntry("$relative/")
            } else {
                $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, $item.FullName, $relative, [IO.Compression.CompressionLevel]::Optimal)
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-SandboxPackageHash {
    param([IO.Stream]$Stream)
    Assert-SandboxPackageLimits $Stream.Length 0 1
    $Stream.Position = 0
    $archive = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        $expandedBytes = [long]0
        $fileCount = 0
        foreach ($entry in $archive.Entries) {
            $expandedBytes += $entry.Length
            if (!$entry.FullName.EndsWith('/')) {
                $fileCount++
            }
        }
        Assert-SandboxPackageLimits $Stream.Length $expandedBytes $archive.Entries.Count
        if ($fileCount -eq 0) {
            throw 'ZIP package contains no files.'
        }
    } finally {
        $archive.Dispose()
    }
    $Stream.Position = 0
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($algorithm.ComputeHash($Stream)).Replace('-', '')
    } finally {
        $algorithm.Dispose()
        $Stream.Position = 0
    }
}

function Invoke-SandboxCommand {
    param($Session, [ValidateSet('New', 'Add', 'Complete', 'Remove')][string]$Operation,
        [string]$SiteName, [string]$UploadId, [long]$Offset, [string]$Base64, [string]$Sha256)
    switch ($Operation) {
        'New' {
            Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                New-SandboxUpload -SiteName $using:SiteName
            }
        }
        'Add' {
            Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                Add-SandboxUploadChunk -UploadId $using:UploadId -Offset $using:Offset -Base64 $using:Base64
            }
        }
        'Complete' {
            Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                Complete-SandboxDeployment -UploadId $using:UploadId -Sha256 $using:Sha256
            }
        }
        'Remove' {
            Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                Remove-SandboxUpload -UploadId $using:UploadId
            }
        }
    }
}

function Assert-SandboxCompletion {
    param([object[]]$Results, $Config, [string]$UploadId)
    if ($Results.Count -ne 1 -or $null -eq $Results[0]) {
        throw 'Invalid completion result count.'
    }
    $result = $Results[0]
    foreach ($propertyName in @('SiteName', 'Destination', 'Backup', 'State', 'HealthCheckMode', 'ModuleVersion', 'UploadId')) {
        if ($result.PSObject.Properties.Name -notcontains $propertyName -or
            $result.$propertyName -isnot [string]) {
            throw "Invalid completion result property: $propertyName."
        }
    }
    if ($result.PSObject.Properties.Name -notcontains 'HealthVerified' -or
        $result.HealthVerified -isnot [bool]) {
        throw 'Invalid completion result property: HealthVerified must be boolean.'
    }
    $backupParent = [IO.Path]::GetDirectoryName($Config.Destination)
    $backupPattern = '^' + [regex]::Escape($Config.Domain) + '_\d{4}-\d{2}-\d{2}_\d{6}\.zip$'
    if ($result.SiteName -cne $Config.Domain -or $result.Destination -ine $Config.Destination -or
        $result.State -cne 'Started' -or [IO.Path]::GetDirectoryName($result.Backup) -ine $backupParent -or
        [IO.Path]::GetFileName($result.Backup) -cnotmatch $backupPattern -or
        $result.HealthCheckMode -cne 'Deferred' -or $result.ModuleVersion -cne '2.1.0' -or
        $result.UploadId -cne $UploadId) {
        throw 'Completion result does not match the requested site, module version, upload ID, or approved backup location.'
    }
    return $result
}

function Send-SandboxPackage {
    param($Config, [IO.Stream]$Stream, [switch]$Complete)
    $ErrorActionPreference = 'Stop'
    if ($Complete) {
        Assert-DeployableApp $Config.AppName
    }
    $sha256 = Get-SandboxPackageHash $Stream
    $session = $null
    $uploadId = $null
    $createAttempted = $false
    $completionAttempted = $false
    $completionValidated = $false
    $completionResult = $null
    $failure = $null
    $cleanupIssues = [Collections.Generic.List[string]]::new()
    try {
        if ($env:COMPUTERNAME -ine 'GH-RUNNER-WIN') {
            throw 'WinRM operations must execute on GH-RUNNER-WIN (gh-runner-windows), not this computer.'
        }
        $credential = [Management.Automation.PSCredential]::new($env:DEPLOY_USERNAME,
            (ConvertTo-SecureString $env:DEPLOY_PASSWORD -AsPlainText -Force))
        $operationTimeoutMs = if ($Complete) { 600000 } else { 60000 }
        $session = New-PSSession -ComputerName $Config.ComputerName -Credential $credential `
            -ConfigurationName 'SurePassID.SandboxDeploy' -Authentication Negotiate `
            -SessionOption (New-PSSessionOption -OpenTimeout 30000 -OperationTimeout $operationTimeoutMs) -ErrorAction Stop
        if ($session.State -ne 'Opened' -or $session.Availability -ne 'Available') {
            throw 'Restricted endpoint session did not become available.'
        }
        $createAttempted = $true
        $identifiers = @(Invoke-SandboxCommand -Session $session -Operation New -SiteName $Config.Domain)
        if ($identifiers.Count -ne 1 -or $identifiers[0] -isnot [string] -or
            $identifiers[0] -cnotmatch '^[a-f0-9]{32}$') {
            throw 'Invalid upload identifier; inspect server staging before manual cleanup.'
        }
        $uploadId = $identifiers[0]
        Write-Host "Owned sandbox upload: $uploadId (run $($Config.RunId))."
        $buffer = [byte[]]::new(192KB)
        $offset = [long]0
        $chunkCount = 0
        while (($byteCount = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $base64 = [Convert]::ToBase64String($buffer, 0, $byteCount)
            $received = @(Invoke-SandboxCommand -Session $session -Operation Add -UploadId $uploadId `
                -Offset $offset -Base64 $base64)
            $offset += $byteCount
            if ($received.Count -ne 1 -or $received[0] -isnot [long] -or $received[0] -ne $offset) {
                throw 'Upload acknowledgement mismatch; no append retry or completion was attempted.'
            }
            $chunkCount++
        }
        if ($offset -ne $Stream.Length) {
            throw 'Incomplete ZIP transfer; completion was not attempted.'
        }
        if ($Complete) {
            $completionAttempted = $true
            $results = @(Invoke-SandboxCommand -Session $session -Operation Complete -UploadId $uploadId -Sha256 $sha256)
            $completionResult = Assert-SandboxCompletion $results $Config $uploadId
            $completionValidated = $true
        }
    } catch {
        $failure = $_
    } finally {
        $safeToRemoveUpload = $uploadId -and (!$completionAttempted -or $completionValidated)
        if ($safeToRemoveUpload -and $session -and
            $session.State -eq 'Opened' -and $session.Availability -eq 'Available') {
            try {
                $removeResults = @(Invoke-SandboxCommand -Session $session -Operation Remove -UploadId $uploadId)
                if ($removeResults.Count -ne 0) {
                    throw 'Unexpected upload-removal response.'
                }
            } catch {
                if ($completionValidated) {
                    $cleanupIssues.Add("Deployment succeeded and IIS started, but upload cleanup failed for ${uploadId}: $($_.Exception.Message)")
                } else {
                    $cleanupIssues.Add("Upload cleanup failed for ${uploadId}: $($_.Exception.Message)")
                }
            }
        } elseif ($uploadId) {
            if ($completionValidated) {
                $cleanupIssues.Add("Deployment succeeded and IIS started, but upload $uploadId was retained because the session became unavailable. Operator cleanup is required.")
            } else {
                $cleanupIssues.Add("Upload $uploadId retained: completion was attempted or the session is unavailable. Operator inspection is required before removal.")
            }
        } elseif ($createAttempted) {
            $cleanupIssues.Add('Upload creation outcome is unknown; inspect server staging. No identifier was guessed or removed.')
        }
        if ($session) {
            try {
                Remove-PSSession -Session $session -ErrorAction Stop
            } catch {
                $cleanupIssues.Add("Session cleanup failed: $($_.Exception.Message)")
            }
        }
    }
    if ($failure) {
        throw [InvalidOperationException]::new(
            "$($failure.Exception.Message) $($cleanupIssues -join '; ')", $failure.Exception)
    }
    if ($cleanupIssues.Count -gt 0) {
        throw ($cleanupIssues -join '; ')
    }
    if ($Complete) {
        Write-Host "Deployment completed for $($Config.Domain): $offset bytes uploaded; backup $($completionResult.Backup); IIS $($completionResult.State); health check $($completionResult.HealthCheckMode) (module $($completionResult.ModuleVersion)); owned upload removed."
        return [pscustomobject]@{
            Mode = 'Deploy'
            SiteName = $completionResult.SiteName
            Destination = $completionResult.Destination
            Backup = $completionResult.Backup
            State = $completionResult.State
            HealthCheckMode = $completionResult.HealthCheckMode
            HealthVerified = $completionResult.HealthVerified
            ModuleVersion = $completionResult.ModuleVersion
            UploadId = $uploadId
            AcknowledgedBytes = $offset
            ChunkCount = $chunkCount
            LocalZipSha256 = $sha256
            UploadRemoved = $true
            CompletionAttempted = $true
        }
    }
    Write-Host "Upload-only validation finished for $($Config.Domain): $offset bytes acknowledged; owned upload removed. No deployment or health verification performed."
    return [pscustomobject]@{
        Mode = 'UploadOnly'
        SiteName = $Config.Domain
        UploadId = $uploadId
        AcknowledgedBytes = $offset
        ChunkCount = $chunkCount
        LocalZipSha256 = $sha256
        UploadRemoved = $true
        CompletionAttempted = $false
    }
}

function Remove-OwnedArchive {
    param([string]$Path, [string]$Parent)
    if ([IO.Path]::GetDirectoryName($Path) -ine $Parent -or
        [IO.Path]::GetFileName($Path) -cnotmatch '^sandbox-upload-[a-f0-9]{32}\.zip$') {
        throw 'Archive cleanup outside the owned path was rejected.'
    }
    Assert-SafeAncestors $Parent
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Owned archive was replaced by a directory or reparse point.'
        }
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}

function Invoke-Deployment {
    param([switch]$UploadOnly)
    $ErrorActionPreference = 'Stop'
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'Runner requires PowerShell 7.'
    }
    $config = New-DeploymentConfig
    if (!$UploadOnly) {
        Assert-DeployableApp $config.AppName
    }
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $temp = [IO.Path]::GetFullPath($temp).TrimEnd('\', '/')
    Assert-SafeAncestors $temp
    if ($temp -ieq $config.Source -or $temp.StartsWith($config.Source + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Local ZIP must be outside the published source directory.'
    }
    $archivePath = Join-Path $temp ('sandbox-upload-' + [guid]::NewGuid().ToString('N') + '.zip')
    $stream = $null
    $owned = $false
    $failure = $null
    $cleanupIssues = [Collections.Generic.List[string]]::new()
    try {
        $stream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $owned = $true
        Write-SandboxArchive $config.Source $stream
        $receipt = Send-SandboxPackage -Config $config -Stream $stream -Complete:(!$UploadOnly)
    } catch {
        $failure = $_
    } finally {
        if ($stream) {
            try {
                $stream.Dispose()
            } catch {
                $cleanupIssues.Add("Archive stream cleanup failed: $($_.Exception.Message)")
            }
        }
        if ($owned) {
            try {
                Remove-OwnedArchive $archivePath $temp
            } catch {
                $cleanupIssues.Add("Local archive cleanup failed at ${archivePath}: $($_.Exception.Message)")
            }
        }
    }
    if ($failure) {
        throw [InvalidOperationException]::new(
            "$($failure.Exception.Message) $($cleanupIssues -join '; ')", $failure.Exception)
    }
    if ($cleanupIssues.Count -gt 0) {
        throw ($cleanupIssues -join '; ')
    }
    return $receipt
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($env:DEPLOY_UPLOAD_ONLY -cnotin @('true', 'false')) {
        throw 'upload-only must be exactly true or false.'
    }
    Invoke-Deployment -UploadOnly:($env:DEPLOY_UPLOAD_ONLY -ceq 'true')
}
