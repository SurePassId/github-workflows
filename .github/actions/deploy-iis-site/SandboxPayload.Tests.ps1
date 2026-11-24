[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Workflow payload tests require PowerShell 7.'
}
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'Deploy-IisSite.ps1')
$workflowPath = Join-Path $PSScriptRoot '..\..\workflows\build-deploy-sandboxvm.yaml'
$workflowText = Get-Content -LiteralPath $workflowPath -Raw

function Get-WorkflowScript {
    param([string]$Name)
    $pattern = '(?m)^      - name: ' + [regex]::Escape($Name) +
        '\r?\n(?:(?:        |          |            ).*\r?\n)*?        run: \|\r?\n(?<body>(?:          .*(?:\r?\n|$)|\r?\n)+)'
    $matches = [regex]::Matches($workflowText, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one inline workflow step: $Name"
    }
    return [scriptblock]::Create(($matches[0].Groups['body'].Value -replace '(?m)^          ', ''))
}

$validateScript = Get-WorkflowScript 'Validate staged deployment configuration'
$savedEnvironment = @{}
foreach ($variableName in @('APP_NAME', 'SITE_ENV', 'PUBLISH_DIR', 'GITHUB_WORKSPACE', 'KEEP_LIST')) {
    $savedEnvironment[$variableName] = [Environment]::GetEnvironmentVariable($variableName)
}
$script:passed = 0
$script:fixture = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION: $Message"
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $failure = $null
    try {
        & $Body | Out-Null
    } catch {
        $failure = $_
    }
    Assert-True ($null -ne $failure) 'Expected rejection.'
    Assert-True ($failure.Exception.Message -notmatch 'secret-marker') 'Errors must not disclose configuration contents.'
    Assert-True ($failure.Exception.Message -match $Pattern) "Expected $Pattern; got $($failure.Exception.Message)"
}

function New-PSSession { throw 'Network calls are forbidden in payload tests.' }
function Invoke-Command { throw 'Remote calls are forbidden in payload tests.' }
function Invoke-WebRequest { throw 'HTTP calls are forbidden in payload tests.' }

function New-Fixture {
    param([string]$Application = 'mfa', [string]$SiteEnv = 'dev')
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) ('payload-policy-tests-' + [guid]::NewGuid().ToString('N'))
    $env:GITHUB_WORKSPACE = $script:fixture
    $env:PUBLISH_DIR = Join-Path $script:fixture 'publish'
    $env:APP_NAME = $Application
    $env:SITE_ENV = $SiteEnv
    $env:KEEP_LIST = ''
    $null = [IO.Directory]::CreateDirectory((Join-Path $env:PUBLISH_DIR 'bin'))
    if ($Application -eq 'mfa') {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'bin\SurePassAdmin.dll'), 'new-assembly-marker')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'),
            '<configuration><appSettings><add key="MfaServerLicence.FilePath" value="E:\shared_licenses\dev" /><add key="MfaServerLicence.Filename" value="site.lic" /></appSettings></configuration>')
    } elseif ($Application -eq 'saml2') {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'bin\SurePassSSOIdentityProvider.dll'), 'new-saml2-assembly')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'),
            '<configuration><appSettings><add key="Connection.Server" value="db-dev" /></appSettings></configuration>')
    } else {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'SurePassIdApiServer.dll'), 'new-api-assembly')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'),
            "<configuration><system.webServer><aspNetCore><environmentVariables><environmentVariable name=`"ASPNETCORE_ENVIRONMENT`" value=`"mfa-$SiteEnv`" /></environmentVariables></aspNetCore></system.webServer></configuration>")
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'appsettings.json'),
            '{ /* allowed comment */ "AppSettings": { "AllowedHosts": "*" }, }')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR "appsettings.mfa-$SiteEnv.json"),
            '{ /* allowed comment */ "AzureKeyVault": { "AuthenticationMethod": "ManagedId" } }')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'logging.config'), '<log4net />')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'appsettings.mfa-prod.json'), '{"unused":"not selected"}')
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body, [string]$Application = 'mfa', [string]$SiteEnv = 'dev')
    try {
        New-Fixture $Application $SiteEnv
        & $Body | Out-Null
        $script:passed++
        Write-Host "PASS $Name"
    } catch {
        throw "FAIL $Name : $($_.Exception.Message)"
    } finally {
        if ($script:fixture -and [IO.Directory]::Exists($script:fixture)) {
            Assert-True ([IO.Path]::GetDirectoryName($script:fixture) -ieq [IO.Path]::GetTempPath().TrimEnd('\')) 'Owned temporary parent.'
            Assert-True ([IO.Path]::GetFileName($script:fixture) -cmatch '^payload-policy-tests-[a-f0-9]{32}$') 'Owned fixture name.'
            Remove-Item -LiteralPath $script:fixture -Recurse -Force
        }
        $script:fixture = $null
    }
}

try {
    foreach ($application in @('api', 'mfa', 'saml2')) {
        foreach ($siteEnv in @('alpha', 'dev', 'sandbox')) {
            Test-Case "$application/$siteEnv validates repo-based staged configuration and packages cleanly" {
                & $validateScript
                Assert-True (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR 'web.config') -PathType Leaf) 'web.config present.'
                if ($env:APP_NAME -eq 'api') {
                    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR 'appsettings.mfa-prod.json'))) 'Unselected configuration pruned.'
                    $normalized = Get-Content -LiteralPath (Join-Path $env:PUBLISH_DIR "appsettings.mfa-$env:SITE_ENV.json") -Raw | ConvertFrom-Json
                    Assert-True ($normalized.AzureKeyVault.AuthenticationMethod -ceq 'ManagedId') 'JSON normalized cleanly for PS5.1 validation.'
                }
                $stream = [IO.MemoryStream]::new()
                try {
                    Write-SandboxArchive $env:PUBLISH_DIR $stream
                    $stream.Position = 0
                    $archive = [IO.Compression.ZipArchive]::new($stream, 'Read', $true)
                    try {
                        Assert-True ($null -ne $archive.GetEntry('web.config')) 'Package contains web.config.'
                    } finally {
                        $archive.Dispose()
                    }
                } finally {
                    $stream.Dispose()
                }
            } $application $siteEnv
        }
        Test-Case "$application rejects missing web.config" {
            Remove-Item -LiteralPath (Join-Path $env:PUBLISH_DIR 'web.config')
            Assert-Throws { & $validateScript } 'Published web.config is missing or empty'
        } $application
        Test-Case "$application rejects keep-list retention" {
            $env:KEEP_LIST = 'bin'
            Assert-Throws { & $validateScript } 'keep-list retention is forbidden'
        } $application
    }

    foreach ($invalidXml in @('<configuration>secret-marker', '<wrongRoot />',
        '<!DOCTYPE configuration [<!ENTITY local SYSTEM "file:///unread-secret">]><configuration>&local;</configuration>',
        '<configuration><appSettings file="outside.config" /></configuration>',
        '<configuration><connectionStrings configSource="outside.config" /></configuration>',
        '<configuration><appSettings configProtectionProvider="machine-key" /></configuration>')) {
        Test-Case 'reject malformed or non-self-contained XML without disclosure' {
            [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'), $invalidXml)
            Assert-Throws { & $validateScript } 'self-contained XML'
        }
    }

    Test-Case 'MFA rejects duplicate appSettings keys' {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'),
            '<configuration><appSettings><add key="DupKey" value="a" /><add key="DupKey" value="b" /></appSettings></configuration>')
        Assert-Throws { & $validateScript } 'Duplicate MFA appSettings key'
    } 'mfa'

    Test-Case 'API rejects mismatched runtime environment' {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'),
            '<configuration><system.webServer><aspNetCore><environmentVariables><environmentVariable name="ASPNETCORE_ENVIRONMENT" value="mfa-prod" /></environmentVariables></aspNetCore></system.webServer></configuration>')
        Assert-Throws { & $validateScript } 'IIS environment must match'
    } 'api'

    Test-Case 'API rejects duplicate or flattened JSON keys' {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'appsettings.mfa-dev.json'),
            '{"ConnectionStrings:MFA":"secret-marker"}')
        Assert-Throws { & $validateScript } 'Configuration JSON'
    } 'api'

    Test-Case 'API preserves and normalizes optional appsettings.local.json when present' {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'appsettings.local.json'),
            '{ /* comment */ "AppSettings": { "MfaServerLicense": { "FilePath": "E:\\shared_licenses\\dev" } } }')
        & $validateScript
        $localCfg = Get-Content -LiteralPath (Join-Path $env:PUBLISH_DIR 'appsettings.local.json') -Raw | ConvertFrom-Json
        Assert-True ($localCfg.AppSettings.MfaServerLicense.FilePath -ceq 'E:\shared_licenses\dev') 'External license path preserved.'
    } 'api'

    Test-Case 'API rejects missing environment appsettings file' {
        Remove-Item -LiteralPath (Join-Path $env:PUBLISH_DIR 'appsettings.mfa-dev.json')
        Assert-Throws { & $validateScript } 'Could not find file'
    } 'api'

    Test-Case 'validation rejects reparse-point publish directories' {
        $binPath = Join-Path $env:PUBLISH_DIR 'bin'
        $otherPath = Join-Path $script:fixture 'other'
        $null = [IO.Directory]::CreateDirectory($otherPath)
        Remove-Item -LiteralPath (Join-Path $binPath 'SurePassAdmin.dll')
        [IO.Directory]::Delete($binPath)
        $null = New-Item -ItemType Junction -Path $binPath -Target $otherPath
        try {
            Assert-Throws { & $validateScript } 'Reparse point'
        } finally {
            [IO.Directory]::Delete($binPath)
        }
    }

    Test-Case 'validation rejects non-owned publish directory' {
        $env:PUBLISH_DIR = Join-Path $script:fixture 'other'
        $null = [IO.Directory]::CreateDirectory($env:PUBLISH_DIR)
        Assert-Throws { & $validateScript } 'owned workspace publish'
    }

    Assert-True ($workflowText.IndexOf('name: Validate staged deployment configuration') -lt
        $workflowText.IndexOf('name: Deploy ${{ env.APP_NAME }}')) 'Validation runs before remoting.'
    Write-Host "RESULT: $script:passed payload-policy tests passed; no real credentials, WinRM, HTTP or IIS calls."
} finally {
    foreach ($variableName in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($variableName, $savedEnvironment[$variableName])
    }
}
