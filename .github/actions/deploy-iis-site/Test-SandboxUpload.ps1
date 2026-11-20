[CmdletBinding()]
param(
    [Management.Automation.PSCredential]$Credential,
    [string]$ComputerName = 'sandbox-app'
)

function Test-SandboxUpload {
    param([Management.Automation.PSCredential]$Credential, [string]$ComputerName = 'sandbox-app')
    $ErrorActionPreference = 'Stop'
    if ($env:COMPUTERNAME -ine 'GH-RUNNER-WIN') {
        throw 'Run this validation locally on GH-RUNNER-WIN (gh-runner-windows); no connection was opened.'
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'Run this validation in PowerShell 7 (pwsh).'
    }
    if ($ComputerName -notmatch '^sandbox-app(?:\.[a-z0-9-]+)*$') {
        throw 'Only the approved sandbox-app target is allowed.'
    }
    $clientPath = Join-Path $PSScriptRoot 'Deploy-IisSite.ps1'
    . $clientPath
    if (!$Credential) {
        $Credential = Get-Credential -UserName 'SANDBOX-APP\github-deploy' `
            -Message 'Step 1c: inert ZIP upload and removal only; no deployment'
    }
    if (!$Credential -or $Credential.UserName -ine 'SANDBOX-APP\github-deploy') {
        throw 'Use the dedicated SANDBOX-APP\github-deploy credential.'
    }
    $environmentNames = @('DEPLOY_COMPUTER_NAME', 'DEPLOY_USERNAME', 'DEPLOY_PASSWORD',
        'DEPLOY_SITE_ENV', 'DEPLOY_APP_NAME', 'DEPLOY_RUN_ID', 'DEPLOY_SOURCE_PATH',
        'DEPLOY_APP_ASSEMBLY', 'DEPLOY_KEEP_LIST', 'DEPLOY_HEALTH_CHECK_URL')
    $savedEnvironment = @{}
    foreach ($environmentName in $environmentNames) {
        $savedEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
    }
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $temp = [IO.Path]::GetFullPath($temp).TrimEnd('\', '/')
    Assert-SafeAncestors $temp
    $fixture = Join-Path $temp ('step1c-inert-' + [guid]::NewGuid().ToString('N'))
    $owned = $false
    $failure = $null
    $cleanupIssues = [Collections.Generic.List[string]]::new()
    $startedUtc = [datetime]::UtcNow.ToString('o')
    $clientHash = (Get-FileHash -LiteralPath $clientPath -Algorithm SHA256 -ErrorAction Stop).Hash
    try {
        $null = New-Item -Path $fixture -ItemType Directory -ErrorAction Stop
        $owned = $true
        $source = Join-Path $fixture 'publish'
        $null = New-Item -Path "$source\bin", "$source\empty", "$source\nested" -ItemType Directory -ErrorAction Stop
        $payload = [byte[]]::new(450000)
        [Random]::new(42).NextBytes($payload)
        [IO.File]::WriteAllBytes((Join-Path $source 'bin\Inert.dll'), $payload)
        Set-Content -LiteralPath (Join-Path $source 'web.config') -Value '<configuration />' -Encoding UTF8
        $hiddenFile = Join-Path $source 'nested\.step1c-inert'
        Set-Content -LiteralPath $hiddenFile -Value 'Inert upload-only validation; not an application.' -Encoding UTF8
        (Get-Item -LiteralPath $hiddenFile -Force).Attributes = [IO.FileAttributes]::Hidden
        $env:DEPLOY_COMPUTER_NAME = $ComputerName
        $env:DEPLOY_USERNAME = $Credential.UserName
        $env:DEPLOY_PASSWORD = $Credential.GetNetworkCredential().Password
        $env:DEPLOY_SITE_ENV = 'sandbox'
        $env:DEPLOY_APP_NAME = 'api'
        $env:DEPLOY_RUN_ID = "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-1"
        $env:DEPLOY_SOURCE_PATH = $source
        $env:DEPLOY_APP_ASSEMBLY = 'bin\Inert.dll'
        $env:DEPLOY_KEEP_LIST = ''
        $env:DEPLOY_HEALTH_CHECK_URL = 'https://api-sandbox.surepassid.com/status'
        $receipt = Invoke-Deployment -UploadOnly
        if ($receipt.Mode -cne 'UploadOnly' -or $receipt.ChunkCount -lt 3 -or
            $receipt.AcknowledgedBytes -le 393216 -or !$receipt.UploadRemoved -or $receipt.CompletionAttempted) {
            throw 'Upload-only validation did not produce the required multi-chunk cleanup receipt.'
        }
    } catch {
        $failure = $_
    } finally {
        if ($owned) {
            try {
                Assert-SafeAncestors $fixture
                $null = @(Get-SafeSourceItems $fixture)
                Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
            } catch {
                $cleanupIssues.Add("Inert fixture cleanup failed at ${fixture}: $($_.Exception.Message)")
            }
        }
        foreach ($environmentName in $environmentNames) {
            try {
                [Environment]::SetEnvironmentVariable($environmentName, $savedEnvironment[$environmentName])
            } catch {
                $cleanupIssues.Add("Could not restore environment variable ${environmentName}: $($_.Exception.Message)")
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
    $receipt | Add-Member -NotePropertyName ExecutionHost -NotePropertyValue $env:COMPUTERNAME
    $receipt | Add-Member -NotePropertyName ClientSha256 -NotePropertyValue $clientHash
    $receipt | Add-Member -NotePropertyName StartedUtc -NotePropertyValue $startedUtc
    $receipt | Add-Member -NotePropertyName CompletedUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o'))
    $receipt | Add-Member -NotePropertyName InertFixtureRemoved -NotePropertyValue $true
    return $receipt
}

if ($MyInvocation.InvocationName -ne '.') {
    Test-SandboxUpload -Credential $Credential -ComputerName $ComputerName
}
