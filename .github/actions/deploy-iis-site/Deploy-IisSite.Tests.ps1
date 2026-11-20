[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
Add-Type -TypeDefinition @'
public class SandboxTransportTestStream : System.IO.MemoryStream {
    public long LengthOverride = -1;
    public bool StopEarly;
    public bool FailRead;
    public override long Length {
        get { return LengthOverride >= 0 ? LengthOverride : base.Length; }
    }
    public override int Read(byte[] buffer, int offset, int count) {
        if (FailRead) { throw new System.IO.IOException("Package read fault."); }
        if (StopEarly && Position >= 196608) { return 0; }
        return base.Read(buffer, offset, count);
    }
}
'@
. (Join-Path $PSScriptRoot 'Deploy-IisSite.ps1')

$script:passed = 0
$script:fixture = $null
$script:package = $null
$script:remote = $null
$savedEnvironment = @{}
$environmentNames = @('COMPUTERNAME', 'DEPLOY_COMPUTER_NAME', 'DEPLOY_USERNAME', 'DEPLOY_PASSWORD',
    'DEPLOY_SITE_ENV', 'DEPLOY_APP_NAME', 'DEPLOY_RUN_ID', 'DEPLOY_SOURCE_PATH', 'DEPLOY_APP_ASSEMBLY',
    'DEPLOY_KEEP_LIST', 'DEPLOY_HEALTH_CHECK_URL', 'RUNNER_TEMP', 'GITHUB_WORKSPACE', 'DEPLOY_UPLOAD_ONLY')
foreach ($environmentName in $environmentNames) {
    $savedEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
}
$originalRemoveArchive = (Get-Item Function:\Remove-OwnedArchive).ScriptBlock

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (!$Value) {
        throw "ASSERTION: $Message"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $caught = $null
    try {
        & $Body | Out-Null
    } catch {
        $caught = $_
    }
    Assert-True ($null -ne $caught) 'Expected failure.'
    Assert-True ($caught.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($caught.Exception.Message)'."
    return $caught.Exception.Message
}

function Close-Fixture {
    foreach ($stream in @($script:package, $script:remote)) {
        if ($stream) {
            $stream.Dispose()
        }
    }
    $script:package = $null
    $script:remote = $null
    if ($script:fixture -and (Test-Path -LiteralPath $script:fixture)) {
        $expectedParent = [IO.Path]::GetTempPath().TrimEnd('\')
        Assert-True ([IO.Path]::GetDirectoryName($script:fixture) -ieq $expectedParent) 'Bounded test fixture parent.'
        Assert-True ([IO.Path]::GetFileName($script:fixture) -cmatch '^sandbox-transport-tests-[a-f0-9]{32}$') 'Bounded test fixture name.'
        Remove-Item -LiteralPath $script:fixture -Recurse -Force
    }
    $script:fixture = $null
    Set-Item Function:\Remove-OwnedArchive $originalRemoveArchive
}

function New-Fixture {
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) ('sandbox-transport-tests-' + [guid]::NewGuid().ToString('N'))
    $source = Join-Path $script:fixture 'publish'
    $null = New-Item -ItemType Directory -Path "$source\bin", "$source\empty", "$source\nested"
    $payload = [byte[]]::new(450000)
    [Random]::new(42).NextBytes($payload)
    [IO.File]::WriteAllBytes("$source\bin\App.dll", $payload)
    Set-Content -LiteralPath "$source\web.config" -Value '<configuration />'
    Set-Content -LiteralPath "$source\nested\.hidden" -Value 'hidden-payload'
    (Get-Item -LiteralPath "$source\nested\.hidden" -Force).Attributes = [IO.FileAttributes]::Hidden
    $env:COMPUTERNAME = 'GH-RUNNER-WIN'
    $env:DEPLOY_COMPUTER_NAME = 'sandbox-app'
    $env:DEPLOY_USERNAME = 'SANDBOX-APP\github-deploy'
    $env:DEPLOY_PASSWORD = 'isolated-test-value'
    $env:DEPLOY_SITE_ENV = 'sandbox'
    $env:DEPLOY_APP_NAME = 'api'
    $env:DEPLOY_RUN_ID = '100-1'
    $env:DEPLOY_SOURCE_PATH = $source
    $env:DEPLOY_APP_ASSEMBLY = '\bin\App.dll'
    $env:DEPLOY_KEEP_LIST = ''
    $env:DEPLOY_HEALTH_CHECK_URL = 'https://api-sandbox.surepassid.com/status'
    $env:DEPLOY_UPLOAD_ONLY = 'true'
    $env:GITHUB_WORKSPACE = $script:fixture
    $env:RUNNER_TEMP = $script:fixture
    $script:config = New-DeploymentConfig
    $script:package = [IO.MemoryStream]::new()
    Write-SandboxArchive $script:config.Source $script:package
    $script:package.Position = 0
    $script:remote = [IO.MemoryStream]::new()
    $script:events = [Collections.Generic.List[string]]::new()
    $script:chunks = [Collections.Generic.List[object]]::new()
    $script:fault = ''
    $script:cleanupFaults = @()
    $script:uploadId = '1234567890abcdef1234567890abcdef'
    $script:session = [pscustomobject]@{ State = 'Opened'; Availability = 'Available' }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        New-Fixture
        & $Body | Out-Null
        $script:passed++
        Write-Host "PASS $Name"
    } catch {
        throw "FAIL $Name : $($_.Exception.Message)"
    } finally {
        Close-Fixture
    }
}

function New-PSSession {
    param($ComputerName, $Credential, $ConfigurationName, $Authentication, $SessionOption, $ErrorAction)
    $script:events.Add('session-open')
    Assert-True ($ComputerName -eq 'sandbox-app') 'Approved target.'
    Assert-True ($ConfigurationName -ceq 'SurePassID.SandboxDeploy') 'Restricted endpoint selected.'
    Assert-True ($Authentication -eq 'Negotiate') 'Authentication is not weakened.'
    Assert-True ($Credential.UserName -eq 'SANDBOX-APP\github-deploy') 'Dedicated account.'
    Assert-True ($ErrorAction -eq 'Stop') 'Connection errors terminate.'
    if ($script:fault -eq 'session-denied') {
        throw 'Session access denied.'
    }
    if ($script:fault -eq 'session-unavailable') {
        $script:session.Availability = 'Busy'
    }
    return $script:session
}

function Remove-PSSession {
    param($Session, $ErrorAction)
    $script:events.Add('session-close')
    if ($script:cleanupFaults -contains 'session-close') {
        throw 'Session close fault.'
    }
}

function Invoke-Command {
    param($Session, [scriptblock]$ScriptBlock, $ErrorAction)
    Assert-True ($Session -eq $script:session) 'Only the restricted session is used.'
    Assert-True ($ErrorAction -eq 'Stop') 'Remote errors terminate.'
    $commands = @($ScriptBlock.Ast.FindAll({
        param($astNode)
        $astNode -is [Management.Automation.Language.CommandAst]
    }, $true))
    Assert-True ($commands.Count -eq 1) 'No bootstrap or arbitrary remote command sequence.'
    $commandName = $commands[0].GetCommandName()
    $script:events.Add($commandName)
    $arguments = @{}
    foreach ($usingMatch in [regex]::Matches($ScriptBlock.ToString(), '\$using:([a-zA-Z][a-zA-Z0-9]*)')) {
        $variableName = $usingMatch.Groups[1].Value
        $arguments[$variableName] = Get-Variable -Name $variableName -Scope 1 -ValueOnly
    }
    switch ($commandName) {
        'New-SandboxUpload' {
            Assert-True ($arguments.SiteName -ceq $script:config.Domain) 'Requested site.'
            switch ($script:fault) {
                'create-denied' { throw 'Create access denied.' }
                'create-lost' { throw 'Create response lost.' }
                'id-missing' { return }
                'id-invalid' { return '..\other-upload' }
                'id-number' { return 100 }
                'id-uppercase' { return $script:uploadId.ToUpperInvariant() }
                'id-multiple' { return @($script:uploadId, $script:uploadId) }
                'id-object' { return [pscustomobject]@{ Id = $script:uploadId } }
                'incomplete-read' { $script:package.StopEarly = $true }
                'read-fault' { $script:package.FailRead = $true }
            }
            return $script:uploadId
        }
        'Add-SandboxUploadChunk' {
            Assert-True ($arguments.UploadId -ceq $script:uploadId) 'Only owned upload is appended.'
            Assert-True ($arguments.Offset -eq $script:remote.Length) 'Exact append offset.'
            Assert-True ($arguments.Base64.Length -le 262144) 'Encoded chunk within server limit.'
            if ($script:fault -eq 'append-denied') {
                throw 'Append access denied.'
            }
            $decoded = [Convert]::FromBase64String($arguments.Base64)
            $script:chunks.Add([pscustomobject]@{
                Offset = $arguments.Offset; Bytes = $decoded.Length; Characters = $arguments.Base64.Length
            })
            if ($script:fault -eq 'corrupt') {
                $decoded[0] = $decoded[0] -bxor 1
            }
            $writeCount = $decoded.Length
            if ($script:fault -eq 'truncated' -and
                $arguments.Offset + $decoded.Length -eq $script:package.Length) {
                $writeCount--
            }
            $script:remote.Write($decoded, 0, $writeCount)
            if ($script:fault -eq 'append-lost') {
                throw 'Append response lost.'
            }
            if ($script:fault -eq 'session-lost') {
                $script:session.State = 'Broken'
                throw 'Remote session lost.'
            }
            switch ($script:fault) {
                'ack-missing' { return }
                'ack-string' { return ([string]$script:remote.Length) }
                'ack-int' { return ([int]$script:remote.Length) }
                'ack-multiple' { return @([long]$script:remote.Length, [long]$script:remote.Length) }
                'ack-wrong' { return ([long]$script:remote.Length - 1) }
                'ack-object' { return [pscustomobject]@{ Received = $script:remote.Length } }
            }
            # Truncation simulates a lying acknowledgement; hash verification must still reject it.
            if ($script:fault -eq 'truncated') {
                return ([long]$arguments.Offset + $decoded.Length)
            }
            return [long]$script:remote.Length
        }
        'Complete-SandboxDeployment' {
            Assert-True ($arguments.UploadId -ceq $script:uploadId) 'Only owned upload is completed.'
            if ($script:fault -eq 'complete-denied') {
                throw 'Complete access denied.'
            }
            if ($script:fault -eq 'complete-lost') {
                throw 'Complete response lost.'
            }
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $actualHash = [BitConverter]::ToString($algorithm.ComputeHash($script:remote.ToArray())).Replace('-', '')
            } finally {
                $algorithm.Dispose()
            }
            if ($actualHash -cne $arguments.Sha256) {
                throw 'Package hash mismatch.'
            }
            $result = [pscustomobject]@{
                SiteName = $script:config.Domain
                Destination = $script:config.Destination
                Backup = [IO.Path]::Combine([IO.Path]::GetDirectoryName($script:config.Destination), ($script:config.Domain + '_2026-11-09_120000.zip'))
                State = 'Started'
            }
            switch ($script:fault) {
                'result-missing' { return }
                'result-multiple' { return @($result, $result) }
                'result-property' { $result.PSObject.Properties.Remove('State') }
                'result-site' { $result.SiteName = 'mfa-sandbox.surepassid.com' }
                'result-path' { $result.Destination = 'C:\unapproved' }
                'result-backup' { $result.Backup = 'C:\unapproved.zip' }
                'result-state' { $result.State = 'Stopped' }
                'result-type' { $result.State = 200 }
            }
            return $result
        }
        'Remove-SandboxUpload' {
            Assert-True ($arguments.UploadId -ceq $script:uploadId) 'Only owned upload is removed.'
            if ($script:cleanupFaults -contains 'remove') {
                throw 'Upload remove fault.'
            }
            if ($script:fault -eq 'remove-response') {
                return 'unexpected'
            }
        }
        default { throw "Forbidden remote command: $commandName" }
    }
}

try {
    Test-Case 'ZIP contains hidden files, nested files and empty directories without a containing root' {
        $null = Get-SandboxPackageHash $script:package
        $archive = [IO.Compression.ZipArchive]::new($script:package, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $names = @($archive.Entries.FullName)
            foreach ($expectedName in @('bin/App.dll', 'web.config', 'nested/.hidden', 'empty/')) {
                Assert-True ($names -ccontains $expectedName) "ZIP contains $expectedName."
            }
            Assert-True (@($names | Where-Object { $_ -like 'publish/*' }).Count -eq 0) 'No extra ZIP root.'
        } finally {
            $archive.Dispose()
        }
    }
    Test-Case 'multi-chunk upload preserves exact ZIP bytes and never completes' {
        $expectedBytes = $script:package.ToArray()
        $receipt = Send-SandboxPackage $script:config $script:package
        Assert-True ([Convert]::ToBase64String($script:remote.ToArray()) -ceq [Convert]::ToBase64String($expectedBytes)) 'Exact package bytes.'
        Assert-True ($script:chunks.Count -eq 3) 'Two full chunks and short final chunk.'
        Assert-True ($script:chunks[0].Bytes -eq 192KB -and $script:chunks[0].Characters -eq 262144) 'Exact chunk ceiling.'
        Assert-True ($script:chunks[2].Bytes -gt 0 -and $script:chunks[2].Bytes -lt 192KB) 'Short final chunk.'
        Assert-True (!$script:events.Contains('Complete-SandboxDeployment')) 'No completion in upload-only mode.'
        Assert-True ($script:events.Contains('Remove-SandboxUpload') -and $script:events.Contains('session-close')) 'Upload/session cleaned.'
        Assert-True ($receipt.Mode -ceq 'UploadOnly' -and $receipt.ChunkCount -eq 3 -and
            $receipt.AcknowledgedBytes -eq $expectedBytes.Length -and $receipt.UploadRemoved -and
            !$receipt.CompletionAttempted -and $receipt.LocalZipSha256 -cmatch '^[A-F0-9]{64}$') 'Structured upload-only evidence.'
    }
    Test-Case 'exact package, expanded and entry-count ceilings are accepted without large allocations' {
        Assert-SandboxPackageLimits 4GB 8GB 100000
    }
    foreach ($limitCase in @(
        @{ Name = 'package over limit'; Package = (4GB + 1); Expanded = 1; Entries = 1; Error = '4 GiB' },
        @{ Name = 'empty package'; Package = 0; Expanded = 1; Entries = 1; Error = 'nonempty' },
        @{ Name = 'expanded over limit'; Package = 1; Expanded = (8GB + 1); Entries = 1; Error = '8 GiB' },
        @{ Name = 'negative expanded size'; Package = 1; Expanded = -1; Entries = 1; Error = '8 GiB' },
        @{ Name = 'entry count over limit'; Package = 1; Expanded = 1; Entries = 100001; Error = '100000' },
        @{ Name = 'zero entries'; Package = 1; Expanded = 1; Entries = 0; Error = '100000' }
    )) {
        Test-Case $limitCase.Name {
            $null = Assert-Throws { Assert-SandboxPackageLimits $limitCase.Package $limitCase.Expanded $limitCase.Entries } $limitCase.Error
            Assert-True ($script:events.Count -eq 0) 'No remote staging for invalid size.'
        }
    }
    Test-Case 'invalid ZIP fails before session creation' {
        $script:package.SetLength(0)
        $script:package.WriteByte(1)
        $null = Assert-Throws { Send-SandboxPackage $script:config $script:package } '.'
        Assert-True ($script:events.Count -eq 0) 'No remote side effects.'
    }
    Test-Case 'oversized package is rejected by transport before parsing or remote creation' {
        $oversized = [SandboxTransportTestStream]::new()
        try {
            $oversized.LengthOverride = 4GB + 1
            $null = Assert-Throws { Send-SandboxPackage $script:config $oversized } '4 GiB'
            Assert-True ($script:events.Count -eq 0) 'No connection or upload for oversized package.'
        } finally {
            $oversized.Dispose()
        }
    }
    foreach ($faultName in @('incomplete-read', 'read-fault')) {
        Test-Case "$faultName stops before completion and still cleans the owned upload" {
            $packageBytes = $script:package.ToArray()
            $script:package.Dispose()
            $script:package = [SandboxTransportTestStream]::new()
            $script:package.Write($packageBytes, 0, $packageBytes.Length)
            $script:fault = $faultName
            $expectedError = if ($faultName -eq 'incomplete-read') { 'Incomplete ZIP transfer' } else { 'Package read fault' }
            $null = Assert-Throws { Send-SandboxPackage $script:config $script:package -Complete } $expectedError
            Assert-True (!$script:events.Contains('Complete-SandboxDeployment')) 'No completion after incomplete read.'
            Assert-True ($script:events.Contains('Remove-SandboxUpload') -and $script:events.Contains('session-close')) 'Owned upload/session cleanup.'
        }
    }
    foreach ($faultName in @('session-denied', 'session-unavailable', 'create-denied', 'create-lost',
        'id-missing', 'id-invalid', 'id-number', 'id-uppercase', 'id-multiple', 'id-object')) {
        Test-Case "$faultName stops before append or completion" {
            $script:fault = $faultName
            $message = Assert-Throws { Send-SandboxPackage $script:config $script:package -Complete } '.'
            Assert-True (!$script:events.Contains('Add-SandboxUploadChunk') -and !$script:events.Contains('Complete-SandboxDeployment')) 'No append/completion.'
            Assert-True (!$script:events.Contains('Remove-SandboxUpload')) 'Never guess an upload identifier.'
            if ($faultName -notlike 'session-*') {
                Assert-True ($message -match 'creation outcome is unknown') 'Unknown create outcome reported.'
            }
            if ($faultName -ne 'session-denied') {
                Assert-True ($script:events.Contains('session-close')) 'Session cleanup attempted.'
            }
        }
    }
    foreach ($faultName in @('append-denied', 'append-lost', 'ack-missing', 'ack-string',
        'ack-int', 'ack-multiple', 'ack-wrong', 'ack-object')) {
        Test-Case "$faultName never retries or completes; removes only the owned upload" {
            $script:fault = $faultName
            $null = Assert-Throws { Send-SandboxPackage $script:config $script:package -Complete } '.'
            Assert-True (@($script:events | Where-Object { $_ -eq 'Add-SandboxUploadChunk' }).Count -eq 1) 'No blind append retry.'
            Assert-True (!$script:events.Contains('Complete-SandboxDeployment')) 'No incomplete completion.'
            Assert-True ($script:events.Contains('Remove-SandboxUpload') -and $script:events.Contains('session-close')) 'Owned cleanup attempted.'
        }
    }
    Test-Case 'lost session retains upload with actionable identifier and closes session' {
        $script:fault = 'session-lost'
        $message = Assert-Throws { Send-SandboxPackage $script:config $script:package -Complete } 'Remote session lost'
        Assert-True ($message.Contains($script:uploadId) -and $message -match 'retained') 'Retained upload identified.'
        Assert-True (!$script:events.Contains('Remove-SandboxUpload') -and $script:events.Contains('session-close')) 'No unsafe removal.'
    }
    foreach ($faultName in @('corrupt', 'truncated', 'complete-denied', 'complete-lost', 'result-missing',
        'result-multiple', 'result-property', 'result-site', 'result-path', 'result-backup', 'result-state', 'result-type')) {
        Test-Case "$faultName retains completion recovery data and fails explicitly" {
            $script:fault = $faultName
            $message = Assert-Throws { Send-SandboxPackage $script:config $script:package -Complete } '.'
            Assert-True ($script:events.Contains('Complete-SandboxDeployment')) 'Completion attempted once.'
            Assert-True (!$script:events.Contains('Remove-SandboxUpload')) 'Recovery upload retained.'
            Assert-True ($message -match 'retained' -and $message.Contains($script:uploadId)) 'Operator follow-up identifies upload.'
            Assert-True ($script:events.Contains('session-close')) 'Session closed independently.'
            if ($faultName -in @('corrupt', 'truncated')) {
                Assert-True ($message -match 'hash mismatch') 'Server hash rejection surfaced.'
            } elseif ($faultName -like 'result-*') {
                Assert-True ($message -match 'completion result') 'Exact completion-result validation surfaced.'
            } elseif ($faultName -eq 'complete-denied') {
                Assert-True ($message -match 'Complete access denied') 'Completion authorization failure surfaced.'
            } elseif ($faultName -eq 'complete-lost') {
                Assert-True ($message -match 'Complete response lost') 'Ambiguous completion failure surfaced.'
            }
        }
    }
    Test-Case 'IIS Started completion is never reported as qualified application success' {
        $message = Assert-Throws { Send-SandboxPackage $script:config $script:package -Complete } 'not qualified application health'
        Assert-True (!$script:events.Contains('Remove-SandboxUpload')) 'Even successful server result retains upload pending safety qualification.'
    }
    Test-Case 'append failure survives both upload and session cleanup failures' {
        $script:fault = 'append-denied'
        $script:cleanupFaults = @('remove', 'session-close')
        $message = Assert-Throws { Send-SandboxPackage $script:config $script:package } 'Append access denied'
        Assert-True ($message -match 'Upload remove fault' -and $message -match 'Session close fault') 'All errors surfaced.'
    }
    Test-Case 'cleanup failure is not upload-only success' {
        $script:fault = 'remove-response'
        $null = Assert-Throws { Send-SandboxPackage $script:config $script:package } 'Unexpected upload-removal response'
        Assert-True ($script:events.Contains('session-close')) 'Session still closes.'
    }
    Test-Case 'completion error and session cleanup error are both reported without removal' {
        $script:fault = 'complete-denied'
        $script:cleanupFaults = @('session-close')
        $message = Assert-Throws { Send-SandboxPackage $script:config $script:package -Complete } 'Complete access denied'
        Assert-True ($message -match 'Session close fault' -and $message -match 'retained') 'Original, cleanup and retention surfaced.'
    }
    foreach ($inputCase in @(
        @{ Name = 'wrong execution host'; Variable = 'COMPUTERNAME'; Value = 'DEVELOPMENT-PC'; Error = 'GH-RUNNER-WIN' },
        @{ Name = 'superseded execution host'; Variable = 'COMPUTERNAME'; Value = 'PRODUCT-SUP-01'; Error = 'GH-RUNNER-WIN' },
        @{ Name = 'wrong target'; Variable = 'DEPLOY_COMPUTER_NAME'; Value = 'production'; Error = 'approved sandbox-app' },
        @{ Name = 'wrong account'; Variable = 'DEPLOY_USERNAME'; Value = 'administrator'; Error = 'dedicated' },
        @{ Name = 'blank password'; Variable = 'DEPLOY_PASSWORD'; Value = ' '; Error = 'dedicated' },
        @{ Name = 'invalid environment'; Variable = 'DEPLOY_SITE_ENV'; Value = 'production'; Error = 'Invalid app-name' },
        @{ Name = 'invalid app'; Variable = 'DEPLOY_APP_NAME'; Value = 'unknown'; Error = 'Invalid app-name' },
        @{ Name = 'invalid run id'; Variable = 'DEPLOY_RUN_ID'; Value = '../100'; Error = 'run-id' },
        @{ Name = 'nested keep entry'; Variable = 'DEPLOY_KEEP_LIST'; Value = 'bin\site.lic'; Error = 'direct child' },
        @{ Name = 'code keep entry'; Variable = 'DEPLOY_KEEP_LIST'; Value = 'bin'; Error = 'application code' },
        @{ Name = 'duplicate keep entry'; Variable = 'DEPLOY_KEEP_LIST'; Value = 'data,DATA'; Error = 'Duplicate' },
        @{ Name = 'wrong health host'; Variable = 'DEPLOY_HEALTH_CHECK_URL'; Value = 'https://mfa-sandbox.surepassid.com/status'; Error = 'Health URL' },
        @{ Name = 'HTTP health'; Variable = 'DEPLOY_HEALTH_CHECK_URL'; Value = 'http://api-sandbox.surepassid.com/status'; Error = 'Health URL' },
        @{ Name = 'health credentials'; Variable = 'DEPLOY_HEALTH_CHECK_URL'; Value = 'https://user:pass@api-sandbox.surepassid.com/status'; Error = 'Health URL' },
        @{ Name = 'health fragment'; Variable = 'DEPLOY_HEALTH_CHECK_URL'; Value = 'https://api-sandbox.surepassid.com/status#fragment'; Error = 'Health URL' },
        @{ Name = 'traversal assembly'; Variable = 'DEPLOY_APP_ASSEMBLY'; Value = '..\App.dll'; Error = 'direct child' },
        @{ Name = 'missing assembly'; Variable = 'DEPLOY_APP_ASSEMBLY'; Value = 'missing.dll'; Error = '.' },
        @{ Name = 'root source'; Variable = 'DEPLOY_SOURCE_PATH'; Value = 'C:\'; Error = 'drive root' },
        @{ Name = 'UNC source'; Variable = 'DEPLOY_SOURCE_PATH'; Value = '\\server\publish'; Error = 'absolute local' }
    )) {
        Test-Case $inputCase.Name {
            [Environment]::SetEnvironmentVariable($inputCase.Variable, $inputCase.Value)
            $null = Assert-Throws { New-DeploymentConfig } $inputCase.Error
            Assert-True ($script:events.Count -eq 0) 'Input validation has no network operations.'
        }
    }
    Test-Case 'all approved site mappings include the OIDC sandbox exception' {
        foreach ($appName in @('api', 'mfa', 'push')) {
            foreach ($siteEnv in @('alpha', 'dev', 'sandbox')) {
                Assert-True ((Get-SandboxDestination $appName $siteEnv) -ceq "E:\iis_sites\$siteEnv\$appName-$siteEnv.surepassid.com") 'Mapped site.'
            }
        }
        Assert-True ((Get-SandboxDestination 'oidc' 'sandbox') -ceq 'E:\iis_sites\sandbox\oidc\oidc-sandbox.surepassid.com') 'OIDC nested path.'
        $null = Get-SandboxDestination 'oidc' 'alpha'
        $null = Get-SandboxDestination 'oidc-client' 'alpha'
        $null = Assert-Throws { Get-SandboxDestination 'oidc' 'dev' } 'not authorized'
        $null = Assert-Throws { Get-SandboxDestination 'oidc-client' 'sandbox' } 'not authorized'
        $null = Assert-Throws { Get-SandboxDestination 'oidc-client' 'dev' } 'not authorized'
    }
    Test-Case 'source junctions are rejected before traversal' {
        $linkPath = Join-Path $script:config.Source 'linked'
        $null = New-Item -ItemType Junction -Path $linkPath -Target $script:config.Source
        try {
            $null = Assert-Throws { Get-SafeSourceItems $script:config.Source } 'Reparse'
        } finally {
            [IO.Directory]::Delete($linkPath)
        }
    }
    Test-Case 'OIDC keep-list and health intent are validated but never applied by upload-only' {
        $env:DEPLOY_APP_NAME = 'oidc'
        $env:DEPLOY_KEEP_LIST = 'keys,logs'
        $env:DEPLOY_HEALTH_CHECK_URL = 'https://oidc-sandbox.surepassid.com/status'
        $script:config = New-DeploymentConfig
        Assert-True ($script:config.Keep.Count -eq 2 -and $script:config.HealthUrl -ceq $env:DEPLOY_HEALTH_CHECK_URL) 'Inputs retained, not silently discarded.'
        Send-SandboxPackage $script:config $script:package
        Assert-True (!$script:events.Contains('Complete-SandboxDeployment')) 'No preservation mutation or health claim.'
    }
    foreach ($application in @('api', 'mfa')) {
        Test-Case "$application rejects live configuration retention" {
            $env:DEPLOY_APP_NAME = $application
            $env:DEPLOY_HEALTH_CHECK_URL = "https://$application-sandbox.surepassid.com/status"
            $env:DEPLOY_KEEP_LIST = 'web.config'
            $null = Assert-Throws { New-DeploymentConfig } 'keep-list retention is forbidden'
        }
    }
    Test-Case 'reserved ZIP child names are rejected consistently with server' {
        foreach ($childName in @('COM0', 'LPT0.txt', '..', 'tail.', 'tail ', 'data:stream', 'nested\file')) {
            $null = Assert-Throws { Assert-ChildName $childName } 'direct child'
        }
    }
    Test-Case 'default action mode fails closed before touching source or network' {
        $env:COMPUTERNAME = 'DEVELOPMENT-PC'
        $null = Assert-Throws { Invoke-Deployment } 'Live completion is blocked'
        Assert-True ($script:events.Count -eq 0) 'No network.'
    }
    Test-Case 'transport primitive also rejects the wrong execution host' {
        $env:COMPUTERNAME = 'DEVELOPMENT-PC'
        $null = Assert-Throws { Send-SandboxPackage $script:config $script:package } 'GH-RUNNER-WIN'
        Assert-True ($script:events.Count -eq 0) 'No network.'
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Test-Case 'operator validation uses inert data and restores credentials after mocked upload' {
            . (Join-Path $PSScriptRoot 'Test-SandboxUpload.ps1')
            $credential = [Management.Automation.PSCredential]::new('SANDBOX-APP\github-deploy',
                (ConvertTo-SecureString 'isolated-test-value' -AsPlainText -Force))
            $priorSource = $env:DEPLOY_SOURCE_PATH
            $priorPassword = $env:DEPLOY_PASSWORD
            $receipt = Test-SandboxUpload -Credential $credential
            Assert-True ($receipt.ExecutionHost -ceq 'GH-RUNNER-WIN' -and $receipt.InertFixtureRemoved) 'Host and fixture cleanup evidence.'
            Assert-True ($receipt.ChunkCount -eq 3 -and $receipt.UploadRemoved -and !$receipt.CompletionAttempted) 'Multi-chunk, removal, no completion.'
            Assert-True ($env:DEPLOY_SOURCE_PATH -ceq $priorSource -and $env:DEPLOY_PASSWORD -ceq $priorPassword) 'Environment restored.'
            Assert-True (@(Get-ChildItem -LiteralPath $script:fixture -Filter 'step1c-inert-*').Count -eq 0) 'Owned fixture removed.'
        }
        Test-Case 'operator validation rejects the wrong host before prompting or connecting' {
            . (Join-Path $PSScriptRoot 'Test-SandboxUpload.ps1')
            $env:COMPUTERNAME = 'DEVELOPMENT-PC'
            $null = Assert-Throws { Test-SandboxUpload } 'locally on GH-RUNNER-WIN'
            Assert-True ($script:events.Count -eq 0) 'No connection.'
        }
        Test-Case 'operator validation restores credentials and emits no receipt after upload failure' {
            . (Join-Path $PSScriptRoot 'Test-SandboxUpload.ps1')
            $credential = [Management.Automation.PSCredential]::new('SANDBOX-APP\github-deploy',
                (ConvertTo-SecureString 'isolated-test-value' -AsPlainText -Force))
            $priorPassword = $env:DEPLOY_PASSWORD
            $priorSource = $env:DEPLOY_SOURCE_PATH
            $script:fault = 'append-denied'
            $observed = [Collections.Generic.List[object]]::new()
            $null = Assert-Throws {
                Test-SandboxUpload -Credential $credential | ForEach-Object { $observed.Add($_) }
            } 'Append access denied'
            Assert-True ($observed.Count -eq 0) 'Failure never emits a success receipt.'
            Assert-True ($env:DEPLOY_PASSWORD -ceq $priorPassword -and $env:DEPLOY_SOURCE_PATH -ceq $priorSource) 'Credentials/source restored after failure.'
            Assert-True (@(Get-ChildItem -LiteralPath $script:fixture -Filter 'step1c-inert-*').Count -eq 0) 'Inert fixture cleaned after failure.'
            Assert-True (!$script:events.Contains('Complete-SandboxDeployment')) 'No completion.'
        }
        Test-Case 'entry uploads only, disposes owned ZIP and leaves unrelated files intact' {
            Set-Content -LiteralPath (Join-Path $script:fixture 'unrelated.txt') -Value 'retain'
            Invoke-Deployment -UploadOnly
            Assert-True (@(Get-ChildItem -LiteralPath $script:fixture -Filter 'sandbox-upload-*.zip').Count -eq 0) 'Owned ZIP removed after stream disposed.'
            Assert-True (Test-Path -LiteralPath (Join-Path $script:fixture 'unrelated.txt')) 'Unrelated file retained.'
            Assert-True (!$script:events.Contains('Complete-SandboxDeployment')) 'Entry cannot complete.'
        }
        Test-Case 'entry cleans partial ZIP when packaging fails before network' {
            function Write-SandboxArchive {
                param($Source, $Stream)
                $Stream.WriteByte(1)
                throw 'Partial ZIP fault.'
            }
            try {
                $null = Assert-Throws { Invoke-Deployment -UploadOnly } 'Partial ZIP fault'
                Assert-True (@(Get-ChildItem -LiteralPath $script:fixture -Filter 'sandbox-upload-*.zip').Count -eq 0) 'Partial owned ZIP cleaned.'
                Assert-True ($script:events.Count -eq 0) 'No remote effects.'
            } finally {
                Remove-Item Function:\Write-SandboxArchive
            }
        }
        Test-Case 'original transport failure survives local archive cleanup failure' {
            $script:fault = 'append-denied'
            function Remove-OwnedArchive {
                param($Path, $Parent)
                throw 'Local removal fault.'
            }
            $message = Assert-Throws { Invoke-Deployment -UploadOnly } 'Append access denied'
            Assert-True ($message -match 'Local archive cleanup failed' -and $message -match 'Local removal fault') 'Original and local cleanup surfaced.'
            Assert-True ($script:events.Contains('session-close')) 'Session cleanup already attempted.'
            $retainedArchives = @(Get-ChildItem -LiteralPath $script:fixture -Filter 'sandbox-upload-*.zip')
            Assert-True ($retainedArchives.Count -eq 1) 'Only the owned local archive remains.'
            $unlockedStream = [IO.File]::Open($retainedArchives[0].FullName, 'Open', 'ReadWrite', 'None')
            $unlockedStream.Dispose()
        }
        Test-Case 'ZIP inside source is rejected before creating a package' {
            $env:RUNNER_TEMP = Join-Path $script:config.Source 'empty'
            $null = Assert-Throws { Invoke-Deployment -UploadOnly } 'outside the published'
            Assert-True ($script:events.Count -eq 0) 'No network.'
        }
    }
    Test-Case 'action retains all inputs via env and defaults to deployment blocked' {
        $yaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'action.yaml') -Raw
        Assert-True (($yaml -split 'run: \|')[1] -notmatch '\$\{\{') 'No expression interpolation in script.'
        foreach ($inputName in @('computer-name', 'username', 'password', 'site-env', 'app-name',
            'source-path', 'app-assembly', 'run-id', 'keep-list', 'health-check-url', 'upload-only')) {
            Assert-True ($yaml.Contains('${{ inputs.' + $inputName + ' }}')) "Input $inputName passed via env."
        }
        Assert-True ($yaml -match "(?s)upload-only:.*?default: 'false'") 'Deployment blocked by default.'
    }
    Write-Host "RESULT: $script:passed isolated tests passed; no real WinRM, IIS, HTTP or server function calls."
} finally {
    Close-Fixture
    foreach ($environmentName in $environmentNames) {
        [Environment]::SetEnvironmentVariable($environmentName, $savedEnvironment[$environmentName])
    }
}
