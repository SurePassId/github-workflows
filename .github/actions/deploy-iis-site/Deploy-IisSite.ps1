# Local entry point: pwsh 7. Remote helpers deliberately use Windows PowerShell 5.1 syntax.
# Dot sourcing loads helpers only (used by the isolated assertion harness).
[CmdletBinding()]
param()

function Assert-ChildName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\\/:*?"<>|\x00-\x1f]' -or
        $Name -in @('.', '..') -or $Name -match '[. ]$' -or
        $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw 'Invalid direct child name.'
    }
}

function Convert-AssemblyPath {
    param([string]$Path)
    if (!$Path -or $Path -match '^[\\/]{2}' -or $Path -match ':') { throw 'Invalid assembly path.' }
    $relative = $Path.TrimStart([char[]]'\/')
    foreach ($part in ($relative -split '[\\/]')) { Assert-ChildName $part }
    return $relative.Replace('/', '\')
}

function Assert-SafeTree {
    param([string]$Path)
    # Check ancestors too: an ordinary child below a junction is not safe.
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point rejected.' }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if (Test-Path -LiteralPath $Path) {
        foreach ($child in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point rejected.' }
            if ($child.PSIsContainer) { Assert-SafeTree $child.FullName }
        }
    }
}

function Get-TreeBytes {
    param([string]$Path)
    Assert-SafeTree $Path
    if (!(Test-Path -LiteralPath $Path)) { return [long]0 }
    $item = Get-Item -LiteralPath $Path -Force
    if (!$item.PSIsContainer) { return [long]$item.Length }
    $sum = [long]0
    foreach ($child in (Get-ChildItem -LiteralPath $Path -Force)) { $sum += Get-TreeBytes $child.FullName }
    return $sum
}

function Remove-BoundedPath {
    param([string]$Path, [string]$Parent, [string]$Name)
    Assert-ChildName $Name
    $expected = [IO.Path]::GetFullPath((Join-Path $Parent $Name))
    if ([IO.Path]::GetFullPath($Path) -ne $expected) { throw 'Deletion outside allowed direct child.' }
    Assert-SafeTree $Path
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
}

function Invoke-CheckedNative {
    param([string]$Tool, [string[]]$Arguments)
    # Never emit native output: tools can print configuration, file contents or secrets.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Tool
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    $info.Arguments = (@($Arguments | ForEach-Object {
        '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }) -join ' ')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $limit = if ([IO.Path]::GetFileName($Tool) -ieq 'appcmd.exe') { 30000 } else { 900000 }
    try {
        if (!$process.Start()) { throw 'Native tool could not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($limit)) {
            $process.Kill()
            throw 'Native operation timed out; deployment aborted.'
        }
        if ($process.ExitCode -ne 0) { throw "Native operation failed (exit $($process.ExitCode))." }
        # Ensure both redirected pipes have drained, without returning stderr.
        $text = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        return @($text -split '\r?\n' | Where-Object { $_ -ne '' })
    } finally {
        $process.Dispose()
    }
}

function Wait-IisCondition {
    param([scriptblock]$Condition, [int]$Seconds, [string]$Description)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 250
    } while ($clock.Elapsed.TotalSeconds -lt $Seconds)
    throw "Timeout waiting for $Description."
}

function Get-IisState {
    param($C, [string]$Kind)
    return ((Invoke-CheckedNative $C.Appcmd @('list', $Kind, $C.Domain, '/text:state')) -join '').Trim()
}

function Stop-IisRelease {
    param($C)
    # Capture worker PIDs BEFORE stopping: appcmd can stop listing workers before they exit.
    $workers = @(Invoke-CheckedNative $C.Appcmd @('list', 'wp', "/apppool.name:$($C.Domain)", '/text:WP.NAME'))
    foreach ($kind in @('site', 'apppool')) {
        if ((Get-IisState $C $kind) -ne 'Stopped') {
            Invoke-CheckedNative $C.Appcmd @('stop', $kind, $C.Domain) | Out-Null
        }
        Wait-IisCondition { (Get-IisState $C $kind) -eq 'Stopped' } $C.StopSeconds "$kind stopped"
    }
    Wait-IisCondition {
        $remaining = @(Invoke-CheckedNative $C.Appcmd @('list', 'wp', "/apppool.name:$($C.Domain)", '/text:WP.NAME'))
        if ($remaining.Count) { return $false }
        foreach ($worker in $workers) {
            $idValue = 0
            if (![int]::TryParse([string]$worker, [ref]$idValue)) { throw 'Invalid worker PID from IIS.' }
            $process = $null
            try { $process = [Diagnostics.Process]::GetProcessById($idValue) }
            catch [ArgumentException] { continue } # This PID no longer exists; other errors must fail.
            finally { if ($process) { $process.Dispose() } }
            return $false
        }
        return $true
    } $C.StopSeconds 'worker processes exited'
}

function Start-IisRelease {
    param($C)
    foreach ($kind in @('apppool', 'site')) {
        if ((Get-IisState $C $kind) -ne 'Started') {
            Invoke-CheckedNative $C.Appcmd @('start', $kind, $C.Domain) | Out-Null
        }
        Wait-IisCondition { (Get-IisState $C $kind) -eq 'Started' } $C.StopSeconds "$kind started"
    }
}

function New-HealthRequest {
    param([string]$Url)
    return [Net.HttpWebRequest]::Create($Url)
}

function Test-ExactHealth {
    param([string]$Url, [int]$Milliseconds)
    $response = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $request = New-HealthRequest $Url
        $request.AllowAutoRedirect = $false
        $request.Timeout = $Milliseconds
        $request.ReadWriteTimeout = $Milliseconds
        $request.Proxy = $null
        $request.Method = 'GET'
        $response = $request.GetResponse()
        return ([int]$response.StatusCode -eq 200)
    } catch [Net.WebException] {
        $response = $_.Exception.Response
        return $false
    } finally {
        if ($response) { $response.Close() }
    }
}

function Wait-ReleaseHealth {
    param($C)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $remaining = [int](($C.HealthSeconds - $clock.Elapsed.TotalSeconds) * 1000)
        if ($remaining -le 0) { break }
        if (Test-ExactHealth $C.HealthUrl ([Math]::Min(10000, $remaining))) { return }
        Start-Sleep -Milliseconds 500
    } while ($clock.Elapsed.TotalSeconds -lt $C.HealthSeconds)
    throw 'HTTPS health probe did not return exact HTTP 200 within the deadline.'
}

function Get-FreeBytes {
    param([string]$Path)
    return [long](Get-PSDrive -Name ((Split-Path -Qualifier $Path).TrimEnd(':')) -ErrorAction Stop).Free
}

function Assert-Capacity {
    param($C, [switch]$AfterExtraction)
    $liveBytes = Get-TreeBytes $C.Live
    $preserved = [long]0
    foreach ($name in $C.Keep) { $preserved += Get-TreeBytes (Join-Path $C.Live $name) }
    # Backups can be incompressible: estimate from uncompressed bytes, not archive*3.
    $required = $liveBytes + $preserved
    if (!$AfterExtraction) { $required += $C.SourceBytes + $C.ArchiveBytes }
    $required += [long][Math]::Max(64MB, [Math]::Ceiling($required * 0.1))
    if ((Get-FreeBytes $C.EnvRoot) -lt $required) { throw 'Insufficient free space for stage, backup and preserved data.' }
}

function Assert-IisOwnership {
    param($C)
    $physical = ((Invoke-CheckedNative $C.Appcmd @('list', 'vdir', "$($C.Domain)/", '/text:physicalPath')) -join '').Trim()
    if (!$physical -or [IO.Path]::GetFullPath($physical).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath($C.Live).TrimEnd('\', '/')) {
        throw 'IIS physical path does not match the bounded deployment directory.'
    }
    $pools = @(Invoke-CheckedNative $C.Appcmd @('list', 'app', "/site.name:$($C.Domain)", '/text:applicationPool'))
    if (!$pools.Count -or @($pools | Where-Object { $_ -ne $C.Domain }).Count) { throw 'Site does not exclusively use its named pool.' }
    $apps = @(Invoke-CheckedNative $C.Appcmd @('list', 'app', "/apppool.name:$($C.Domain)", '/text:APP.NAME'))
    if (!$apps.Count -or @($apps | Where-Object { !([string]$_).StartsWith("$($C.Domain)/", [StringComparison]::OrdinalIgnoreCase) }).Count) {
        throw 'App pool is shared with another site.'
    }
    foreach ($kind in @('site', 'apppool')) {
        if ((Get-IisState $C $kind) -ne 'Started') { throw 'Prior site and pool must be Started before deployment.' }
    }
}

function Copy-PreservedChildren {
    param($C)
    foreach ($name in $C.Keep) {
        $from = Join-Path $C.Live $name
        $to = Join-Path $C.Stage $name
        Assert-SafeTree $from
        if (!(Test-Path -LiteralPath $from)) { throw "Required preserved child is missing: $name" }
        Remove-BoundedPath $to $C.Stage $name
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force -ErrorAction Stop
        Assert-SafeTree $to
    }
    # Do not replace the primary assembly with preserved content unnoticed.
    $assembly = Get-Item -LiteralPath (Join-Path $C.Stage $C.Assembly) -ErrorAction Stop
    if ($assembly.PSIsContainer -or $assembly.Length -le 0) { throw 'Staged assembly is not a nonempty file.' }
}

function Set-ReleaseRootAcl {
    param($C)
    Set-Acl -LiteralPath $C.Stage -AclObject (Get-Acl -LiteralPath $C.Live -ErrorAction Stop) -ErrorAction Stop
}

function Assert-ArchiveInventory {
    param($C)
    if ((Get-FileHash -LiteralPath $C.Archive -Algorithm SHA256 -ErrorAction Stop).Hash -ne $C.ArchiveHash) {
        throw 'Transferred archive hash mismatch.'
    }
    $entries = 0
    foreach ($line in (Invoke-CheckedNative $C.SevenZip @('l', '-slt', '-ba', $C.Archive))) {
        if ($line -match '^(Symbolic Link|Hard Link) = ' -or $line -match '^Attributes = .*L') {
            throw 'Archive links are not permitted.'
        }
        if ($line -match '^Path = (.*)$') {
            $relative = $Matches[1]
            if ($relative -match '^[\\/]' -or $relative -match ':') { throw 'Unsafe archive entry.' }
            foreach ($part in ($relative -split '[\\/]')) { Assert-ChildName $part }
            $entries++
        }
    }
    if (!$entries) { throw 'Archive has no safe entries.' }
}

function Rename-Release {
    param([string]$From, [string]$To)
    Assert-SafeTree $From
    if (Test-Path -LiteralPath $To) { throw 'Rename target already exists; refusing overwrite.' }
    Rename-Item -LiteralPath $From -NewName (Split-Path -Leaf $To) -ErrorAction Stop
}

function Assert-LockOwner {
    param($C)
    Assert-SafeTree $C.Lock
    if (!(Test-Path -LiteralPath $C.Lock -PathType Container) -or
        (Get-Content -LiteralPath (Join-Path $C.Lock 'owner') -Raw -ErrorAction Stop) -ne $C.Token) {
        throw 'Site lock ownership lost; manual recovery required.'
    }
}

function Invoke-IisRemote {
    param($C, [ValidateSet('Prepare', 'Deploy', 'Cleanup')][string]$Operation)
    $ErrorActionPreference = 'Stop'
    Assert-SafeTree $C.EnvRoot
    if (!(Test-Path -LiteralPath $C.Live -PathType Container)) {
        # Cleanup after a failed rollback must still work, but never dispose its state.
        if ($Operation -ne 'Cleanup') { throw 'Existing live site directory is required.' }
    }
    if ($Operation -eq 'Prepare') {
        # New-Item without Force is exclusive on the Windows filesystem. Never steal stale locks.
        New-Item -Path $C.Lock -ItemType Directory -ErrorAction Stop | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $C.Lock 'owner') -Value $C.Token -NoNewline -ErrorAction Stop
            Write-Host "Recovery paths: lock=$($C.Lock); stage=$($C.Stage); previous=$($C.Previous); archive=$($C.Archive); backup=$($C.Backup)"
            foreach ($path in @($C.Stage, $C.Previous, $C.Archive, $C.Backup, $C.BackupPending)) {
                if (Test-Path -LiteralPath $path) { throw 'Run-specific state already exists; inspect it rather than deleting it.' }
            }
            Assert-IisOwnership $C
            Assert-Capacity $C
            New-Item -Path $C.Stage -ItemType Directory -ErrorAction Stop | Out-Null
        } catch {
            # No live mutation has occurred. Ownership is needed for outer cleanup.
            throw
        }
        return
    }
    Assert-LockOwner $C
    if ($Operation -eq 'Cleanup') {
        # Stage/previous are handled by the transaction, NOT an outage-shaped fallback.
        $cleanupIssues = New-Object 'Collections.Generic.List[string]'
        foreach ($path in @($C.Archive, $C.BackupPending, $C.Lock)) {
            try { Remove-BoundedPath $path $C.EnvRoot (Split-Path -Leaf $path) }
            catch { $cleanupIssues.Add("Cleanup failed at ${path}: $($_.Exception.Message)") }
        }
        if ($cleanupIssues.Count) { throw ($cleanupIssues -join '; ') }
        return
    }

    $stopAttempted = $false
    $swapAttempted = $false
    $verified = $false
    $recovered = $false
    $failure = $null
    $issues = New-Object 'Collections.Generic.List[string]'
    try {
        Assert-ArchiveInventory $C
        Invoke-CheckedNative $C.SevenZip @('x', $C.Archive, "-o$($C.Stage)", '-y') | Out-Null
        Assert-SafeTree $C.Stage
        $assembly = Get-Item -LiteralPath (Join-Path $C.Stage $C.Assembly) -ErrorAction Stop
        if ($assembly.PSIsContainer -or $assembly.Length -le 0) { throw 'Extraction produced no nonempty expected assembly.' }
        # Fail closed rather than silently deleting server-only IIS configuration/licenses.
        # Nested licenses must be supplied in the payload: keep-list deliberately is NOT a path language.
        foreach ($relative in @('web.config', 'site.lic', 'bin\site.lic')) {
            if ((Test-Path -LiteralPath (Join-Path $C.Live $relative) -PathType Leaf) -and
                !(Test-Path -LiteralPath (Join-Path $C.Stage $relative) -PathType Leaf) -and
                $C.Keep -notcontains ($relative -split '\\')[0]) {
                throw "Release would drop existing server file '$relative'. Supply it in the payload or explicitly preserve its safe direct child."
            }
        }
        Assert-Capacity $C -AfterExtraction
        $stopAttempted = $true
        Stop-IisRelease $C
        # Mutable live data is read only after all workers have exited.
        Assert-Capacity $C -AfterExtraction
        Invoke-CheckedNative $C.SevenZip @('a', '-t7z', $C.BackupPending, (Join-Path $C.Live '*')) | Out-Null
        if (!(Test-Path -LiteralPath $C.BackupPending -PathType Leaf)) { throw 'Backup tool produced no archive.' }
        Invoke-CheckedNative $C.SevenZip @('t', $C.BackupPending) | Out-Null
        Rename-Release $C.BackupPending $C.Backup
        Copy-PreservedChildren $C
        Set-ReleaseRootAcl $C
        $swapAttempted = $true
        Rename-Release $C.Live $C.Previous
        Rename-Release $C.Stage $C.Live
        Start-IisRelease $C
        Wait-ReleaseHealth $C
        $verified = $true
    } catch {
        $failure = $_
        if ($stopAttempted) {
            try {
                # Stop even after partial startup; never rename a directory under running workers.
                Stop-IisRelease $C
                if ($swapAttempted -and (Test-Path -LiteralPath $C.Previous)) {
                    if (Test-Path -LiteralPath $C.Live) {
                        # Stage name is free after the second rename. Retain the failed release there.
                        Rename-Release $C.Live $C.Stage
                    }
                    Rename-Release $C.Previous $C.Live
                }
                if (!(Test-Path -LiteralPath $C.Live -PathType Container)) { throw 'Old live tree unavailable.' }
                Start-IisRelease $C
                Wait-ReleaseHealth $C
                $recovered = $true
                Write-Warning 'Old release and preserved data restored; prior site verified.'
            } catch {
                $issues.Add("Recovery failed: $($_.Exception.Message)")
                Write-Warning "MANUAL RECOVERY REQUIRED. Do not remove lock or release trees. live=$($C.Live); previous=$($C.Previous); stage=$($C.Stage); backup=$($C.Backup)"
            }
        }
    }
    # Previous release is never deleted before health verification. Old preserved data was COPIED.
    if ($verified) {
        try {
            Remove-BoundedPath $C.Previous $C.EnvRoot (Split-Path -Leaf $C.Previous)
            $prefix = "$($C.Domain).backup-"
            $backups = @(Get-ChildItem -LiteralPath $C.EnvRoot -File -Force |
                Where-Object { $_.Name -match ('^' + [regex]::Escape($prefix) + '[1-9][0-9]*-[1-9][0-9]*\.7z$') } |
                Sort-Object LastWriteTimeUtc, Name -Descending)
            foreach ($backup in @($backups | Select-Object -Skip 3)) {
                Remove-BoundedPath $backup.FullName $C.EnvRoot $backup.Name
            }
        } catch { $issues.Add("Verified-release cleanup failed: $($_.Exception.Message)") }
    } elseif (!$stopAttempted -or $recovered) {
        try { Remove-BoundedPath $C.Stage $C.EnvRoot (Split-Path -Leaf $C.Stage) }
        catch { $issues.Add("Stage cleanup failed: $($_.Exception.Message)") }
    }
    # A failed recovery deliberately retains the lock to block further deployments.
    if ($stopAttempted -and !$verified -and !$recovered) {
        $issues.Add('Lock retained: operator must stop IIS, restore previous if present, start and verify prior site, then remove this owned lock.')
    } else {
        try { Invoke-IisRemote $C 'Cleanup' }
        catch { $issues.Add("Remote cleanup failed: $($_.Exception.Message)") }
    }
    if ($failure) { throw "$($failure.Exception.Message) $($issues -join '; ')" }
    if ($issues.Count) { throw ($issues -join '; ') }
    Write-Host "Verified deployment of $($C.Domain). Backup: $($C.Backup)"
}

function New-DeploymentConfig {
    $siteEnv = $env:DEPLOY_SITE_ENV
    $app = $env:DEPLOY_APP_NAME
    $run = $env:DEPLOY_RUN_ID
    if ($siteEnv -cnotin @('alpha', 'dev', 'sandbox')) { throw 'Invalid site-env.' }
    if ($app -cnotin @('api', 'mfa', 'push', 'oidc', 'oidc-client')) { throw 'Invalid app-name.' }
    if ($run -cnotmatch '^[1-9][0-9]*-[1-9][0-9]*$') { throw 'Invalid numeric run-id-attempt.' }
    if ($env:DEPLOY_COMPUTER_NAME -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' -or
        !$env:DEPLOY_USERNAME -or !$env:DEPLOY_PASSWORD) { throw 'Missing or invalid WinRM connection inputs.' }
    $domain = "$app-$siteEnv.surepassid.com"
    $uri = $null
    if (![Uri]::TryCreate($env:DEPLOY_HEALTH_CHECK_URL, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne $domain -or !$uri.IsDefaultPort -or
        $uri.UserInfo -or $uri.Fragment) { throw 'Health URL must use HTTPS on the exact app/environment host, default port, without credentials or fragment.' }
    $assembly = Convert-AssemblyPath $env:DEPLOY_APP_ASSEMBLY
    $keep = @()
    if ($env:DEPLOY_KEEP_LIST) {
        foreach ($name in ($env:DEPLOY_KEEP_LIST -split ',')) {
            $name = $name.Trim()
            Assert-ChildName $name
            if ($keep -contains $name) { throw 'Duplicate keep-list name.' }
            if (($assembly -split '\\')[0] -eq $name) { throw 'keep-list must not overwrite the expected assembly or its parent.' }
            $keep += $name
        }
    }
    $source = $env:DEPLOY_SOURCE_PATH
    if (!$source -or $source -match '(^|[\\/])\.\.?([\\/]|$)' -or $source -match '[*?"<>|]' -or
        $source -notmatch '^[a-zA-Z]:[\\/]' -or $source.Substring(2).Contains(':')) {
        throw 'Source must be an absolute local safe directory path.'
    }
    $source = [IO.Path]::GetFullPath($source).TrimEnd('\', '/')
    if ($source -eq [IO.Path]::GetPathRoot($source).TrimEnd('\', '/') -or
        ($env:GITHUB_WORKSPACE -and $source -eq [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\', '/'))) {
        throw 'Source cannot be drive root or the entire workspace.'
    }
    Assert-SafeTree $source
    if (!(Test-Path -LiteralPath $source -PathType Container)) { throw 'Source directory missing.' }
    $item = Get-Item -LiteralPath (Join-Path $source $assembly) -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0) { throw 'Source assembly must be a nonempty file.' }
    $root = 'E:\iis_sites'
    # The runner need not have the remote E: drive.
    $envRoot = [IO.Path]::Combine($root, $siteEnv)
    $live = [IO.Path]::Combine($envRoot, $domain)
    return [pscustomobject]@{
        Domain = $domain; EnvRoot = $envRoot; Live = $live
        Stage = "$live.staging-$run"; Previous = "$live.previous-$run"
        Archive = "$live.archive-$run.7z"; Backup = "$live.backup-$run.7z"
        BackupPending = "$live.backup-$run.partial.7z"; ArchiveHash = ''
        Lock = "$live.deploy-lock"; Token = [guid]::NewGuid().ToString()
        Assembly = $assembly; Keep = $keep; Source = $source
        SourceBytes = (Get-TreeBytes $source); ArchiveBytes = [long]0
        HealthUrl = $uri.AbsoluteUri; StopSeconds = 180; HealthSeconds = 120
        SevenZip = 'C:\Program Files\7-Zip\7z.exe'; Appcmd = 'C:\Windows\System32\inetsrv\appcmd.exe'
    }
}

function Invoke-Deployment {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Runner requires PowerShell 7.' }
    $ErrorActionPreference = 'Stop'
    $c = New-DeploymentConfig
    $session = $null
    $localArchive = $null
    $localOwned = $false
    $prepared = $false
    $deployAttempted = $false
    $failure = $null
    $issues = New-Object 'Collections.Generic.List[string]'
    # Functions are serialized as code, inputs solely as WinRM argument objects, never script text.
    $helperNames = @('Assert-ChildName', 'Assert-SafeTree', 'Get-TreeBytes', 'Remove-BoundedPath',
        'Invoke-CheckedNative', 'Wait-IisCondition', 'Get-IisState', 'Stop-IisRelease', 'Start-IisRelease',
        'New-HealthRequest', 'Test-ExactHealth', 'Wait-ReleaseHealth', 'Get-FreeBytes', 'Assert-Capacity', 'Assert-IisOwnership',
        'Copy-PreservedChildren', 'Set-ReleaseRootAcl', 'Assert-ArchiveInventory',
        'Rename-Release', 'Assert-LockOwner', 'Invoke-IisRemote')
    $definitions = foreach ($name in $helperNames) {
        "function global:$name {`n$((Get-Item "Function:\$name").Definition)`n}"
    }
    $bootstrap = [scriptblock]::Create($definitions -join "`n")
    try {
        $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
        Assert-SafeTree $temp
        $localArchive = Join-Path $temp "$($c.Domain).archive-$($env:DEPLOY_RUN_ID).$($c.Token).7z"
        if (Test-Path -LiteralPath $localArchive) { throw 'Local run archive already exists; inspect it before retry.' }
        # Reserve ownership before invoking 7zip, so partial archives are cleaned too.
        New-Item -Path $localArchive -ItemType File -ErrorAction Stop | Out-Null
        $localOwned = $true
        Remove-BoundedPath $localArchive $temp (Split-Path -Leaf $localArchive)
        Invoke-CheckedNative $c.SevenZip @('a', '-t7z', $localArchive, (Join-Path $c.Source '*')) | Out-Null
        $c.ArchiveBytes = (Get-Item -LiteralPath $localArchive -ErrorAction Stop).Length
        if ($c.ArchiveBytes -le 0) { throw 'Compression produced an empty archive.' }
        $c.ArchiveHash = (Get-FileHash -LiteralPath $localArchive -Algorithm SHA256 -ErrorAction Stop).Hash
        $credential = New-Object Management.Automation.PSCredential ($env:DEPLOY_USERNAME,
            (ConvertTo-SecureString $env:DEPLOY_PASSWORD -AsPlainText -Force))
        $session = New-PSSession -ComputerName $env:DEPLOY_COMPUTER_NAME -Credential $credential -ErrorAction Stop
        Invoke-Command -Session $session -ScriptBlock $bootstrap -ErrorAction Stop
        # If a response is lost, a created lock may remain: do not guess or steal it.
        Write-Host "On cancellation/WinRM outage inspect $($c.Lock), $($c.Previous), $($c.Stage), $($c.Archive) and $($c.Backup). Stop IIS before any manual restore; verify HTTPS 200 before unlocking."
        Invoke-Command -Session $session -ScriptBlock { param($config) Invoke-IisRemote $config 'Prepare' } -ArgumentList $c -ErrorAction Stop
        $prepared = $true
        Copy-Item -LiteralPath $localArchive -Destination $c.Archive -ToSession $session -ErrorAction Stop
        $deployAttempted = $true
        Invoke-Command -Session $session -ScriptBlock { param($config) Invoke-IisRemote $config 'Deploy' } -ArgumentList $c -ErrorAction Stop
    } catch { $failure = $_ }
    finally {
        if ($session) {
            if (!$deployAttempted) {
                try {
                    # Check the token even if Prepare failed after acquiring the lock.
                    Invoke-Command -Session $session -ScriptBlock {
                        param($config)
                        if (Test-Path -LiteralPath (Join-Path $config.Lock 'owner')) {
                            Assert-LockOwner $config
                            if (Test-Path -LiteralPath $config.Stage) {
                                # Only remove stage if Prepare completed; collision state is not ours.
                                if ($config.Prepared) { Remove-BoundedPath $config.Stage $config.EnvRoot (Split-Path -Leaf $config.Stage) }
                            }
                            if ($config.Prepared) {
                                Invoke-IisRemote $config 'Cleanup'
                            } else {
                                # Prepare may have rejected pre-existing run paths. They are not ours.
                                Remove-BoundedPath $config.Lock $config.EnvRoot (Split-Path -Leaf $config.Lock)
                            }
                        } elseif (Test-Path -LiteralPath $config.Lock) {
                            throw "Lock lacks an owner marker; inspect $($config.Lock) manually before retry."
                        }
                    } -ArgumentList ($c | Select-Object *, @{n='Prepared'; e={$prepared}}) -ErrorAction Stop
                } catch { $issues.Add("Pre-deploy cleanup failed: $($_.Exception.Message)") }
            }
            try { Remove-PSSession -Session $session -ErrorAction Stop }
            catch { $issues.Add("Session cleanup failed: $($_.Exception.Message)") }
        }
        if ($localOwned) {
            try { Remove-BoundedPath $localArchive (Split-Path -Parent $localArchive) (Split-Path -Leaf $localArchive) }
            catch { $issues.Add("Local archive cleanup failed at $localArchive : $($_.Exception.Message)") }
        }
    }
    if ($failure) { throw "$($failure.Exception.Message) $($issues -join '; ')" }
    if ($issues.Count) { throw ($issues -join '; ') }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Deployment }
