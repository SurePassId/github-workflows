# Standalone assertion harness; no package install, WinRM, IIS, 7zip or HTTP access.
# Compatible with PowerShell 5.1 and 7. Entry/transport tests execute only in 7.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deploy-IisSite.ps1')
$script:original = @{}
foreach ($name in @('Invoke-CheckedNative', 'Rename-Release', 'Remove-BoundedPath', 'Copy-PreservedChildren',
    'New-DeploymentConfig', 'New-HealthRequest', 'Set-ReleaseRootAcl', 'Get-FreeBytes')) {
    $script:original[$name] = (Get-Item "Function:\$name").ScriptBlock
}
$script:passed = 0
$script:fixture = $null
$script:events = @()
$script:fault = ''
$script:extraFaults = @()
$script:counts = @{}
$script:siteState = 'Started'
$script:poolState = 'Started'

function Assert-True {
    param($Value, [string]$Message)
    if (!$Value) { throw "ASSERTION: $Message" }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern = '.')
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected failure, not success.'
    Assert-True ($caught.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($caught.Exception.Message)'"
    return $caught.Exception.Message
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { throw "FAIL $Name : $($_.Exception.Message)" }
}
function Hit-Fault {
    param([string]$Name)
    if (!$script:counts.ContainsKey($Name)) { $script:counts[$Name] = 0 }
    $script:counts[$Name]++
    $script:events += $Name
    if ($script:fault -eq $Name -and $script:counts[$Name] -eq 1) { throw "Injected $Name failure." }
    if ($script:extraFaults -contains $Name -and $script:counts[$Name] -eq 1) { throw "Injected $Name recovery failure." }
    if ($script:fault -eq "$Name-always") { throw "Injected $Name persistent failure." }
}
function New-Fixture {
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) ("iis-action-tests-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:fixture -ItemType Directory | Out-Null
    $envRoot = Join-Path $script:fixture 'sandbox'
    $source = Join-Path $script:fixture 'publish'
    $domain = 'api-sandbox.surepassid.com'
    $live = Join-Path $envRoot $domain
    foreach ($path in @($envRoot, $source, $live, "$source\bin", "$source\data", "$live\bin", "$live\data", "$live\data\nested")) {
        New-Item -Path $path -ItemType Directory | Out-Null
    }
    Set-Content -LiteralPath "$source\bin\App.dll" -Value 'new-release'
    Set-Content -LiteralPath "$source\data\mutable.txt" -Value 'wrong-new-data'
    Set-Content -LiteralPath "$live\bin\App.dll" -Value 'old-release'
    Set-Content -LiteralPath "$live\data\mutable.txt" -Value 'old-mutable-data'
    Set-Content -LiteralPath "$live\data\nested\hidden.txt" -Value 'old-hidden-data'
    (Get-Item -LiteralPath "$live\data\nested\hidden.txt").Attributes = [IO.FileAttributes]::Hidden
    $script:c = [pscustomobject]@{
        Domain=$domain; EnvRoot=$envRoot; Live=$live; Source=$source
        Stage="$live.staging-100-1"; Previous="$live.previous-100-1"
        Archive="$live.archive-100-1.7z"; Backup="$live.backup-100-1.7z"
        BackupPending="$live.backup-100-1.partial.7z"
        Lock="$live.deploy-lock"; Token=[guid]::NewGuid().ToString()
        Assembly='bin\App.dll'; Keep=@('data'); SourceBytes=(Get-TreeBytes $source)
        ArchiveBytes=100; ArchiveHash=''; SevenZip='mock-7zip'; Appcmd='mock-appcmd'
        HealthUrl="https://$domain/status"; StopSeconds=1; HealthSeconds=1
    }
    $script:events = @(); $script:counts = @{}; $script:fault = ''; $script:extraFaults = @()
    $script:siteState = 'Started'; $script:poolState = 'Started'
    $script:responseStatus = 200
    $script:freeBytes = [long]10GB
}
function Close-Fixture {
    if ($script:fixture -and (Test-Path -LiteralPath $script:fixture)) {
        & $script:original['Remove-BoundedPath'] $script:fixture ([IO.Path]::GetTempPath()) (Split-Path -Leaf $script:fixture)
    }
    $script:fixture = $null
}
function Assert-OldData {
    param([string]$Path = $script:c.Live)
    Assert-True ((Get-Content -LiteralPath "$Path\bin\App.dll" -Raw).Trim() -eq 'old-release') 'Old release intact.'
    Assert-True ((Get-Content -LiteralPath "$Path\data\mutable.txt" -Raw).Trim() -eq 'old-mutable-data') 'Old mutable data intact.'
    Assert-True ((Get-Content -LiteralPath "$Path\data\nested\hidden.txt" -Raw).Trim() -eq 'old-hidden-data') 'Old nested hidden data intact.'
}
function Prepare-Fixture {
    Invoke-IisRemote $script:c Prepare
    Set-Content -LiteralPath $script:c.Archive -Value 'mock archive'
    $script:c.ArchiveHash = (Get-FileHash -LiteralPath $script:c.Archive -Algorithm SHA256).Hash
}

# Mock native tools, with real filesystem effects confined to the random fixture.
function Invoke-CheckedNative {
    param([string]$Tool, [string[]]$Arguments)
    if ($Tool -eq 'mock-appcmd') {
        $verb = $Arguments[0]; $kind = $Arguments[1]
        if ($verb -eq 'list') {
            Hit-Fault "query-$kind"
            if ($kind -eq 'vdir') {
                if ($script:fault -eq 'physical-trailing-slash') { return "$($script:c.Live)\" }
                return $script:c.Live
            }
            if ($kind -eq 'app') {
                if ($Arguments[-1] -eq '/text:applicationPool') { return $script:c.Domain }
                return "$($script:c.Domain)/"
            }
            if ($kind -eq 'wp') {
                if ($script:fault -eq 'worker-timeout') { return '2147483646' }
                if ($script:fault -eq 'exited-worker' -and $script:poolState -eq 'Started') { return '2147483646' }
                return
            }
            if ($kind -eq 'site') { return $script:siteState }
            if ($kind -eq 'apppool') { return $script:poolState }
            throw 'Unexpected IIS query.'
        }
        Hit-Fault "$verb-$kind"
        $state = if ($verb -eq 'stop') { 'Stopped' } else { 'Started' }
        if ($kind -eq 'site') { $script:siteState = $state } else { $script:poolState = $state }
        if ($script:fault -eq 'partial-stop' -and $verb -eq 'stop' -and $kind -eq 'site' -and $script:counts['stop-site'] -eq 1) {
            throw 'Injected stop failure after mutation.'
        }
        return
    }
    Assert-True ($Tool -eq 'mock-7zip') 'Unexpected native tool would be unsafe.'
    switch ($Arguments[0]) {
        'l' {
            Hit-Fault 'inventory'
            if ($script:fault -eq 'archive-traversal') { return 'Path = ..\escape.txt' }
            if ($script:fault -eq 'archive-link') { return @('Path = bin\App.dll', 'Symbolic Link = ..\outside') }
            return @('Path = bin\App.dll', 'Path = data\mutable.txt')
        }
        'x' {
            Hit-Fault 'extract'
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath "$($script:c.Source)\bin" -Destination $script:c.Stage -Recurse -Force
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath "$($script:c.Source)\data" -Destination $script:c.Stage -Recurse -Force
            if ($script:fault -eq 'missing-extracted-assembly') {
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath "$($script:c.Stage)\bin\App.dll"
            }
            return
        }
        'a' {
            if ($Arguments[2] -eq $script:c.BackupPending) {
                Assert-True ($script:siteState -eq 'Stopped' -and $script:poolState -eq 'Stopped') 'Backup only after stop.'
                Hit-Fault 'backup'
                Set-Content -LiteralPath $script:c.BackupPending -Value 'verified backup'
            } else {
                Hit-Fault 'compress'
                Set-Content -LiteralPath $Arguments[2] -Value 'mock archive'
            }
            return
        }
        't' { Hit-Fault 'backup-test'; return }
        default { throw 'Unexpected 7zip command.' }
    }
}
function Get-FreeBytes {
    param([string]$Path)
    Hit-Fault 'space'
    if ($script:fault -eq 'space-after-stop' -and $script:siteState -eq 'Stopped') { return 0 }
    return $script:freeBytes
}
function Set-ReleaseRootAcl {
    param($C)
    Hit-Fault 'acl'
    & $script:original['Set-ReleaseRootAcl'] $C
}
function Rename-Release {
    param([string]$From, [string]$To)
    $point = 'rename-backup'
    if ($From -eq $script:c.Live -and $To -eq $script:c.Previous) { $point = 'rename-old' }
    elseif ($From -eq $script:c.Stage -and $To -eq $script:c.Live) { $point = 'rename-new' }
    elseif ($From -eq $script:c.Live -and $To -eq $script:c.Stage) { $point = 'rename-failed' }
    elseif ($From -eq $script:c.Previous -and $To -eq $script:c.Live) { $point = 'rename-restore' }
    Hit-Fault $point
    & $script:original['Rename-Release'] $From $To
    if ($script:fault -eq "$point-after") { throw "Injected $point failure after mutation." }
}
function Remove-BoundedPath {
    param([string]$Path, [string]$Parent, [string]$Name)
    $point = 'remove-other'
    if ($Path -eq $script:c.Previous) { $point = 'remove-previous' }
    elseif ($Path -eq $script:c.Stage) { $point = 'remove-stage' }
    elseif ($Path -eq $script:c.Archive) { $point = 'remove-archive' }
    elseif ($Path -eq $script:c.Lock) { $point = 'remove-lock' }
    elseif ($Path -like '*.backup-*.7z') { $point = 'remove-backup' }
    Hit-Fault $point
    & $script:original['Remove-BoundedPath'] $Path $Parent $Name
}
function Copy-PreservedChildren {
    param($C)
    Assert-True ($script:siteState -eq 'Stopped' -and $script:poolState -eq 'Stopped') 'Preserve only after stop.'
    Hit-Fault 'preserve'
    & $script:original['Copy-PreservedChildren'] $C
    Assert-OldData
    if ($script:fault -eq 'preserve-after') { throw 'Injected preserve failure after copy.' }
}
function New-HealthRequest {
    param([string]$Url)
    # Actual Test-ExactHealth sets flags on this mock; GetResponse verifies no redirect following.
    $request = [pscustomobject]@{ AllowAutoRedirect=$true; Timeout=0; ReadWriteTimeout=0; Proxy='default'; Method='' }
    $request | Add-Member ScriptMethod GetResponse {
        Assert-True (!$this.AllowAutoRedirect) 'HTTP redirects must never be followed.'
        Assert-True ($this.Timeout -gt 0 -and $this.Timeout -le 10000) 'Bounded HTTP request.'
        Hit-Fault 'health-request'
        $isOld = (Test-Path -LiteralPath "$($script:c.Live)\bin\App.dll") -and
            ((Get-Content -LiteralPath "$($script:c.Live)\bin\App.dll" -Raw).Trim() -eq 'old-release')
        $code = $script:responseStatus
        if (!$isOld -and $script:fault -eq 'health-new-redirect') { $code = 302 }
        if (!$isOld -and $script:fault -eq 'health-new-503') { $code = 503 }
        if ($script:fault -eq 'health-always-503') { $code = 503 }
        $response = [pscustomobject]@{ StatusCode=$code }
        $response | Add-Member ScriptMethod Close { $script:events += 'response-disposed' }
        return $response
    }
    return $request
}

try {
    Test-Case 'exact 200, response disposal, redirects/403/500/503 rejected without body access' {
        New-Fixture
        foreach ($status in @(200, 301, 302, 307, 308, 403, 500, 503)) {
            $script:responseStatus = $status
            Assert-True ((Test-ExactHealth $script:c.HealthUrl 1000) -eq ($status -eq 200)) "Exact status $status."
        }
        Assert-True (@($script:events | Where-Object { $_ -eq 'response-disposed' }).Count -eq 8) 'All responses disposed.'
        Close-Fixture
    }
    Test-Case 'native nonzero fails, stderr/body not included; successful stdout is available for IIS queries' {
        $tool = (Get-Command powershell.exe).Source
        $message = Assert-Throws { & $script:original['Invoke-CheckedNative'] $tool @('-NoProfile', '-Command', 'Write-Output "PRIVATE-BODY"; exit 9') } 'exit 9'
        Assert-True ($message -notmatch 'PRIVATE-BODY') 'Native body not disclosed.'
        $value = & $script:original['Invoke-CheckedNative'] $tool @('-NoProfile', '-Command', 'Write-Output Started; exit 0')
        Assert-True ($value -eq 'Started') 'Native stdout captured.'
        Assert-Throws { & $script:original['Invoke-CheckedNative'] 'Z:\missing-native.exe' @() } | Out-Null
    }
    Test-Case 'safe relative assembly paths and rejected traversal, ADS, UNC, device names' {
        Assert-True ((Convert-AssemblyPath '\bin\App.dll') -eq 'bin\App.dll') 'Leading backslash trimmed.'
        Assert-True ((Convert-AssemblyPath '/bin/App.dll') -eq 'bin\App.dll') 'Leading forward slash trimmed.'
        foreach ($bad in @('..\App.dll', 'bin\..\App.dll', 'C:\bin\App.dll', '\\server\share', 'bin\\App.dll',
            'bin\App.dll:stream', '.', 'bin\CON.dll', 'bin\App.dll ', 'bin\*.dll', 'bin/./App.dll')) {
            Assert-Throws { Convert-AssemblyPath $bad } | Out-Null
        }
        foreach ($bad in @('', '.', '..', 'data\child', 'data/child', 'CON', 'x:', 'data.')) {
            Assert-Throws { Assert-ChildName $bad } | Out-Null
        }
    }
    Test-Case 'bounded deletion refuses parent/root/sibling; junction tree and ancestor rejected' {
        New-Fixture
        Assert-Throws { & $script:original['Remove-BoundedPath'] $script:c.EnvRoot $script:c.EnvRoot 'data' } | Out-Null
        Assert-Throws { & $script:original['Remove-BoundedPath'] $script:c.Live $script:c.Stage $script:c.Domain } | Out-Null
        $junction = Join-Path $script:c.Source 'junction'
        New-Item -Path $junction -ItemType Junction -Target $script:c.Live | Out-Null
        Assert-Throws { Assert-SafeTree $script:c.Source } 'Reparse' | Out-Null
        Assert-Throws { Assert-SafeTree "$junction\data" } 'Reparse' | Out-Null
        # Unlink the junction itself, never recurse into its target.
        [IO.Directory]::Delete($junction)
        Assert-OldData
        Close-Fixture
    }
    Test-Case 'environment contract rejects source/assembly/URL/keep/run/env/app defects before connecting' {
        New-Fixture
        $env:DEPLOY_COMPUTER_NAME='fixture'; $env:DEPLOY_USERNAME='fixture'; $env:DEPLOY_PASSWORD='not-a-secret'
        $env:DEPLOY_SITE_ENV='sandbox'; $env:DEPLOY_APP_NAME='api'; $env:DEPLOY_RUN_ID='100-1'
        $env:DEPLOY_SOURCE_PATH=$script:c.Source; $env:DEPLOY_APP_ASSEMBLY='\bin\App.dll'
        $env:DEPLOY_KEEP_LIST='data'; $env:DEPLOY_HEALTH_CHECK_URL=$script:c.HealthUrl
        $valid = & $script:original['New-DeploymentConfig']
        Assert-True ($valid.Assembly -eq 'bin\App.dll' -and $valid.Keep[0] -eq 'data') 'Valid contract.'
        $cases = @{
            DEPLOY_HEALTH_CHECK_URL=@('http://api-sandbox.surepassid.com/status', 'https://api-dev.surepassid.com/status',
                'https://api-sandbox.surepassid.com.evil/status', 'https://user:password@api-sandbox.surepassid.com/status',
                'https://api-sandbox.surepassid.com:444/status', 'https://api-sandbox.surepassid.com/status#x')
            DEPLOY_RUN_ID=@('100', '../1', '0-1', '100-0', '100-1-x')
            DEPLOY_KEEP_LIST=@('..', 'data/child', 'bin\site.lic', 'data,,other', 'data,DATA', 'bin')
            DEPLOY_APP_ASSEMBLY=@('bin\missing.dll', 'bin\..\App.dll')
            DEPLOY_SOURCE_PATH=@("$($script:c.Source)\..\publish", $script:c.EnvRoot, 'C:\', 'C:relative', 'relative')
            DEPLOY_SITE_ENV=@('production', 'SANDBOX'); DEPLOY_APP_NAME=@('unknown', 'API')
        }
        foreach ($key in $cases.Keys) {
            $saved = [Environment]::GetEnvironmentVariable($key)
            foreach ($bad in $cases[$key]) {
                [Environment]::SetEnvironmentVariable($key, $bad)
                Assert-Throws { & $script:original['New-DeploymentConfig'] } | Out-Null
            }
            [Environment]::SetEnvironmentVariable($key, $saved)
        }
        $env:GITHUB_WORKSPACE=$script:c.Source
        Assert-Throws { & $script:original['New-DeploymentConfig'] } 'workspace' | Out-Null
        $env:GITHUB_WORKSPACE=$null
        Close-Fixture
    }
    Test-Case 'successful swap preserves old mutable/hidden files, root ACL, and only last 3 complete backups' {
        New-Fixture
        foreach ($n in 1..4) {
            $path = "$($script:c.Live).backup-$n-1.7z"
            Set-Content -LiteralPath $path -Value "old backup $n"
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-$n)
        }
        $liveAcl = Get-Acl -LiteralPath $script:c.Live
        $rule = New-Object Security.AccessControl.FileSystemAccessRule (
            (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-568'),
            'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $liveAcl.AddAccessRule($rule)
        Set-Acl -LiteralPath $script:c.Live -AclObject $liveAcl
        $acl = (Get-Acl -LiteralPath $script:c.Live).Sddl
        Prepare-Fixture
        Invoke-IisRemote $script:c Deploy
        Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\bin\App.dll" -Raw).Trim() -eq 'new-release') 'New release live.'
        Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\data\mutable.txt" -Raw).Trim() -eq 'old-mutable-data') 'Preserved live data copied.'
        Assert-True (Test-Path -LiteralPath "$($script:c.Live)\data\nested\hidden.txt") 'Hidden data copied.'
        # Windows may set the informational AutoInherited bit when applying identical rules.
        $actualAcl = (Get-Acl -LiteralPath $script:c.Live).Sddl -replace 'D:(P?)AI', 'D:$1'
        Assert-True ($actualAcl -eq ($acl -replace 'D:(P?)AI', 'D:$1')) 'Root ACL including explicit IIS group rule preserved.'
        Assert-True (!(Test-Path -LiteralPath $script:c.Previous)) 'Previous removed only after health.'
        Assert-True (!(Test-Path -LiteralPath $script:c.Archive) -and !(Test-Path -LiteralPath $script:c.Lock)) 'Archive/lock cleaned.'
        $backups = @(Get-ChildItem -LiteralPath $script:c.EnvRoot -Filter '*.backup-*.7z')
        Assert-True ($backups.Count -eq 3) 'Exactly last 3 backups.'
        Assert-True ([array]::IndexOf($script:events, 'health-request') -lt [array]::IndexOf($script:events, 'remove-previous')) 'Health before previous deletion.'
        Close-Fixture
    }
    foreach ($faultName in @('inventory', 'archive-traversal', 'archive-link', 'extract', 'missing-extracted-assembly')) {
        Test-Case "pre-stop $faultName failure never changes old release or IIS" {
            New-Fixture; Prepare-Fixture; $script:fault=$faultName
            Assert-Throws { Invoke-IisRemote $script:c Deploy } | Out-Null
            Assert-OldData
            Assert-True ($script:siteState -eq 'Started' -and $script:poolState -eq 'Started') 'IIS remains started.'
            Assert-True (!($script:events -contains 'stop-site')) 'No IIS stop.'
            Assert-True (!(Test-Path -LiteralPath $script:c.Lock)) 'Lock cleaned.'
            Close-Fixture
        }
    }
    foreach ($faultName in @('partial-stop', 'stop-apppool', 'backup', 'backup-test', 'rename-backup',
        'space-after-stop', 'preserve', 'preserve-after', 'acl', 'rename-old', 'rename-old-after',
        'rename-new', 'rename-new-after', 'start-apppool', 'start-site', 'health-new-redirect', 'health-new-503')) {
        Test-Case "$faultName failure rolls back old release AND preserved files, never returns success" {
            New-Fixture; Prepare-Fixture; $script:fault=$faultName
            Assert-Throws { Invoke-IisRemote $script:c Deploy } | Out-Null
            Assert-OldData
            Assert-True ($script:siteState -eq 'Started' -and $script:poolState -eq 'Started') 'Prior site restarted.'
            Assert-True (!(Test-Path -LiteralPath $script:c.Previous)) 'Old tree is live.'
            Assert-True (!(Test-Path -LiteralPath $script:c.Lock)) 'Recovered lock cleaned.'
            Close-Fixture
        }
    }
    Test-Case 'capacity uses uncompressed bytes and aborts before stop, not compressed size times 3' {
        New-Fixture
        $script:c.SourceBytes=2GB; $script:c.ArchiveBytes=100; $script:freeBytes=1GB
        Assert-Throws { Invoke-IisRemote $script:c Prepare } 'Insufficient' | Out-Null
        Assert-OldData
        Assert-True (!($script:events -contains 'stop-site')) 'No stop on insufficient space.'
        Invoke-IisRemote $script:c Cleanup
        Close-Fixture
    }
    foreach ($fixtureVariant in @('physical-trailing-slash', 'exited-worker')) {
        Test-Case "$fixtureVariant supports canonical IIS paths and waits for captured workers to exit" {
            New-Fixture; $script:fault=$fixtureVariant
            Prepare-Fixture
            Invoke-IisRemote $script:c Deploy
            Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\bin\App.dll" -Raw).Trim() -eq 'new-release') 'New release verified.'
            Close-Fixture
        }
    }
    Test-Case 'missing preserved file fails safely, without deleting original data' {
        New-Fixture; $script:c.Keep=@('missing'); Prepare-Fixture
        Assert-Throws { Invoke-IisRemote $script:c Deploy } 'preserved child' | Out-Null
        Assert-OldData
        Close-Fixture
    }
    foreach ($serverFile in @('web.config', 'site.lic', 'bin\site.lic')) {
        Test-Case "missing staged/unpreserved $serverFile fails before stop without dropping server configuration" {
            New-Fixture
            Set-Content -LiteralPath (Join-Path $script:c.Live $serverFile) -Value 'server-only-config-or-license'
            Prepare-Fixture
            Assert-Throws { Invoke-IisRemote $script:c Deploy } 'would drop existing server file' | Out-Null
            Assert-OldData
            Assert-True ((Get-Content -LiteralPath (Join-Path $script:c.Live $serverFile) -Raw).Trim() -eq 'server-only-config-or-license') 'Server file retained.'
            Assert-True (!($script:events -contains 'stop-site')) 'No stop.'
            Close-Fixture
        }
    }
    Test-Case 'direct-child web.config preservation overwrites existing staged config but never moves old config' {
        New-Fixture
        $script:c.Keep=@('data','web.config')
        Set-Content -LiteralPath "$($script:c.Live)\web.config" -Value 'old-server-config'
        Prepare-Fixture
        # Native mock only extracts bin and data; this file simulates an already-staged config.
        Set-Content -LiteralPath "$($script:c.Stage)\web.config" -Value 'new-payload-config'
        Invoke-IisRemote $script:c Deploy
        Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\web.config" -Raw).Trim() -eq 'old-server-config') 'Explicit keep overwrites payload config with old config.'
        Close-Fixture
    }
    Test-Case 'direct-child web.config preservation permits a payload lacking root web.config' {
        New-Fixture
        $script:c.Keep=@('data','web.config')
        Set-Content -LiteralPath "$($script:c.Live)\web.config" -Value 'old-server-config'
        Prepare-Fixture
        Invoke-IisRemote $script:c Deploy
        Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\web.config" -Raw).Trim() -eq 'old-server-config') 'Server-only config copied into new release.'
        Close-Fixture
    }
    Test-Case 'health rollback restores old server-only config and nested license, not just assemblies' {
        New-Fixture
        $script:c.Keep=@('data','web.config')
        Set-Content -LiteralPath "$($script:c.Live)\web.config" -Value 'old-server-config'
        Set-Content -LiteralPath "$($script:c.Live)\bin\site.lic" -Value 'old-server-license'
        Set-Content -LiteralPath "$($script:c.Source)\bin\site.lic" -Value 'new-payload-license'
        Prepare-Fixture; $script:fault='health-new-redirect'
        Assert-Throws { Invoke-IisRemote $script:c Deploy } 'HTTPS health probe' | Out-Null
        Assert-OldData
        Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\web.config" -Raw).Trim() -eq 'old-server-config') 'Old web.config restored.'
        Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\bin\site.lic" -Raw).Trim() -eq 'old-server-license') 'Old nested license restored.'
        Close-Fixture
    }
    Test-Case 'site lock excludes concurrent repositories and abandoned state is not deleted' {
        New-Fixture; Prepare-Fixture
        $second = $script:c | Select-Object *
        $second.Token=[guid]::NewGuid().ToString()
        Assert-Throws { Invoke-IisRemote $second Prepare } | Out-Null
        Assert-Throws { Invoke-IisRemote $second Cleanup } 'ownership' | Out-Null
        Assert-True ((Get-Content -LiteralPath "$($script:c.Lock)\owner" -Raw) -eq $script:c.Token) 'Owner unchanged.'
        Invoke-IisRemote $script:c Cleanup
        Set-Content -LiteralPath "$($script:c.Stage)\abandoned" -Value 'do not delete'
        Assert-Throws { Invoke-IisRemote $script:c Prepare } 'already exists' | Out-Null
        Assert-True (Test-Path -LiteralPath "$($script:c.Stage)\abandoned") 'Abandoned stage retained.'
        Invoke-IisRemote $script:c Cleanup
        Close-Fixture
    }
    foreach ($faultName in @('stop-site-always', 'worker-timeout', 'health-always-503')) {
        Test-Case "$faultName recovery failure explicitly retains old data and recovery lock" {
            New-Fixture; Prepare-Fixture; $script:fault=$faultName
            $message = Assert-Throws { Invoke-IisRemote $script:c Deploy } 'Recovery failed'
            Assert-True ($message -match 'Lock retained') 'Actionable recovery failure.'
            if (Test-Path -LiteralPath $script:c.Previous) { Assert-OldData $script:c.Previous } else { Assert-OldData }
            Assert-True (Test-Path -LiteralPath $script:c.Lock) 'Recovery lock retained.'
            Close-Fixture
        }
    }
        foreach ($recoveryFault in @('rename-failed', 'rename-restore')) {
            Test-Case "$recoveryFault failure keeps the only old recovery copy and lock" {
                New-Fixture; Prepare-Fixture
                $script:fault='health-new-503'; $script:extraFaults=@($recoveryFault)
                $message=Assert-Throws { Invoke-IisRemote $script:c Deploy } 'Recovery failed'
                Assert-True ($message -match 'HTTPS health probe' -and $message -match $recoveryFault) 'Original and recovery failures retained.'
                Assert-OldData $script:c.Previous
                Assert-True (Test-Path -LiteralPath $script:c.Lock) 'Lock blocks another deploy.'
                Assert-True (Test-Path -LiteralPath $script:c.Archive) 'Remote archive retained for diagnosis.'
                Close-Fixture
            }
        }
        Test-Case 'native restart failure during both startup and recovery is never discarded' {
            New-Fixture; Prepare-Fixture; $script:fault='start-site-always'
            $message=Assert-Throws { Invoke-IisRemote $script:c Deploy } 'Recovery failed'
            Assert-True ($message -match 'start-site persistent failure') 'Native restart failure surfaced.'
            Assert-OldData
            Assert-True (Test-Path -LiteralPath $script:c.Lock) 'Recovery lock retained.'
            Close-Fixture
        }
        Test-Case 'transferred archive integrity mismatch fails before extraction or stop' {
            New-Fixture; Prepare-Fixture
            Set-Content -LiteralPath $script:c.Archive -Value 'tampered archive'
            Assert-Throws { Invoke-IisRemote $script:c Deploy } 'hash mismatch' | Out-Null
            Assert-OldData
            Assert-True (!($script:events -contains 'extract') -and !($script:events -contains 'stop-site')) 'No unsafe extraction or stop.'
            Close-Fixture
        }
    foreach ($faultName in @('remove-previous', 'remove-archive', 'remove-lock', 'remove-backup')) {
        Test-Case "$faultName cleanup failure is failure, not false success" {
            New-Fixture
            if ($faultName -eq 'remove-backup') {
                foreach ($n in 1..4) { Set-Content -LiteralPath "$($script:c.Live).backup-$n-1.7z" -Value 'backup' }
            }
            Prepare-Fixture; $script:fault=$faultName
            Assert-Throws { Invoke-IisRemote $script:c Deploy } 'cleanup failed' | Out-Null
            Assert-True ((Get-Content -LiteralPath "$($script:c.Live)\data\mutable.txt" -Raw).Trim() -eq 'old-mutable-data') 'Preserved data remains on verified release.'
            Close-Fixture
        }
    }
    Test-Case 'original extraction error survives additional stage cleanup error' {
        New-Fixture; Prepare-Fixture
        # Arrange both faults by wrapping just the extraction command.
        $nativeMock = (Get-Item Function:\Invoke-CheckedNative).ScriptBlock
        function Invoke-CheckedNative {
            param($Tool, $Arguments)
            if ($Arguments[0] -eq 'x') { $script:fault='remove-stage'; throw 'Original extraction failure.' }
            & $nativeMock $Tool $Arguments
        }
        $message=Assert-Throws { Invoke-IisRemote $script:c Deploy } 'Original extraction failure'
        Assert-True ($message -match 'Stage cleanup failed') 'Secondary cleanup error included.'
        Set-Item Function:\Invoke-CheckedNative $nativeMock
        Assert-OldData
        Close-Fixture
    }

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # Mock transport as well. Even entry-point tests cannot create a real PSSession.
        function New-DeploymentConfig { return $script:c }
        function New-PSSession {
            param($ComputerName, $Credential, $ErrorAction)
            Hit-Fault 'session-open'
            return [pscustomobject]@{ Fixture=$true }
        }
        function Invoke-Command {
            param($Session, $ScriptBlock, $ArgumentList, $ErrorAction)
            Assert-True ($Session.Fixture) 'Only fixture session accepted.'
            if ($ScriptBlock.ToString() -match '^function global:') { Hit-Fault 'bootstrap'; return }
            if ($script:fault -eq 'remote-outage' -and $ScriptBlock.ToString() -match "'Deploy'") {
                throw 'Mock WinRM outage.'
            }
            & $ScriptBlock @ArgumentList
        }
        function Remove-PSSession {
            param($Session, $ErrorAction)
            Hit-Fault 'session-close'
        }
        function Copy-Item {
            param($LiteralPath, $Destination, $ToSession, [switch]$Recurse, [switch]$Force, $ErrorAction)
            if ($ToSession) { Hit-Fault 'transfer' }
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse -Force:$Force
        }
        foreach ($faultName in @('', 'compress', 'session-open', 'bootstrap', 'transfer', 'remote-outage', 'session-close')) {
            Test-Case "mocked entry/WinRM '$faultName' closes sessions, cleans owned local archive, no false success" {
                New-Fixture
                $env:RUNNER_TEMP=$script:fixture
                $env:DEPLOY_RUN_ID='100-1'
                $script:fault=$faultName
                if (!$faultName) { Invoke-Deployment } else { Assert-Throws { Invoke-Deployment } | Out-Null }
                Assert-True (@(Get-ChildItem -LiteralPath $script:fixture -Filter "$($script:c.Domain).archive-100-1.*.7z").Count -eq 0) 'Local archive cleaned.'
                if ($faultName -notin @('compress', 'session-open')) {
                    Assert-True ($script:events -contains 'session-close') 'Session cleanup attempted.'
                }
                if ($faultName -eq 'remote-outage') {
                    Assert-OldData
                    Assert-True (Test-Path -LiteralPath $script:c.Lock) 'Outage retains remote recovery paths.'
                }
                Close-Fixture
            }
        }
        Test-Case 'entry prepare collision never deletes existing archive/previous/stage' {
            New-Fixture; $env:RUNNER_TEMP=$script:fixture
            Set-Content -LiteralPath $script:c.Archive -Value 'abandoned archive'
            Assert-Throws { Invoke-Deployment } 'already exists' | Out-Null
            Assert-True ((Get-Content -LiteralPath $script:c.Archive -Raw).Trim() -eq 'abandoned archive') 'Collision archive intact.'
            Assert-OldData
            Close-Fixture
        }
        Test-Case 'owned local cleanup error does not obscure original transport failure' {
            New-Fixture; $env:RUNNER_TEMP=$script:fixture
            $script:fault='transfer'
            $removeMock=(Get-Item Function:\Remove-BoundedPath).ScriptBlock
            function Remove-BoundedPath {
                param($Path, $Parent, $Name)
                if ($Parent -eq $script:fixture -and $script:events -contains 'transfer') { throw 'Injected local archive removal failure.' }
                & $removeMock $Path $Parent $Name
            }
            $message=Assert-Throws { Invoke-Deployment } 'transfer failure'
            Assert-True ($message -match 'Local archive cleanup failed at') 'Original error plus actionable retained archive path.'
            Set-Item Function:\Remove-BoundedPath $removeMock
            Assert-OldData
            Close-Fixture
        }
    }
    Test-Case 'all action inputs use env, health required, no input expressions in script text' {
        $yaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'action.yaml') -Raw
        $runText = ($yaml -split 'run: \|')[1]
        Assert-True ($runText -notmatch '\$\{\{') 'No expressions interpolated in run text.'
        foreach ($name in @('computer-name','username','password','site-env','app-name','source-path','app-assembly','run-id','keep-list','health-check-url')) {
            Assert-True ($yaml.Contains(('${{ inputs.' + $name + ' }}'))) "Input $name in env."
        }
        Assert-True ($yaml -match '(?s)health-check-url:.*?required: true') 'Health URL required.'
    }
    Write-Host "RESULT: $script:passed tests passed; no remote/native IIS/HTTP actions performed."
} finally {
    Close-Fixture
}
<#
PASS
Findings: none.
#>
<#
Local execution record (2026-11-04):
Scope: action.yaml, Deploy-IisSite.ps1 and this isolated test harness only.
Original action inspected at a255bc2af00999cf88b22dd93c33a2820b8fd5b3.
Decomposition: atomic action transaction + related tests; no scenario skill root or
task.md/progress-details.md paths supplied. No workflow/caller/snapshot edits.
From repos/github-workflows:
  pwsh -NoProfile -File .github/actions/deploy-iis-site/Deploy-IisSite.Tests.ps1
  PASS: 61 cases, exit 0 (runner-entry tests included).
  powershell -NoProfile -File .github/actions/deploy-iis-site/Deploy-IisSite.Tests.ps1
  PASS: 52 cases, exit 0 (remote-compatible helpers; runner requires PS7).
Both scripts parsed with the PowerShell language parser; no syntax errors.
IIS, 7zip, WinRM and HTTP are mocked. Native-wrapper checks use only a local
PowerShell child process. No live sites, deployments, credentials or response bodies read.
Latest additions: reject dropping existing web.config/site.lic/bin/site.lic before
stop; explicit direct-child keep overwrites staged files; verify rollback restores
old config/licenses; accept trailing IIS physical path separator; captured PID exit.
Cancellation/WinRM outage can prevent finally: inspect the logged owned lock,
stage, previous, backup and archive. Never delete previous/old live blindly.
On failed recovery the old tree and remote recovery artifacts/lock are retained.
An operator must stop IIS/workers, restore the old tree if necessary, start and
verify the prior site's HTTPS exact200, and only then clear the owned lock/state.
Nonhealthy prior baseline cannot be declared verified; recovery remains a failure.
Complete backups prune to last3 only after verified deployment; old naming schemes,
abandoned state, failed recovery artifacts are deliberately not indiscriminately deleted.
No live/actual appcmd/7zip/WinRM qualification claimed; remoting permission and MFA
published configuration are external rollout blockers, not corrected by this action.
#>
<#
Integrity review round 2 (2026-11-04):
PASS
Open findings: none.
Scope: bounded final re-review of material additions since the prior PASS in this
file, limited to action.yaml, Deploy-IisSite.ps1, and Deploy-IisSite.Tests.ps1.
#>
