Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem, System.Net.Http

function Get-SandboxSiteMap {
    $sites = @{}
    foreach ($environment in @('alpha', 'dev', 'sandbox')) {
        foreach ($application in @('mfa', 'api', 'push')) {
            $siteName = "$application-$environment.surepassid.com"
            $sites[$siteName] = "E:\iis_sites\$environment\$siteName"
        }
    }
    $sites['oidc-alpha.surepassid.com'] = 'E:\iis_sites\alpha\oidc-alpha.surepassid.com'
    $sites['oidc-sandbox.surepassid.com'] = 'E:\iis_sites\sandbox\oidc\oidc-sandbox.surepassid.com'
    $sites['oidc-client-alpha.surepassid.com'] = 'E:\iis_sites\alpha\oidc-client-alpha.surepassid.com'
    return $sites
}

function Assert-SandboxTree {
    param([string]$Path, [switch]$AncestorsOnly)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $attributes = [IO.File]::GetAttributes($cursor)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are forbidden.' }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -and -not $AncestorsOnly) {
        foreach ($child in (Get-ChildItem -LiteralPath $Path -Force)) {
            Assert-SandboxTree $child.FullName
        }
    }
}

function Get-SandboxTarget {
    param([string]$SiteName)
    $sites = Get-SandboxSiteMap
    if (-not $sites.ContainsKey($SiteName)) { throw 'Site is not authorized.' }
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-Item -LiteralPath "IIS:\Sites\$SiteName" -ErrorAction Stop
    $expectedPath = $sites[$SiteName]
    $actualPath = [Environment]::ExpandEnvironmentVariables([string]$site.PhysicalPath)
    if ([IO.Path]::GetFullPath($actualPath).TrimEnd('\') -ine $expectedPath -or
        [string]$site.ApplicationPool -ine $SiteName -or
        @(Get-WebApplication -Site $SiteName | Where-Object { $_.Path -cne '/' }).Count -or
        @(Get-WebVirtualDirectory -Site $SiteName | Where-Object { $_.Path -cne '/' }).Count -or
        @(Get-Website | Where-Object { $_.Name -ine $SiteName -and $_.ApplicationPool -ieq $SiteName }).Count -or
        @(Get-WebApplication | Where-Object { $_.Path -cne '/' -and $_.ApplicationPool -ieq $SiteName }).Count) {
        throw 'IIS path, dedicated pool, child applications or virtual directories differ from the approved mapping.'
    }
    Assert-SandboxTree $expectedPath
    return [pscustomobject]@{ SiteName = $SiteName; Path = $expectedPath }
}

function Get-SandboxStagingRoot {
    if ($env:COMPUTERNAME -ine 'sandbox-app' -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Server deployment operations require Windows PowerShell 5.1 on sandbox-app.'
    }
    $root = Join-Path $env:ProgramData 'SurePassID-SandboxDeploy'
    Assert-SandboxTree $root -AncestorsOnly
    $acl = Get-Acl -LiteralPath $root
    if (-not $acl.AreAccessRulesProtected) { throw 'Staging root must have a protected SYSTEM/Administrators-only ACL.' }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544')) {
            throw 'Staging root grants access outside SYSTEM/Administrators; operator review required.'
        }
    }
    return $root
}

function Get-SandboxCaller {
    $sender = Get-Variable -Name PSSenderInfo -ValueOnly -ErrorAction Ignore
    if ($null -ne $sender) {
        $caller = [string]$sender.UserInfo.Identity.Name
    } else {
        $caller = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    if ([string]::IsNullOrWhiteSpace($caller)) { throw 'Authenticated upload owner is unavailable.' }
    return $caller.ToUpperInvariant()
}

function Open-SandboxLock {
    param([string]$Name)
    if ($Name -cnotmatch '^[a-f0-9]{32}\.upload\.lock$') {
        if (-not $Name.EndsWith('.lock', [StringComparison]::Ordinal) -or
            -not (Get-SandboxSiteMap).ContainsKey($Name.Substring(0, $Name.Length - 5))) {
            throw 'Invalid lock identity.'
        }
    }
    $path = Join-Path (Get-SandboxStagingRoot) $Name
    if (Test-Path -LiteralPath $path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Lock anchor must be an ordinary file.' }
        Assert-SandboxTree $path -AncestorsOnly
    }
    return [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None')
}

function Get-SandboxUpload {
    param([string]$UploadId, [switch]$AllowExpired, [switch]$Operator)
    if ($UploadId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid upload ID.' }
    $directory = Join-Path (Get-SandboxStagingRoot) $UploadId
    Assert-SandboxTree $directory
    $metadata = Get-Content -LiteralPath (Join-Path $directory 'metadata.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($propertyName in @('Version', 'Owner', 'SiteName', 'CreatedUtc')) {
        if ($metadata.PSObject.Properties.Name -notcontains $propertyName) { throw 'Legacy or invalid upload metadata; operator inspection required.' }
    }
    if ($metadata.Version -ne 2 -or $metadata.SiteName -isnot [string] -or
        -not (Get-SandboxSiteMap).ContainsKey($metadata.SiteName)) { throw 'Invalid upload metadata version/site.' }
    if (-not $Operator -and [string]$metadata.Owner -cne (Get-SandboxCaller)) {
        throw 'Upload belongs to a different authenticated caller.'
    }
    if (-not $AllowExpired -and [datetime]::Parse($metadata.CreatedUtc).ToUniversalTime() -lt [datetime]::UtcNow.AddHours(-24)) {
        throw 'Upload expired; completion is forbidden.'
    }
    return [pscustomobject]@{ Directory = $directory; SiteName = [string]$metadata.SiteName; UploadId = $UploadId }
}

function Assert-SandboxUnblocked {
    param([string]$SiteName)
    if (Test-Path -LiteralPath (Join-Path (Get-SandboxStagingRoot) "$SiteName.recovery.json")) {
        throw 'Site has an unresolved deployment journal. Operator recovery is required.'
    }
}

function New-SandboxUpload {
    param([Parameter(Mandatory)][string]$SiteName)
    $null = Get-SandboxTarget $SiteName
    $siteLock = Open-SandboxLock "$SiteName.lock"
    try {
        Assert-SandboxUnblocked $SiteName
        $uploadId = [guid]::NewGuid().ToString('N')
        $directory = Join-Path (Get-SandboxStagingRoot) $uploadId
        if (Test-Path -LiteralPath $directory) { throw 'Upload ID collision; nothing was reused.' }
        $null = [IO.Directory]::CreateDirectory($directory)
        @{ Version = 2; SiteName = $SiteName; Owner = Get-SandboxCaller; CreatedUtc = [datetime]::UtcNow.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'metadata.json') -Encoding UTF8
        $stream = [IO.File]::Open((Join-Path $directory 'package.zip'), 'CreateNew', 'Write', 'None')
        $stream.Dispose()
        return $uploadId
    } finally { $siteLock.Dispose() }
}

function Add-SandboxUploadChunk {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$UploadId,
        [Parameter(Mandatory)][ValidateRange(0, 4294967296)][long]$Offset,
        [Parameter(Mandatory)][ValidateLength(1, 262144)][string]$Base64
    )
    $uploadLock = Open-SandboxLock "$UploadId.upload.lock"
    try {
        $upload = Get-SandboxUpload $UploadId
        $siteLock = Open-SandboxLock "$($upload.SiteName).lock"
        try {
            Assert-SandboxUnblocked $upload.SiteName
            $bytes = [Convert]::FromBase64String($Base64)
            if ($bytes.Length -eq 0) { throw 'Empty chunks are forbidden.' }
            $stream = [IO.File]::Open((Join-Path $upload.Directory 'package.zip'), 'Open', 'Write', 'None')
            try {
                if ($stream.Length -ne $Offset) { throw 'Upload offset mismatch; do not retry blindly.' }
                if ($Offset + $bytes.Length -gt 4GB) { throw 'Upload exceeds 4 GiB.' }
                $stream.Position = $Offset
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
                return [long]$stream.Length
            } finally { $stream.Dispose() }
        } finally { $siteLock.Dispose() }
    } finally { $uploadLock.Dispose() }
}

function Remove-SandboxUpload {
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$UploadId)
    $uploadLock = Open-SandboxLock "$UploadId.upload.lock"
    try {
        $directory = Join-Path (Get-SandboxStagingRoot) $UploadId
        if (-not (Test-Path -LiteralPath $directory)) { return }
        $upload = Get-SandboxUpload $UploadId -AllowExpired
        $siteLock = Open-SandboxLock "$($upload.SiteName).lock"
        try {
            Assert-SandboxUnblocked $upload.SiteName
            Assert-SandboxTree $directory
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
        } finally { $siteLock.Dispose() }
    } finally { $uploadLock.Dispose() }
}

function Get-SandboxHash {
    param([IO.Stream]$Stream)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return [BitConverter]::ToString($algorithm.ComputeHash($Stream)).Replace('-', '')
    } finally { $algorithm.Dispose(); $Stream.Position = 0 }
}

function Get-SandboxArchiveInfo {
    param([IO.Stream]$Stream, [switch]$Backup)
    $archive = [IO.Compression.ZipArchive]::new($Stream, 'Read', $true)
    try {
        $names = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::OrdinalIgnoreCase)
        $expandedBytes = 0L
        $fileCount = 0
        if (-not $Backup) { Assert-SandboxArchiveLimits $Stream.Length 0 $archive.Entries.Count }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $segments = $name.TrimEnd('/').Split('/')
            foreach ($segment in $segments) {
                if ($segment -in @('', '.', '..') -or $segment -match '[:<>"|?*\x00-\x1f]' -or
                    $segment -match '[. ]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
                    throw 'Unsafe archive path.'
                }
            }
            $unixType = ([long]$entry.ExternalAttributes -band 0xF0000000L)
            if ($unixType -notin @(0L, 0x80000000L, 0x40000000L) -or
                ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint)) {
                throw 'Archive links and special files are forbidden.'
            }
            $isDirectory = $name.EndsWith('/')
            if ($isDirectory -and $entry.Length) { throw 'Directory entry contains data.' }
            $key = $name.TrimEnd('/')
            if ($names.ContainsKey($key)) { throw 'Duplicate archive path.' }
            $names.Add($key, $isDirectory)
            $expandedBytes += $entry.Length
            if (-not $Backup) { Assert-SandboxArchiveLimits $Stream.Length $expandedBytes $archive.Entries.Count }
            if (-not $isDirectory) { $fileCount++ }
        }
        foreach ($name in $names.Keys) {
            $parent = $name
            while ($parent.Contains('/')) {
                $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
                if ($names.ContainsKey($parent) -and -not $names[$parent]) { throw 'Archive file/directory collision.' }
            }
        }
        if ($fileCount -eq 0) { throw 'Archive contains no files.' }
        return [long]$expandedBytes
    } finally { $archive.Dispose(); $Stream.Position = 0 }
}

function Assert-SandboxArchiveLimits {
    param([long]$PackageBytes, [long]$ExpandedBytes, [long]$EntryCount)
    if ($PackageBytes -le 0 -or $PackageBytes -gt 4GB -or $ExpandedBytes -lt 0 -or
        $ExpandedBytes -gt 8GB -or $EntryCount -le 0 -or $EntryCount -gt 100000) {
        throw 'Package exceeds archive limits (4 GiB ZIP, 8 GiB expanded, 100000 entries).'
    }
}

function Expand-SandboxPackage {
    param([IO.Stream]$Stream, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'Extraction directory already exists; inspect retained upload.' }
    $null = [IO.Directory]::CreateDirectory($Destination)
    $archive = [IO.Compression.ZipArchive]::new($Stream, 'Read', $true)
    try {
        foreach ($entry in $archive.Entries) {
            $path = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName.Replace('/', '\')))
            if (-not $path.StartsWith($Destination.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Extraction escaped its owned directory.'
            }
            if ($entry.FullName.EndsWith('/')) {
                $null = [IO.Directory]::CreateDirectory($path)
            } else {
                $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
                $output = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
                try {
                    $input = $entry.Open()
                    try {
                        $buffer = [byte[]]::new(64KB)
                        $copiedBytes = 0L
                        while (($readBytes = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $copiedBytes += $readBytes
                            if ($copiedBytes -gt $entry.Length) { throw 'Extracted data exceeded its validated length.' }
                            $output.Write($buffer, 0, $readBytes)
                        }
                    } finally { $input.Dispose() }
                    if ($output.Length -ne $entry.Length) { throw 'Extracted file length mismatch.' }
                } finally { $output.Dispose() }
            }
        }
    } finally { $archive.Dispose(); $Stream.Position = 0 }
    Assert-SandboxTree $Destination
}

function Read-SandboxXml {
    param([string]$Path, [string]$RootName = 'configuration')
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    try {
        $reader = [Xml.XmlReader]::Create($Path, $settings)
        try {
            $document = [Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.Load($reader)
            if ($document.DocumentElement.Name -cne $RootName -or
                $document.SelectNodes('//@configSource | //appSettings/@file | //@configProtectionProvider').Count) {
                throw 'Non-self-contained configuration.'
            }
            return ,$document
        } finally { $reader.Dispose() }
    } catch { throw 'Invalid staged XML configuration; content suppressed.' }
}

function Get-SandboxHealthUrl {
    param([string]$SiteName)
    if ($SiteName -cmatch '^api-(alpha|dev|sandbox)\.surepassid\.com$') { return "https://$SiteName/status" }
    if ($SiteName -cmatch '^mfa-(alpha|dev|sandbox)\.surepassid\.com$') { return "https://$SiteName/server/HealthCheck.aspx" }
    throw 'Completion for this application is not health-qualified. Upload-only remains available.'
}

function Assert-SandboxPayload {
    param($Target, [string]$Path)
    $null = Get-SandboxHealthUrl $Target.SiteName
    $configuration = Read-SandboxXml (Join-Path $Path 'web.config')
    if ($Target.SiteName -like 'mfa-*') {
        $assembly = 'bin\SurePassAdmin.dll'
        $settings = @{}
        foreach ($setting in $configuration.SelectNodes('/configuration/appSettings/add')) {
            $key = $setting.GetAttribute('key')
            if ($settings.ContainsKey($key)) { throw 'Duplicate staged MFA setting.' }
            $settings[$key] = $setting.GetAttribute('value')
        }
        if ($settings['MfaServerLicence.LicenseCode'] -or
            $settings['MfaServerLicence.FilePath'] -ine [IO.Path]::Combine($Target.Path, 'bin') -or
            $settings['MfaServerLicence.Filename'] -cne 'site.lic') { throw 'MFA license policy mismatch.' }
        $licensePath = Join-Path $Path 'bin\site.lic'
    } else {
        $assembly = 'SurePassIdApiServer.dll'
        $environment = ($Target.SiteName -split '[.-]')[1]
        $runtimeSettings = @($configuration.SelectNodes('//aspNetCore/environmentVariables/environmentVariable') |
            Where-Object { $_.GetAttribute('name') -in @('ASPNETCORE_ENVIRONMENT', 'DOTNET_ENVIRONMENT') })
        if (-not $runtimeSettings.Count -or @($runtimeSettings | Where-Object {
            $_.GetAttribute('value') -cne "mfa-$environment"
        }).Count) { throw 'API runtime environment mismatch.' }
        foreach ($fileName in @('appsettings.json', "appsettings.mfa-$environment.json", 'appsettings.local.json')) {
            try { $null = Get-Content -LiteralPath (Join-Path $Path $fileName) -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
            catch { throw 'Invalid staged API JSON configuration; content suppressed.' }
        }
        $null = Read-SandboxXml (Join-Path $Path 'logging.config') 'log4net'
        try {
            $localSettings = Get-Content -LiteralPath (Join-Path $Path 'appsettings.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $license = $localSettings.AppSettings.MfaServerLicense
            if ([string]::IsNullOrWhiteSpace($localSettings.ConnectionStrings.MFA) -or
                [string]::IsNullOrWhiteSpace($license.ValidationKey) -or
                $license.FilePath -ine $Target.Path -or $license.Filename -cne 'site.lic' -or
                $license.LicenseCode -isnot [string]) { throw 'API policy mismatch.' }
            $inlineLicense = -not [string]::IsNullOrEmpty($license.LicenseCode)
        } catch { throw 'API local settings do not satisfy provisioning policy; content suppressed.' }
        $licensePath = Join-Path $Path 'site.lic'
        if ($inlineLicense) {
            if (Test-Path -LiteralPath $licensePath) { throw 'Inline licensing must not also contain a license file.' }
            $licensePath = $null
        }
    }
    foreach ($filePath in @((Join-Path $Path $assembly), $licensePath)) {
        if ($filePath -and (-not [IO.File]::Exists($filePath) -or (Get-Item -LiteralPath $filePath).Length -le 0)) {
            throw 'Required staged assembly or license is missing/empty.'
        }
    }
}

function Invoke-SandboxHealthRequest {
    param([string]$Url)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $handler.UseCookies = $false
    $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12
    $client = [Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(5)
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Url)
        try {
            $request.Headers.CacheControl = [Net.Http.Headers.CacheControlHeaderValue]::new()
            $request.Headers.CacheControl.NoCache = $true
            $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try { return [int]$response.StatusCode } finally { $response.Dispose() }
        } finally { $request.Dispose() }
    } finally { $client.Dispose() }
}

function Wait-SandboxHealth {
    param([string]$SiteName)
    $url = Get-SandboxHealthUrl $SiteName
    $lastResult = 'not attempted'
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            $status = Invoke-SandboxHealthRequest $url
            if ($status -eq 200) { return }
            $lastResult = "HTTP $status"
        } catch { $lastResult = 'TLS, transport or request timeout failure' }
        if ($attempt -lt 9) { Start-Sleep -Milliseconds 500 }
    }
    throw "Application health failed (exact HTTPS 200 required): $lastResult. Response bodies are not collected."
}

function Invoke-SandboxAppCmd {
    param([string[]]$Arguments)
    $output = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" @Arguments
    if ($LASTEXITCODE -ne 0) { throw "appcmd failed (exit $LASTEXITCODE)." }
    return $output
}

function Set-SandboxIisState {
    param([ValidateSet('site', 'apppool')][string]$Kind, [string]$SiteName,
        [ValidateSet('Started', 'Stopped')][string]$State)
    $getState = {
        if ($Kind -eq 'site') { return (Get-WebsiteState -Name $SiteName).Value }
        return (Get-WebAppPoolState -Name $SiteName).Value
    }
    if ((& $getState) -ne $State) {
        $verb = 'stop'
        if ($State -eq 'Started') { $verb = 'start' }
        $null = Invoke-SandboxAppCmd @($verb, $Kind, $SiteName)
    }
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while ((& $getState) -ne $State) {
        if ([datetime]::UtcNow -ge $deadline) { throw "IIS $Kind did not reach $State." }
        Start-Sleep -Milliseconds 200
    }
}

function Stop-SandboxSite {
    param([string]$SiteName)
    Set-SandboxIisState 'site' $SiteName 'Stopped'
    Set-SandboxIisState 'apppool' $SiteName 'Stopped'
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    do {
        $workerXml = [xml]((Invoke-SandboxAppCmd @('list', 'wp', "/apppool.name:$SiteName", '/xml')) -join "`n")
        if ($workerXml.DocumentElement.Name -cne 'appcmd') { throw 'Unexpected worker inventory response.' }
        if ($workerXml.SelectNodes('/appcmd/WP').Count -eq 0) { return }
        if ([datetime]::UtcNow -ge $deadline) { throw 'Application pool workers did not drain; content untouched.' }
        Start-Sleep -Milliseconds 200
    } while ($true)
}

function Start-SandboxSite {
    param([string]$SiteName)
    Set-SandboxIisState 'apppool' $SiteName 'Started'
    Set-SandboxIisState 'site' $SiteName 'Started'
}

function Get-SandboxTreeBytes {
    param([string]$Path)
    Assert-SandboxTree $Path
    $total = 0L
    foreach ($item in (Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        $nameBytes = [Text.Encoding]::UTF8.GetByteCount($item.FullName.Substring($Path.Length + 1))
        # Reserve ZIP headers, duplicate names, and conservative DEFLATE block overhead as well as file bytes.
        $total += 256L + 4L * $nameBytes
        if (-not $item.PSIsContainer) { $total += $item.Length + 5L * [long][Math]::Ceiling($item.Length / 16383.0) }
    }
    return $total
}

function Get-SandboxFreeBytes {
    param([string]$Path)
    return [long]([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace
}

function Assert-SandboxCapacity {
    param([string]$SitePath, [long]$ExpandedBytes, [long]$OldBytes, [switch]$Recovery)
    # Account per volume for extraction, uncompressed ZIP overhead, replacement and rollback.
    $requirements = @{}
    $stagingPath = Get-SandboxStagingRoot
    $stagingBytes = $ExpandedBytes + $OldBytes + 64MB
    $siteBytes = $ExpandedBytes + 2 * $OldBytes + 64MB
    if ($Recovery) { $stagingBytes = $OldBytes + 64MB; $siteBytes = $OldBytes + 64MB }
    foreach ($requirement in @(@{ Path = $stagingPath; Bytes = $stagingBytes }, @{ Path = $SitePath; Bytes = $siteBytes })) {
        $root = [IO.Path]::GetPathRoot($requirement.Path)
        if (-not $requirements.ContainsKey($root)) { $requirements[$root] = 0L }
        $requirements[$root] += $requirement.Bytes
    }
    foreach ($root in $requirements.Keys) {
        if ((Get-SandboxFreeBytes $root) -lt $requirements[$root]) { throw 'Insufficient free space for deployment and rollback.' }
    }
}

function Open-SandboxPrivateFile {
    param([string]$Path)
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
    }
    return [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 4096,
        [IO.FileOptions]::None, $acl)
}

function New-SandboxBackup {
    param([string]$Source, [string]$Destination)
    $output = Open-SandboxPrivateFile $Destination
    try {
        $archive = [IO.Compression.ZipArchive]::new($output, 'Create', $true)
        try {
            foreach ($item in (Get-ChildItem -LiteralPath $Source -Recurse -Force)) {
                $relative = $item.FullName.Substring($Source.Length + 1).Replace('\', '/')
                if ($item.PSIsContainer) { $null = $archive.CreateEntry("$relative/") }
                else { $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $item.FullName, $relative, 'Optimal') }
            }
        } finally { $archive.Dispose() }
        $output.Flush($true)
    } finally { $output.Dispose() }
    $input = [IO.File]::OpenRead($Destination)
    try { return Get-SandboxHash $input } finally { $input.Dispose() }
}

function Set-SandboxContent {
    param([string]$Source, [string]$Destination)
    Assert-SandboxTree $Source
    Assert-SandboxTree $Destination
    foreach ($item in (Get-ChildItem -LiteralPath $Destination -Force)) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    }
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
    }
}

function Write-SandboxJournal {
    param([string]$Path, $Journal, [switch]$New)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Compress))
    $temporaryPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $failure = $null
    $cleanupFailure = $null
    try {
        $output = Open-SandboxPrivateFile $temporaryPath
        try { $output.Write($bytes, 0, $bytes.Length); $output.Flush($true) } finally { $output.Dispose() }
        if ($New) { [IO.File]::Move($temporaryPath, $Path) }
        else { [IO.File]::Replace($temporaryPath, $Path, [Management.Automation.Language.NullString]::Value) }
    } catch { $failure = $_ }
    finally {
        try {
            if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        } catch { $cleanupFailure = $_ }
    }
    if ($failure) {
        throw "Journal write failed: $($failure.Exception.Message). Temporary-file cleanup error: $cleanupFailure"
    }
    if ($cleanupFailure) { throw "Journal temporary-file cleanup failed: $($cleanupFailure.Exception.Message)." }
}

function Clear-SandboxJournal {
    param([string]$Path)
    [IO.File]::Delete($Path)
}

function Restore-SandboxRelease {
    param($Target, $Upload, $Journal)
    if ($Journal.Phase -in @('Replacing', 'Committed')) {
        $backupPath = Join-Path ([IO.Path]::GetDirectoryName($Target.Path)) $Journal.BackupName
        Assert-SandboxTree $backupPath
        $backup = [IO.File]::Open($backupPath, 'Open', 'Read', 'Read')
        try {
            if ((Get-SandboxHash $backup) -cne $Journal.BackupSha256) { throw 'Recovery backup hash mismatch.' }
            $oldBytes = Get-SandboxArchiveInfo $backup -Backup
            Assert-SandboxCapacity $Target.Path 0 $oldBytes -Recovery
            $restorePath = Join-Path $Upload.Directory ('restore-' + [guid]::NewGuid().ToString('N'))
            Expand-SandboxPackage $backup $restorePath
            Stop-SandboxSite $Target.SiteName
            Set-SandboxContent $restorePath $Target.Path
        } finally { $backup.Dispose() }
    }
    Start-SandboxSite $Target.SiteName
    Wait-SandboxHealth $Target.SiteName
}

function Complete-SandboxDeployment {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$UploadId,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256
    )
    $uploadLock = Open-SandboxLock "$UploadId.upload.lock"
    try {
        $upload = Get-SandboxUpload $UploadId
        $target = Get-SandboxTarget $upload.SiteName
        $null = Get-SandboxHealthUrl $target.SiteName
        $siteLock = Open-SandboxLock "$($target.SiteName).lock"
        try {
            Assert-SandboxUnblocked $target.SiteName
            $package = [IO.File]::Open((Join-Path $upload.Directory 'package.zip'), 'Open', 'Read', 'Read')
            try {
                if ((Get-SandboxHash $package) -ine $Sha256) { throw 'Package hash mismatch; content untouched.' }
                $expandedBytes = Get-SandboxArchiveInfo $package
                $oldBytes = Get-SandboxTreeBytes $target.Path
                Assert-SandboxCapacity $target.Path $expandedBytes $oldBytes
                $expanded = Join-Path $upload.Directory 'expanded'
                Expand-SandboxPackage $package $expanded
                Assert-SandboxPayload $target $expanded
                if ((Get-WebsiteState -Name $target.SiteName).Value -ne 'Started' -or
                    (Get-WebAppPoolState -Name $target.SiteName).Value -ne 'Started') {
                    throw 'Deployment requires an already started, healthy baseline.'
                }
                Wait-SandboxHealth $target.SiteName
                $backupName = $target.SiteName + '_' + [datetime]::UtcNow.ToString('yyyy-MM-dd_HHmmss') + '.zip'
                $backupPath = Join-Path ([IO.Path]::GetDirectoryName($target.Path)) $backupName
                if (Test-Path -LiteralPath $backupPath) { throw 'Backup timestamp collision; content untouched.' }
                $journalPath = Join-Path (Get-SandboxStagingRoot) "$($target.SiteName).recovery.json"
                $journal = [pscustomobject]@{
                    Version = 2; UploadId = $UploadId; SiteName = $target.SiteName
                    Phase = 'Prepared'; BackupName = $backupName; BackupSha256 = ''
                    CreatedUtc = [datetime]::UtcNow.ToString('o')
                }
                Write-SandboxJournal $journalPath $journal -New
                try {
                    Stop-SandboxSite $target.SiteName
                    $oldBytes = Get-SandboxTreeBytes $target.Path
                    Assert-SandboxCapacity $target.Path $expandedBytes $oldBytes
                    $journal.BackupSha256 = New-SandboxBackup $target.Path $backupPath
                    $journal.Phase = 'Replacing'
                    # Durable intent precedes the first content mutation; interruption always requires recovery.
                    Write-SandboxJournal $journalPath $journal
                    Set-SandboxContent $expanded $target.Path
                    Start-SandboxSite $target.SiteName
                    Wait-SandboxHealth $target.SiteName
                } catch {
                    $deploymentFailure = $_
                    try { Restore-SandboxRelease $target $upload $journal }
                    catch {
                        throw "Deployment failed: $($deploymentFailure.Exception.Message). Recovery failed: $($_.Exception.Message). Retain upload $UploadId, backup and journal; site remains blocked."
                    }
                    try { Clear-SandboxJournal $journalPath }
                    catch { throw "Deployment failed: $($deploymentFailure.Exception.Message). Recovery health passed; journal cleanup failed: $($_.Exception.Message). Site remains blocked." }
                    throw "Deployment failed: $($deploymentFailure.Exception.Message). Previous release restored and HTTPS health verified; upload retained."
                }
                $journal.Phase = 'Committed'
                Write-SandboxJournal $journalPath $journal
                try { Clear-SandboxJournal $journalPath }
                catch { throw "Deployment health passed but journal cleanup failed: $($_.Exception.Message). Retain upload and backup; site remains blocked." }
                return [pscustomobject]@{
                    SiteName = $target.SiteName; Destination = $target.Path; Backup = $backupPath
                    State = 'Started'; HealthStatus = 200; HealthUrl = Get-SandboxHealthUrl $target.SiteName
                    HealthVerified = $true; ModuleVersion = '2.0.0'; UploadId = $UploadId
                }
            } finally { $package.Dispose() }
        } finally { $siteLock.Dispose() }
    } finally { $uploadLock.Dispose() }
}

function Repair-SandboxDeployment {
    param([string]$SiteName, [string]$UploadId, [string]$ExpectedJournalSha256)
    $uploadLock = Open-SandboxLock "$UploadId.upload.lock"
    try {
        $upload = Get-SandboxUpload $UploadId -AllowExpired -Operator
        if ($upload.SiteName -cne $SiteName) { throw 'Recovery upload/site mismatch.' }
        $target = Get-SandboxTarget $SiteName
        $null = Get-SandboxHealthUrl $SiteName
        $siteLock = Open-SandboxLock "$SiteName.lock"
        try {
            $journalPath = Join-Path (Get-SandboxStagingRoot) "$SiteName.recovery.json"
            Assert-SandboxTree $journalPath
            $input = [IO.File]::Open($journalPath, 'Open', 'Read', 'Read')
            try {
                if ((Get-SandboxHash $input) -cne $ExpectedJournalSha256) { throw 'Journal changed; re-inspect before recovery.' }
                $reader = [IO.StreamReader]::new($input, [Text.Encoding]::UTF8, $true, 1024, $true)
                try { $journal = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            } finally { $input.Dispose() }
            if ($journal.Version -ne 2 -or $journal.UploadId -cne $UploadId -or $journal.SiteName -cne $SiteName -or
                $journal.Phase -cnotin @('Prepared', 'Replacing', 'Committed') -or
                $journal.BackupName -cnotmatch ('^' + [regex]::Escape($SiteName) + '_\d{4}-\d{2}-\d{2}_\d{6}\.zip$')) {
                throw 'Invalid recovery journal; no automatic recovery is permitted.'
            }
            if ($journal.Phase -ne 'Prepared' -and $journal.BackupSha256 -cnotmatch '^[A-F0-9]{64}$') {
                throw 'Invalid recovery backup hash.'
            }
            Restore-SandboxRelease $target $upload $journal
            Clear-SandboxJournal $journalPath
            return [pscustomobject]@{ SiteName = $SiteName; UploadId = $UploadId; RecoveryHealthVerified = $true }
        } finally { $siteLock.Dispose() }
    } finally { $uploadLock.Dispose() }
}

Export-ModuleMember -Function New-SandboxUpload, Add-SandboxUploadChunk, Complete-SandboxDeployment, Remove-SandboxUpload
