[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Workflow payload tests require PowerShell 7.' }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'Deploy-IisSite.ps1')
$workflowPath = Join-Path $PSScriptRoot '..\..\workflows\build-deploy-sandboxvm.yaml'
$workflowText = Get-Content -LiteralPath $workflowPath -Raw

function Get-WorkflowScript {
    param([string]$Name)
    $pattern = '(?m)^      - name: ' + [regex]::Escape($Name) +
        '\r?\n(?:(?:        |          |            ).*\r?\n)*?        run: \|\r?\n(?<body>(?:          .*(?:\r?\n|$)|\r?\n)+)'
    $matches = [regex]::Matches($workflowText, $pattern)
    if ($matches.Count -ne 1) { throw "Expected exactly one inline workflow step: $Name" }
    return [scriptblock]::Create(($matches[0].Groups['body'].Value -replace '(?m)^          ', ''))
}
$prepareScript = Get-WorkflowScript 'Prepare and validate deployment configuration'
$cleanupScript = Get-WorkflowScript 'Remove provisioned configuration from runner'
$savedEnvironment = @{}
foreach ($variableName in @('APP_NAME', 'SITE_ENV', 'PUBLISH_DIR', 'GITHUB_WORKSPACE',
    'DEPLOYMENT_CONFIGURATION', 'KEEP_LIST')) {
    $savedEnvironment[$variableName] = [Environment]::GetEnvironmentVariable($variableName)
}
$script:passed = 0
$script:fixture = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION: $Message" }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $failure = $null
    try { & $Body | Out-Null } catch { $failure = $_ }
    Assert-True ($null -ne $failure) 'Expected rejection.'
    Assert-True ($failure.Exception.Message -notmatch 'secret-marker') 'Errors must not disclose configuration contents.'
    Assert-True ($failure.Exception.Message -match $Pattern) "Expected $Pattern; got $($failure.Exception.Message)"
}
function New-PSSession { throw 'Network calls are forbidden in payload tests.' }
function Invoke-Command { throw 'Remote calls are forbidden in payload tests.' }
function Invoke-WebRequest { throw 'HTTP calls are forbidden in payload tests.' }
function ConvertTo-EncodedFile {
    param([string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}
function Save-Bundle {
    $env:DEPLOYMENT_CONFIGURATION = $script:bundle | ConvertTo-Json -Depth 20 -Compress
}
function New-Fixture {
    param([string]$Application = 'mfa', [string]$SiteEnv = 'sandbox')
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) ('payload-policy-tests-' + [guid]::NewGuid().ToString('N'))
    $env:GITHUB_WORKSPACE = $script:fixture
    $env:PUBLISH_DIR = Join-Path $script:fixture 'publish'
    $env:APP_NAME = $Application
    $env:SITE_ENV = $SiteEnv
    $env:KEEP_LIST = ''
    $null = [IO.Directory]::CreateDirectory((Join-Path $env:PUBLISH_DIR 'bin'))
    [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'bin\SurePassAdmin.dll'), 'new-assembly-marker')
    $script:bundle = @{
        application = $Application
        environment = $SiteEnv
        files = @{}
    }
    if ($Application -eq 'mfa') {
        $script:bundle.files['web.config'] = ConvertTo-EncodedFile '<configuration><appSettings /></configuration>'
        $script:bundle.files['bin/site.lic'] = ConvertTo-EncodedFile 'secret-marker-selected-license'
    } else {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'),
            "<configuration><system.webServer><aspNetCore><environmentVariables><environmentVariable name=`"ASPNETCORE_ENVIRONMENT`" value=`"mfa-$SiteEnv`" /></environmentVariables></aspNetCore></system.webServer></configuration>")
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'appsettings.json'),
            '{"AppSettings":{"MfaServerLicense":{"LicenseCode":"unselected-default","FilePath":"E:\\other-site"}}}')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR "appsettings.mfa-$SiteEnv.json"), '{ /* allowed configuration comment */ }')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'logging.config'), '<log4net />')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'appsettings.mfa-prod.json'), '{"unused":"not selected"}')
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'appsettings.local.json'), '{"unused":"must be replaced"}')
        $script:localSettings = @{
            ConnectionStrings = @{ MFA = 'secret-marker-database' }
            AppSettings = @{ MfaServerLicense = @{ ValidationKey = 'secret-marker-validation' } }
        }
        $script:bundle.files['appsettings.local.json'] = ConvertTo-EncodedFile ($script:localSettings | ConvertTo-Json -Depth 10)
        $script:bundle.files['site.lic'] = ConvertTo-EncodedFile 'secret-marker-selected-license'
    }
    Save-Bundle
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body, [string]$Application = 'mfa', [string]$SiteEnv = 'sandbox')
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
    foreach ($application in @('api', 'mfa')) {
        foreach ($siteEnv in @('alpha', 'dev', 'sandbox')) {
            Test-Case "$application/$siteEnv provisions and packages the selected license/configuration" {
                & $prepareScript
                $licensePath = 'site.lic'
                if ($env:APP_NAME -eq 'mfa') { $licensePath = 'bin/site.lic' }
                Assert-True ([IO.File]::ReadAllText((Join-Path $env:PUBLISH_DIR $licensePath)) -ceq 'secret-marker-selected-license') 'Exact selected license bytes.'
                Assert-True (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR 'web.config') -PathType Leaf) 'MFA missing web.config is securely provisioned, not bypassed.'
                if ($env:APP_NAME -eq 'api') {
                    $effective = Get-Content -LiteralPath (Join-Path $env:PUBLISH_DIR 'appsettings.local.json') -Raw | ConvertFrom-Json
                    Assert-True ($effective.AppSettings.MfaServerLicense.LicenseCode -ceq '') 'Clear lower-priority license code.'
                    Assert-True ($effective.AppSettings.MfaServerLicense.FilePath -ceq "E:\iis_sites\$env:SITE_ENV\api-$env:SITE_ENV.surepassid.com") 'File license is bound to the selected site.'
                    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR 'appsettings.mfa-prod.json'))) 'Unselected configuration excluded.'
                    Assert-True ([IO.File]::ReadAllText((Join-Path $env:PUBLISH_DIR "appsettings.mfa-$env:SITE_ENV.json")) -ceq '{}') 'Comments normalized for deployed Windows PowerShell 5.1 validation.'
                } else {
                    $effective = [xml][IO.File]::ReadAllText((Join-Path $env:PUBLISH_DIR 'web.config'))
                    $licenseSettings = @{}
                    foreach ($setting in $effective.SelectNodes('/configuration/appSettings/add')) {
                        $licenseSettings[$setting.GetAttribute('key')] = $setting.GetAttribute('value')
                    }
                    Assert-True ($licenseSettings['MfaServerLicence.LicenseCode'] -ceq '') 'Do not inherit an inline license from machine configuration.'
                    Assert-True ($licenseSettings['MfaServerLicence.FilePath'] -ceq "E:\iis_sites\$env:SITE_ENV\mfa-$env:SITE_ENV.surepassid.com\bin") 'MFA license path is explicitly site-bound.'
                }
                $stream = [IO.MemoryStream]::new()
                try {
                    Write-SandboxArchive $env:PUBLISH_DIR $stream
                    $stream.Position = 0
                    $archive = [IO.Compression.ZipArchive]::new($stream, 'Read', $true)
                    try {
                        Assert-True ($null -ne $archive.GetEntry('web.config') -and $null -ne $archive.GetEntry($licensePath)) 'One immutable payload contains configuration and license.'
                        Assert-True ($null -ne $archive.GetEntry('bin/SurePassAdmin.dll')) 'Package retains newly built code, not live binaries.'
                    } finally { $archive.Dispose() }
                } finally { $stream.Dispose() }
                & $cleanupScript
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR $licensePath))) 'Runner license cleaned.'
                Assert-True (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR 'bin\SurePassAdmin.dll')) 'Cleanup does not remove binaries.'
            } $application $siteEnv
        }
        Test-Case "$application handles inline licensing according to application compatibility" {
            if ($env:APP_NAME -eq 'mfa') {
                $script:bundle.files['web.config'] = ConvertTo-EncodedFile '<configuration><appSettings><add key="MfaServerLicence.LicenseCode" value="secret-marker-inline" /></appSettings></configuration>'
                $script:bundle.files.Remove('bin/site.lic')
                Save-Bundle
                Assert-Throws { & $prepareScript } 'existing license-management UI'
                return
            } else {
                $script:localSettings.AppSettings.MfaServerLicense.LicenseCode = 'secret-marker-inline'
                $script:bundle.files['appsettings.local.json'] = ConvertTo-EncodedFile ($script:localSettings | ConvertTo-Json -Depth 10)
                $script:bundle.files.Remove('site.lic')
                $unusedLicensePath = Join-Path $env:PUBLISH_DIR 'site.lic'
            }
            [IO.File]::WriteAllText($unusedLicensePath, 'old-publish-license')
            Save-Bundle
            & $prepareScript
            Assert-True (-not (Test-Path -LiteralPath $unusedLicensePath)) 'Inline code has explicit precedence; stale file removed.'
        } $application
        Test-Case "$application fails closed without a selected secret" {
            $env:DEPLOYMENT_CONFIGURATION = ''
            Assert-Throws { & $prepareScript } 'selected environment requires'
        } $application
        Test-Case "$application rejects another environment" {
            $script:bundle.environment = 'alpha'
            Save-Bundle
            Assert-Throws { & $prepareScript } 'matching the selected deployment'
        } $application
        Test-Case "$application rejects another application" {
            $script:bundle.application = 'other'
            Save-Bundle
            Assert-Throws { & $prepareScript } 'matching the selected deployment'
        } $application
        Test-Case "$application rejects missing required license" {
            $script:bundle.files.Remove('site.lic')
            $script:bundle.files.Remove('bin/site.lic')
            Save-Bundle
            Assert-Throws { & $prepareScript } 'requires the selected environment license'
        } $application
        Test-Case "$application rejects a missing configuration" {
            $script:bundle.files.Remove('web.config')
            $script:bundle.files.Remove('appsettings.local.json')
            Save-Bundle
            Assert-Throws { & $prepareScript } 'Required environment-specific configuration'
        } $application
        Test-Case "$application rejects keep-list retention" {
            $env:KEEP_LIST = 'bin'
            Assert-Throws { & $prepareScript } 'forbids keep-list retention'
        } $application
    }
    foreach ($fileName in @('../web.config', 'bin/Old.dll', 'E:\production\site.lic', 'web.config:stream', 'WEB.CONFIG')) {
        Test-Case "reject unsupported bundle path $fileName" {
            if ($fileName -ceq 'WEB.CONFIG') { $script:bundle.files.Remove('web.config') }
            $script:bundle.files[$fileName] = ConvertTo-EncodedFile 'secret-marker'
            Save-Bundle
            Assert-Throws { & $prepareScript } 'unsupported file|Configuration JSON'
        }
    }
    foreach ($invalidBase64 in @('', 'secret-marker-not-base64')) {
        Test-Case 'reject empty or malformed encoded configuration' {
            $script:bundle.files['web.config'] = $invalidBase64
            Save-Bundle
            Assert-Throws { & $prepareScript } 'nonempty|base64 encoded'
        }
    }
    foreach ($invalidXml in @('<configuration>secret-marker', '<wrongRoot />',
        '<!DOCTYPE configuration [<!ENTITY local SYSTEM "file:///unread-secret">]><configuration>&local;</configuration>',
        '<configuration><appSettings file="outside.config" /></configuration>',
        '<configuration><connectionStrings configSource="outside.config" /></configuration>',
        '<configuration><appSettings configProtectionProvider="machine-key" /></configuration>')) {
        Test-Case 'reject malformed or non-self-contained MFA XML without disclosure' {
            $script:bundle.files['web.config'] = ConvertTo-EncodedFile $invalidXml
            Save-Bundle
            Assert-Throws { & $prepareScript } 'self-contained XML'
        }
    }
    Test-Case 'reject off-site MFA license references' {
        $script:bundle.files['web.config'] = ConvertTo-EncodedFile '<configuration><appSettings><add key="MfaServerLicence.FilePath" value="E:\production" /><add key="MfaServerLicence.Filename" value="site.lic" /></appSettings></configuration>'
        Save-Bundle
        Assert-Throws { & $prepareScript } 'same-site'
    }
    Test-Case 'accept explicit same-site MFA license references' {
        $script:bundle.files['web.config'] = ConvertTo-EncodedFile '<configuration><appSettings><add key="MfaServerLicence.FilePath" value="E:\iis_sites\sandbox\mfa-sandbox.surepassid.com\bin" /><add key="MfaServerLicence.Filename" value="site.lic" /></appSettings></configuration>'
        Save-Bundle
        & $prepareScript
    }
    Test-Case 'MFA UTF-16 input is serialized as valid UTF-8 after license normalization' {
        $xmlText = '<?xml version="1.0" encoding="utf-16"?><configuration><appSettings><add key="OtherSetting" value="preserved" /></appSettings></configuration>'
        $script:bundle.files['web.config'] = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($xmlText))
        Save-Bundle
        & $prepareScript
        $configuration = [xml][IO.File]::ReadAllText((Join-Path $env:PUBLISH_DIR 'web.config'))
        Assert-True ($configuration.FirstChild.Encoding -ceq 'utf-8') 'Declaration matches staged bytes.'
        Assert-True ($configuration.SelectSingleNode('/configuration/appSettings/add[@key="OtherSetting"]').GetAttribute('value') -ceq 'preserved') 'Unrelated configuration settings preserved.'
    }
    foreach ($invalidBundle in @('{secret-marker', '[]',
        '{"application":"mfa","Application":"secret-marker","environment":"sandbox","files":{}}',
        '{"application":["mfa"],"environment":"sandbox","files":{}}',
        '{"application":"mfa","environment":["sandbox"],"files":{}}',
        '{"application":"mfa","environment":"sandbox","files":{},"extra":"secret-marker"}')) {
        Test-Case 'reject malformed, duplicate or extra bundle fields' {
            $env:DEPLOYMENT_CONFIGURATION = $invalidBundle
            Assert-Throws { & $prepareScript } 'Configuration JSON|matching the selected deployment'
        }
    }
    foreach ($mutation in @('database', 'license-key', 'off-site', 'license-type', 'filename-type', 'duplicate', 'flattened')) {
        Test-Case "reject API configuration error $mutation" {
            switch ($mutation) {
                'database' { $script:localSettings.ConnectionStrings.MFA = '' }
                'license-key' { $script:localSettings.AppSettings.MfaServerLicense.ValidationKey = '' }
                'off-site' { $script:localSettings.AppSettings.MfaServerLicense.FilePath = 'E:\production' }
                'license-type' { $script:localSettings.AppSettings.MfaServerLicense.LicenseCode = @('secret-marker') }
                'filename-type' { $script:localSettings.AppSettings.MfaServerLicense.Filename = @('site.lic') }
            }
            $localText = $script:localSettings | ConvertTo-Json -Depth 10
            if ($mutation -eq 'duplicate') { $localText = '{"AppSettings":{"MfaServerLicense":{},"mfaserverlicense":"secret-marker"}}' }
            if ($mutation -eq 'flattened') { $localText = '{"ConnectionStrings:MFA":"secret-marker"}' }
            $script:bundle.files['appsettings.local.json'] = ConvertTo-EncodedFile $localText
            Save-Bundle
            Assert-Throws { & $prepareScript } 'API local settings|validation key|same-site|must be a string|Configuration JSON'
        } 'api'
    }
    Test-Case 'reject mismatched API runtime environment' {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'web.config'),
            '<configuration><system.webServer><aspNetCore><environmentVariables><environmentVariable name="ASPNETCORE_ENVIRONMENT" value="mfa-prod" /></environmentVariables></aspNetCore></system.webServer></configuration>')
        Assert-Throws { & $prepareScript } 'IIS environment must match'
    } 'api'
    Test-Case 'API whitespace license codes cannot override file licensing at runtime' {
        $script:localSettings.AppSettings.MfaServerLicense.LicenseCode = '   '
        $script:bundle.files['appsettings.local.json'] = ConvertTo-EncodedFile ($script:localSettings | ConvertTo-Json -Depth 10)
        Save-Bundle
        & $prepareScript
        $effective = Get-Content -LiteralPath (Join-Path $env:PUBLISH_DIR 'appsettings.local.json') -Raw | ConvertFrom-Json
        Assert-True ($effective.AppSettings.MfaServerLicense.LicenseCode -ceq '') 'Runtime uses file licensing, not a whitespace inline code.'
    } 'api'
    Test-Case 'reject a missing API environment settings file' {
        Remove-Item -LiteralPath (Join-Path $env:PUBLISH_DIR 'appsettings.mfa-sandbox.json')
        Assert-Throws { & $prepareScript } 'Could not find file'
    } 'api'
    Test-Case 'configuration cleanup also runs after preparation failure' {
        [IO.File]::WriteAllText((Join-Path $env:PUBLISH_DIR 'bin\site.lic'), 'secret-marker-leftover')
        $env:DEPLOYMENT_CONFIGURATION = ''
        Assert-Throws { & $prepareScript } 'selected environment requires'
        & $cleanupScript
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR 'bin\site.lic'))) 'Failure path removes sensitive files.'
    }
    Test-Case 'cleanup rejects an unexpected directory without deleting it' {
        $null = [IO.Directory]::CreateDirectory((Join-Path $env:PUBLISH_DIR 'web.config'))
        Assert-Throws { & $cleanupScript } 'ordinary file'
        Assert-True (Test-Path -LiteralPath (Join-Path $env:PUBLISH_DIR 'web.config') -PathType Container) 'Unexpected target retained.'
    }
    Test-Case 'preparation and cleanup reject reparse-point parents' {
        $binPath = Join-Path $env:PUBLISH_DIR 'bin'
        $otherPath = Join-Path $script:fixture 'other'
        $null = [IO.Directory]::CreateDirectory($otherPath)
        Remove-Item -LiteralPath (Join-Path $binPath 'SurePassAdmin.dll')
        [IO.Directory]::Delete($binPath)
        $null = New-Item -ItemType Junction -Path $binPath -Target $otherPath
        try {
            Assert-Throws { & $prepareScript } 'Reparse point'
            Assert-Throws { & $cleanupScript } 'Reparse point'
        } finally { [IO.Directory]::Delete($binPath) }
    }
    Test-Case 'preparation and cleanup reject a non-owned publish directory' {
        $env:PUBLISH_DIR = Join-Path $script:fixture 'other'
        $null = [IO.Directory]::CreateDirectory($env:PUBLISH_DIR)
        Assert-Throws { & $prepareScript } 'owned workspace publish'
        Assert-Throws { & $cleanupScript } 'owned publish directory'
    }
    Assert-True ($workflowText.IndexOf('name: Prepare and validate deployment configuration') -lt
        $workflowText.IndexOf('name: Deploy and verify')) 'Policy runs before remoting.'
    Assert-True ($workflowText -match "(?m)^        if:.*always\(\).*APP_NAME.*api.*mfa") 'Cleanup executes after both success and failure.'
    Write-Host "RESULT: $script:passed payload-policy tests passed; no real credentials, WinRM, HTTP or IIS calls."
} finally {
    foreach ($variableName in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($variableName, $savedEnvironment[$variableName])
    }
}
