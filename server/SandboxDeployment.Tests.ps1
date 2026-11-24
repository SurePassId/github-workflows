[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'SandboxDeployment\SandboxDeployment.psd1'
$module = Import-Module $manifestPath -Force -PassThru
$script:passed = 0

try {
    & $module {
        $script:passed = 0
        $script:originals = @{}
        foreach ($name in @('Get-SandboxTarget', 'Get-SandboxStagingRoot', 'Get-SandboxCaller',
            'Get-SandboxFreeBytes', 'Open-SandboxPrivateFile', 'Wait-SandboxHealth', 'Set-SandboxIisState',
            'Invoke-SandboxAppCmd', 'Set-SandboxContent', 'New-SandboxBackup', 'Write-SandboxJournal',
            'Expand-SandboxPackage', 'Invoke-SandboxHealthRequest', 'Clear-SandboxJournal')) {
            $script:originals[$name] = (Get-Item "Function:\$name").ScriptBlock
        }
        function script:Get-SandboxStagingRoot { return $script:staging }
        function script:Get-SandboxTarget {
            param([string]$SiteName)
            if ($SiteName -cne $script:siteName) { throw 'Site not authorized in test.' }
            Assert-SandboxTree $script:site
            return [pscustomobject]@{ SiteName = $SiteName; Path = $script:site }
        }
        function script:Get-SandboxCaller { return $script:caller }
        function script:Get-SandboxFreeBytes { param($Path); return $script:freeBytes }
        function script:Open-SandboxPrivateFile {
            param([string]$Path)
            return [IO.File]::Open($Path, 'CreateNew', 'ReadWrite', 'None')
        }
        function script:Get-WebsiteState { param($Name); return @{ Value = $script:siteState } }
        function script:Get-WebAppPoolState { param($Name); return @{ Value = $script:poolState } }
        function script:Set-SandboxIisState {
            param($Kind, $SiteName, $State)
            $script:events.Add("$Kind/$State")
            if ($script:fault -eq 'partial-stop' -and $Kind -eq 'apppool' -and $State -eq 'Stopped' -and -not $script:stopFailed) {
                $script:stopFailed = $true
                throw 'Partial stop fault.'
            }
            if ($script:fault -in @('start', 'rollback-cleanup') -and $State -eq 'Started' -and -not $script:startFailed) {
                $script:startFailed = $true
                throw 'Startup fault.'
            }
            if ($script:fault -eq 'start-all' -and $State -eq 'Started') {
                throw 'Persistent startup fault.'
            }
            if ($script:fault -eq 'space-after-stop' -and $Kind -eq 'apppool' -and $State -eq 'Stopped') { $script:freeBytes = 1 }
            if ($Kind -eq 'site') { $script:siteState = $State } else { $script:poolState = $State }
        }
        function script:Invoke-SandboxAppCmd {
            param($Arguments)
            $script:events.Add('workers-drained')
            if ($script:fault -eq 'workers') { return '<appcmd><WP /></appcmd>' }
            return '<appcmd />'
        }
        function script:Wait-SandboxHealth {
            param($SiteName)
            $script:healthCalls++
            $script:events.Add('health')
            if (($script:fault -in @('new-health', 'rollback-cleanup') -and $script:healthCalls -eq 2) -or
                ($script:fault -eq 'all-health' -and $script:healthCalls -ge 2) -or
                $script:fault -eq 'baseline-health') { throw 'Health probe fault (no response body).' }
        }
        function script:Set-SandboxContent {
            param($Source, $Destination)
            $script:events.Add('replace')
            if (($script:fault -eq 'replace' -or $script:fault -eq 'restore') -and -not $script:replaceFailed) {
                $script:replaceFailed = $true
                [IO.File]::WriteAllText((Join-Path $Destination 'partial.txt'), 'partial')
                throw 'Replacement fault.'
            }
            if ($script:fault -eq 'restore' -and $script:replaceFailed) { throw 'Restore fault.' }
            & $script:originals['Set-SandboxContent'] $Source $Destination
        }
        function script:New-SandboxBackup {
            param($Source, $Destination)
            $script:events.Add('backup')
            if ($script:fault -eq 'backup') { throw 'Backup fault.' }
            return & $script:originals['New-SandboxBackup'] $Source $Destination
        }
        function script:Write-SandboxJournal {
            param($Path, $Journal, [switch]$New)
            if ($script:fault -eq 'journal-commit' -and $Journal.Phase -eq 'Committed') { throw 'Journal commit fault.' }
            if ($script:fault -eq 'journal-new' -and $New) { throw 'Journal creation fault.' }
            if ($script:fault -eq 'journal-replace' -and $Journal.Phase -eq 'Replacing') { throw 'Journal replacement fault.' }
            & $script:originals['Write-SandboxJournal'] $Path $Journal -New:$New
        }
        function script:Clear-SandboxJournal {
            param($Path)
            if ($script:fault -in @('cleanup', 'rollback-cleanup')) { throw 'Journal cleanup fault.' }
            & $script:originals['Clear-SandboxJournal'] $Path
        }
        function script:Expand-SandboxPackage {
            param($Stream, $Destination)
            if ($script:fault -eq 'extract') { throw 'Extraction fault.' }
            & $script:originals['Expand-SandboxPackage'] $Stream $Destination
        }
        function script:New-TestArchive {
            param([string[]]$Names = @('web.config', 'bin/SurePassAdmin.dll'), [switch]$Link)
            $stream = [IO.MemoryStream]::new()
            $archive = [IO.Compression.ZipArchive]::new($stream, 'Create', $true)
            try {
                foreach ($name in $Names) {
                    $entry = $archive.CreateEntry($name)
                    if ($Link) { $entry.ExternalAttributes = -1610612736 }
                    if (-not $name.EndsWith('/')) {
                        $output = $entry.Open()
                        try {
                            $text = 'new-release'
                            if ($name -eq 'web.config') {
                                if ($script:siteName -like 'api-*') {
                                    $envName = ($script:siteName -split '[.-]')[1]
                                    $text = "<configuration><system.webServer><aspNetCore><environmentVariables><environmentVariable name=`"ASPNETCORE_ENVIRONMENT`" value=`"mfa-$envName`" /></environmentVariables></aspNetCore></system.webServer></configuration>"
                                } elseif ($script:siteName -like 'saml2-*') {
                                    $text = '<configuration><appSettings><add key="Connection.Server" value="db-dev" /></appSettings></configuration>'
                                } else {
                                    $text = '<configuration><appSettings><add key="MfaServerLicence.FilePath" value="E:\shared_licenses\dev" /><add key="MfaServerLicence.Filename" value="site.lic" /></appSettings></configuration>'
                                }
                            } elseif ($name -match '^appsettings(\.[^.]+)?\.json$') {
                                $text = '{}'
                            } elseif ($name -eq 'logging.config') {
                                $text = '<log4net />'
                            }
                            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
                            $output.Write($bytes, 0, $bytes.Length)
                        } finally { $output.Dispose() }
                    }
                }
            } finally { $archive.Dispose() }
            $stream.Position = 0
            return ,$stream
        }
        function script:New-TestUpload {
            param([string[]]$Names = @('web.config', 'bin/SurePassAdmin.dll'))
            $identifier = New-SandboxUpload -SiteName $script:siteName
            $stream = New-TestArchive -Names $Names
            try {
                $script:packageHash = Get-SandboxHash $stream
                $ack = Add-SandboxUploadChunk $identifier 0 ([Convert]::ToBase64String($stream.ToArray()))
                if ($ack -isnot [long] -or $ack -ne $stream.Length) { throw 'Wrong acknowledgement.' }
            } finally { $stream.Dispose() }
            return $identifier
        }
        function script:Assert-Test {
            param([bool]$Condition, [string]$Message)
            if (-not $Condition) { throw "ASSERTION: $Message" }
        }
        function script:Assert-Failure {
            param([scriptblock]$Body, [string]$Pattern)
            $failure = $null
            try { & $Body | Out-Null } catch { $failure = $_ }
            Assert-Test ($null -ne $failure) 'Expected failure.'
            Assert-Test ($failure.Exception.Message -match $Pattern) "Expected $Pattern; got $($failure.Exception.Message)"
        }
        function script:Get-TestJournal {
            return Join-Path $script:staging 'mfa-sandbox.surepassid.com.recovery.json'
        }
        function script:Get-TestJournalHash {
            $input = [IO.File]::OpenRead((Get-TestJournal))
            try { return Get-SandboxHash $input } finally { $input.Dispose() }
        }
        function script:Test-Case {
            param([string]$Name, [scriptblock]$Body)
            $script:fixture = Join-Path ([IO.Path]::GetTempPath()) ('server-safety-tests-' + [guid]::NewGuid().ToString('N'))
            $script:staging = Join-Path $script:fixture 'staging'
            $script:site = Join-Path $script:fixture 'site'
            $null = [IO.Directory]::CreateDirectory($script:staging)
            $null = [IO.Directory]::CreateDirectory((Join-Path $script:site 'bin'))
            [IO.File]::WriteAllText((Join-Path $script:site 'web.config'), '<configuration />')
            [IO.File]::WriteAllText((Join-Path $script:site 'bin\SurePassAdmin.dll'), 'old-code')
            [IO.File]::WriteAllText((Join-Path $script:site 'bin\site.lic'), 'old-mutable-license')
            $script:caller = 'SANDBOX-APP\github-deploy'
            $script:siteName = 'mfa-sandbox.surepassid.com'
            $script:freeBytes = 100GB
            $script:fault = ''
            $script:healthCalls = 0
            $script:siteState = 'Started'
            $script:poolState = 'Started'
            $script:replaceFailed = $false
            $script:stopFailed = $false
            $script:startFailed = $false
            $script:events = [Collections.Generic.List[string]]::new()
            try {
                & $Body
                $script:passed++
                Write-Host "PASS $Name"
            } catch { throw "FAIL $Name : $($_.Exception.Message)" }
            finally {
                Assert-Test ([IO.Path]::GetDirectoryName($script:fixture) -ieq [IO.Path]::GetTempPath().TrimEnd('\')) 'Owned temporary parent.'
                Assert-Test ([IO.Path]::GetFileName($script:fixture) -cmatch '^server-safety-tests-[a-f0-9]{32}$') 'Owned fixture name.'
                Remove-Item -LiteralPath $script:fixture -Recurse -Force -ErrorAction Stop
            }
        }

        Test-Case 'manifest exports exactly the original four restricted commands' {
            Assert-Test ((Get-Module SandboxDeployment).ExportedFunctions.Count -eq 4) 'Four exports only.'
            Assert-Test (-not (Get-Module SandboxDeployment).ExportedFunctions.ContainsKey('Repair-SandboxDeployment')) 'Recovery is not a JEA command.'
            $role = Import-PowerShellDataFile -LiteralPath (Join-Path (Get-Module SandboxDeployment).ModuleBase 'RoleCapabilities\SurePassIDSandboxDeployer.psrc')
            Assert-Test ($role.ModulesToImport.Count -eq 1 -and $role.ModulesToImport[0] -ceq
                'C:\Program Files\WindowsPowerShell\Modules\SandboxDeployment\2.1.0\SandboxDeployment.psd1') 'Role pins the exact versioned manifest without constrained RequiredVersion initialization.'
            Assert-Test ($role.VisibleFunctions.Count -eq 4 -and $role.VisibleExternalCommands.Count -eq 0) 'No role expansion.'
        }
        Test-Case 'actual IIS target checks allow known MFA virtual directories and reject unknown virtual directories or mismatches' {
            function Import-Module { param($Name, $ErrorAction) }
            function Get-SandboxSiteMap {
                return @{
                    'mfa-dev.surepassid.com' = $script:site
                    'saml2-dev.surepassid.com' = $script:site
                }
            }
            function Get-Item {
                param($LiteralPath, [switch]$Force, $ErrorAction)
                if ($LiteralPath -like 'IIS:*') {
                    return @{ PhysicalPath = $script:mappedPath; ApplicationPool = $script:mappedPool }
                }
                return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
            }
            function Get-WebApplication {
                param($Site)
                if ($script:targetFault -eq 'child' -or ($script:targetFault -eq 'shared-child' -and -not $Site)) {
                    return @{ Path = '/child'; ApplicationPool = $script:mappedPool }
                }
            }
            function Get-WebVirtualDirectory {
                param($Site)
                if ($script:targetFault -eq 'virtual') { return @{ Path = '/virtual'; PhysicalPath = $script:site } }
                if ($script:targetFault -eq 'mfa-vdir-wrong-path') {
                    return @(
                        @{ Path = '/'; PhysicalPath = $script:site },
                        @{ Path = '/.well-known'; PhysicalPath = 'E:\wrong\path' }
                    )
                }
                if ($script:targetFault -eq 'mfa-vdirs') {
                    return @(
                        @{ Path = '/'; PhysicalPath = $script:site },
                        @{ Path = '/.well-known'; PhysicalPath = 'E:\iis_sites\well-known-common\dev' },
                        @{ Path = '/oath-ota-provision'; PhysicalPath = [IO.Path]::Combine($script:site, 'oath-ota-provision') },
                        @{ Path = '/otp-push-ota-provision'; PhysicalPath = [IO.Path]::Combine($script:site, 'otp-push-ota-provision') },
                        @{ Path = '/push-ota-provision'; PhysicalPath = [IO.Path]::Combine($script:site, 'push-ota-provision') }
                    )
                }
                return @{ Path = '/'; PhysicalPath = $script:site }
            }
            function Get-Website {
                if ($script:targetFault -eq 'shared') { return @{ Name = 'other'; ApplicationPool = 'mfa-dev.surepassid.com' } }
            }
            $script:mappedPath = $script:site
            $script:mappedPool = 'mfa-dev.surepassid.com'
            $script:targetFault = 'mfa-vdirs'
            $target = & $script:originals['Get-SandboxTarget'] 'mfa-dev.surepassid.com'
            Assert-Test ($target.Path -ceq $script:site) 'Approved MFA virtual directories accepted.'
            $script:mappedPool = 'saml2-dev.surepassid.com'
            $script:targetFault = ''
            $samlTarget = & $script:originals['Get-SandboxTarget'] 'saml2-dev.surepassid.com'
            Assert-Test ($samlTarget.Path -ceq $script:site) 'Approved SAML2 mapping accepted.'
            $script:targetFault = 'mfa-vdirs'
            Assert-Failure { & $script:originals['Get-SandboxTarget'] 'saml2-dev.surepassid.com' } 'approved mapping'
            foreach ($targetFault in @('child', 'virtual', 'mfa-vdir-wrong-path', 'shared', 'shared-child', 'path', 'pool')) {
                $script:targetFault = $targetFault
                $script:mappedPath = $script:site
                $script:mappedPool = 'mfa-dev.surepassid.com'
                if ($targetFault -eq 'path') { $script:mappedPath = Join-Path $script:fixture 'wrong' }
                if ($targetFault -eq 'pool') { $script:mappedPool = 'other' }
                Assert-Failure { & $script:originals['Get-SandboxTarget'] 'mfa-dev.surepassid.com' } 'approved mapping'
            }
            Assert-Failure { & $script:originals['Get-SandboxTarget'] 'mfa-prod.surepassid.com' } 'not authorized'
        }
        Test-Case 'completion uses real ZIP, payload checks, backup, content replacement and IIS start with deferred health check' {
            $identifier = New-TestUpload
            $result = Complete-SandboxDeployment $identifier $script:packageHash
            Assert-Test ($result.State -ceq 'Started' -and $result.HealthCheckMode -ceq 'Deferred' -and -not $result.HealthVerified -and $result.ModuleVersion -ceq '2.1.0') 'Deferred-health v2.1.0 receipt.'
            Assert-Test ($script:healthCalls -eq 0) 'HTTP health probes deferred.'
            Assert-Test ($script:events.IndexOf('workers-drained') -lt $script:events.IndexOf('backup')) 'Drain precedes backup.'
            Assert-Test ([IO.File]::ReadAllText((Join-Path $script:site 'bin\SurePassAdmin.dll')) -ceq 'new-release') 'New code deployed.'
            Assert-Test (-not (Test-Path -LiteralPath (Get-TestJournal))) 'Successful deployment cleared journal.'
            Assert-Test (Test-Path -LiteralPath $result.Backup) 'Backup retained after success.'
            Remove-SandboxUpload $identifier
            Assert-Test (-not (Test-Path -LiteralPath (Join-Path $script:staging $identifier))) 'Safe cleanup after terminal success.'
            Assert-Test (Test-Path -LiteralPath $result.Backup) 'Upload cleanup never deletes external backup.'
        }
        foreach ($fault in @('replace', 'partial-stop', 'backup', 'start', 'journal-replace', 'space-after-stop', 'workers')) {
            Test-Case "recover original release after $fault" {
                $identifier = New-TestUpload
                $script:fault = $fault
                Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Previous release restored and IIS started'
                Assert-Test ([IO.File]::ReadAllText((Join-Path $script:site 'bin\SurePassAdmin.dll')) -ceq 'old-code') 'Original code restored.'
                Assert-Test ([IO.File]::ReadAllText((Join-Path $script:site 'bin\site.lic')) -ceq 'old-mutable-license') 'Original mutable license restored.'
                Assert-Test ([IO.File]::ReadAllText((Join-Path $script:site 'web.config')) -ceq '<configuration />') 'Original configuration restored.'
                Assert-Test (-not (Test-Path -LiteralPath (Get-TestJournal))) 'Verified recovery unblocks site.'
                Assert-Test ($script:siteState -eq 'Started' -and $script:poolState -eq 'Started') 'Partial IIS state recovered.'
                Assert-Test (Test-Path -LiteralPath (Join-Path $script:staging $identifier)) 'Failure retains owned upload for inspection.'
            }
        }
        foreach ($fault in @('start-all', 'restore')) {
            Test-Case "failed recovery $fault durably blocks create append complete and remove" {
                $identifier = New-TestUpload
                $script:fault = $fault
                Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Deployment failed:.*Recovery failed:.*site remains blocked'
                Assert-Test (Test-Path -LiteralPath (Get-TestJournal)) 'Journal survives released handles.'
                Assert-Failure { New-SandboxUpload 'mfa-sandbox.surepassid.com' } 'unresolved deployment journal'
                Assert-Failure { Add-SandboxUploadChunk $identifier 0 'AQ==' } 'unresolved deployment journal'
                Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'unresolved deployment journal'
                Assert-Failure { Remove-SandboxUpload $identifier } 'unresolved deployment journal'
                $script:fault = ''
                $result = Repair-SandboxDeployment 'mfa-sandbox.surepassid.com' $identifier (Get-TestJournalHash)
                Assert-Test ($result.State -ceq 'Started' -and $result.ModuleVersion -ceq '2.1.0') 'Operator recovery restarted IIS.'
                Assert-Test (-not (Test-Path -LiteralPath (Get-TestJournal))) 'Only verified recovery cleared journal.'
                Assert-Test ([IO.File]::ReadAllText((Join-Path $script:site 'bin\site.lic')) -ceq 'old-mutable-license') 'Operator restores consistent release.'
            }
        }
        Test-Case 'lost successful response / journal commit failure retains recoverable prior release' {
            $identifier = New-TestUpload
            $script:fault = 'journal-commit'
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Journal commit fault'
            Assert-Test (Test-Path -LiteralPath (Get-TestJournal)) 'Durable intent retained.'
            $script:fault = ''
            $null = Repair-SandboxDeployment 'mfa-sandbox.surepassid.com' $identifier (Get-TestJournalHash)
            Assert-Test ([IO.File]::ReadAllText((Join-Path $script:site 'bin\SurePassAdmin.dll')) -ceq 'old-code') 'Interrupted transaction rolled back deliberately.'
        }
        Test-Case 'successful deploy followed by cleanup failure is not reported as success' {
            $identifier = New-TestUpload
            $script:fault = 'cleanup'
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Deployment completed and IIS started, but journal cleanup failed'
            Assert-Test (Test-Path -LiteralPath (Get-TestJournal)) 'Committed journal remains to block a later deployment.'
            Assert-Failure { Remove-SandboxUpload $identifier } 'unresolved'
            $script:fault = ''
            $null = Repair-SandboxDeployment 'mfa-sandbox.surepassid.com' $identifier (Get-TestJournalHash)
        }
        Test-Case 'rollback cleanup failure reports original failure and retains the block' {
            $identifier = New-TestUpload
            $script:fault = 'rollback-cleanup'
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Deployment failed:.*Startup fault.*Previous release restored and IIS started; journal cleanup failed'
            Assert-Test (Test-Path -LiteralPath (Get-TestJournal)) 'Recovered but unresolved cleanup remains blocked.'
        }
        foreach ($fault in @('extract', 'journal-new')) {
            Test-Case "pre-stop $fault leaves release untouched without a journal" {
                $identifier = New-TestUpload
                $script:fault = $fault
                Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'fault'
                Assert-Test (-not $script:events.Contains('site/Stopped')) 'No IIS stop.'
                Assert-Test (-not (Test-Path -LiteralPath (Get-TestJournal))) 'No destructive intent recorded.'
            }
        }
        Test-Case 'hash mismatch rejects package before extraction or IIS stop' {
            $identifier = New-TestUpload
            Assert-Failure { Complete-SandboxDeployment $identifier ('A' * 64) } 'Package hash mismatch'
            Assert-Test (-not $script:events.Contains('site/Stopped')) 'No IIS mutation.'
        }
        Test-Case 'API deployment succeeds with repo config and Key Vault (no appsettings.local.json or site.lic required)' {
            $script:siteName = 'api-dev.surepassid.com'
            $identifier = New-TestUpload -Names @('web.config', 'SurePassIdApiServer.dll', 'logging.config',
                'appsettings.json', 'appsettings.mfa-dev.json')
            $result = Complete-SandboxDeployment $identifier $script:packageHash
            Assert-Test ($result.State -ceq 'Started' -and $result.ModuleVersion -ceq '2.1.0') 'API deployment succeeded.'
            Assert-Test ([IO.File]::Exists((Join-Path $script:site 'SurePassIdApiServer.dll'))) 'New API assembly.'
        }
        Test-Case 'SAML2 deployment validates web.config and SurePassSSOIdentityProvider.dll without site.lic' {
            $script:siteName = 'saml2-dev.surepassid.com'
            $identifier = New-TestUpload -Names @('web.config', 'bin/SurePassSSOIdentityProvider.dll')
            $result = Complete-SandboxDeployment $identifier $script:packageHash
            Assert-Test ($result.State -ceq 'Started' -and $result.ModuleVersion -ceq '2.1.0') 'SAML2 deployment succeeded.'
            Assert-Test ([IO.File]::Exists((Join-Path $script:site 'bin\SurePassSSOIdentityProvider.dll'))) 'New SAML2 assembly.'
        }
        Test-Case 'backup collision refuses deployment before a journal or IIS stop' {
            $identifier = New-TestUpload
            foreach ($offset in @(-1, 0, 1, 2)) {
                $backupName = $script:siteName + '_' + [datetime]::UtcNow.AddSeconds($offset).ToString('yyyy-MM-dd_HHmmss') + '.zip'
                [IO.File]::WriteAllText((Join-Path $script:fixture $backupName), 'existing backup')
            }
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Backup timestamp collision'
            Assert-Test (-not $script:events.Contains('site/Stopped')) 'No IIS stop on backup name collision.'
        }
        Test-Case 'package read handle prevents modification through hashing and extraction' {
            $identifier = New-TestUpload
            $packagePath = Join-Path (Join-Path $script:staging $identifier) 'package.zip'
            $reader = [IO.File]::Open($packagePath, 'Open', 'Read', 'Read')
            try {
                Assert-Failure { [IO.File]::Open($packagePath, 'Open', 'Write', 'None') } 'being used|another process'
                Assert-Failure { Add-SandboxUploadChunk $identifier 0 'AQ==' } 'being used|another process'
            } finally { $reader.Dispose() }
        }
        Test-Case 'insufficient actual volume capacity rejects before IIS stop' {
            $identifier = New-TestUpload
            $script:freeBytes = 1
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Insufficient free space'
            Assert-Test (-not $script:events.Contains('site/Stopped')) 'No IIS mutation.'
        }
        Test-Case 'capacity aggregates staging and site reserves on the same volume' {
            $script:freeBytes = 128MB + 800
            Assert-SandboxCapacity $script:site 100 200
            $script:freeBytes--
            Assert-Failure { Assert-SandboxCapacity $script:site 100 200 } 'Insufficient free space'
            $script:freeBytes = 64MB + 500
            Assert-SandboxCapacity 'E:\isolated-site' 100 200
        }
        foreach ($missing in @('web.config', 'bin/SurePassAdmin.dll')) {
            Test-Case "missing required payload file $missing never falls back to live" {
                $names = @('web.config', 'bin/SurePassAdmin.dll') | Where-Object { $_ -cne $missing }
                $identifier = New-TestUpload -Names $names
                Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Invalid staged XML|Required staged assembly'
                Assert-Test (-not $script:events.Contains('site/Stopped')) 'No live-file fallback.'
            }
        }
        Test-Case 'stopped site can be deployed and started when health check is deferred' {
            $identifier = New-TestUpload
            $script:siteState = 'Stopped'
            $script:poolState = 'Stopped'
            $result = Complete-SandboxDeployment $identifier $script:packageHash
            Assert-Test ($result.State -ceq 'Started' -and $script:siteState -eq 'Started' -and $script:poolState -eq 'Started') 'Stopped site deployed and started.'
        }
        Test-Case 'wrong caller cannot append complete or remove another upload' {
            $identifier = New-TestUpload
            $script:caller = 'other'
            Assert-Failure { Add-SandboxUploadChunk $identifier 0 'AQ==' } 'different authenticated caller'
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'different authenticated caller'
            Assert-Failure { Remove-SandboxUpload $identifier } 'different authenticated caller'
        }
        Test-Case 'authenticated remoting identity is used instead of the transient JEA virtual account' {
            $PSSenderInfo = [pscustomobject]@{ UserInfo = [pscustomobject]@{ Identity = [pscustomobject]@{ Name = 'sandbox-app\Github-Deploy' } } }
            $owner = & $script:originals['Get-SandboxCaller']
            Assert-Test ($owner -ceq 'SANDBOX-APP\GITHUB-DEPLOY') 'Durable authenticated owner, case normalized across sessions.'
        }
        Test-Case 'legacy or path-injected upload metadata cannot drive lock paths or deletion' {
            $identifier = New-TestUpload
            $metadataPath = Join-Path (Join-Path $script:staging $identifier) 'metadata.json'
            [IO.File]::WriteAllText($metadataPath, '{"SiteName":"mfa-sandbox.surepassid.com"}')
            Assert-Failure { Remove-SandboxUpload $identifier } 'Legacy or invalid upload metadata'
            $metadata = @{ Version = 2; Owner = $script:caller; CreatedUtc = [datetime]::UtcNow.ToString('o'); SiteName = '..\outside' }
            $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath
            Assert-Failure { Add-SandboxUploadChunk $identifier 0 'AQ==' } 'metadata version/site'
            Assert-Failure { Open-SandboxLock '..\outside.lock' } 'Invalid lock identity'
            Assert-Test ([IO.Directory]::Exists((Join-Path $script:staging $identifier))) 'Invalid staging is never guessed or removed.'
        }
        Test-Case 'expired uploads may be removed by owner but not appended or completed' {
            $identifier = New-TestUpload
            $metadataPath = Join-Path (Join-Path $script:staging $identifier) 'metadata.json'
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            $metadata.CreatedUtc = [datetime]::UtcNow.AddDays(-2).ToString('o')
            $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath
            Assert-Failure { Add-SandboxUploadChunk $identifier 0 'AQ==' } 'expired'
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'expired'
            Remove-SandboxUpload $identifier
        }
        Test-Case 'offset mismatch and malformed/empty chunks do not modify upload' {
            $identifier = New-SandboxUpload 'mfa-sandbox.surepassid.com'
            Assert-Failure { Add-SandboxUploadChunk $identifier 1 'AQ==' } 'offset mismatch'
            Assert-Failure { Add-SandboxUploadChunk $identifier 0 '====' } 'Base-64'
            Assert-Failure { Add-SandboxUploadChunk $identifier 0 ' ' } 'Empty chunks'
            Assert-Test ((Get-Item -LiteralPath (Join-Path (Join-Path $script:staging $identifier) 'package.zip')).Length -eq 0) 'No failed append wrote bytes.'
        }
        Test-Case 'upload lock excludes append completion and removal across sessions' {
            $identifier = New-TestUpload
            $heldLock = Open-SandboxLock "$identifier.upload.lock"
            try {
                Assert-Failure { Add-SandboxUploadChunk $identifier 0 'AQ==' } 'being used|another process'
                Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'being used|another process'
                Assert-Failure { Remove-SandboxUpload $identifier } 'being used|another process'
            } finally { $heldLock.Dispose() }
        }
        Test-Case 'site lock excludes all uploads for that site including different IDs' {
            $identifier = New-TestUpload
            $heldLock = Open-SandboxLock 'mfa-sandbox.surepassid.com.lock'
            try {
                Assert-Failure { New-SandboxUpload 'mfa-sandbox.surepassid.com' } 'being used|another process'
                Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'being used|another process'
                Assert-Failure { Remove-SandboxUpload $identifier } 'being used|another process'
            } finally { $heldLock.Dispose() }
        }
        foreach ($names in @(
            @('../escape'), @('/absolute'), @('dir/../../escape'), @('C:/escape'), @('data:stream'),
            @('COM0.txt'), @('tail.'), @('duplicate', 'DUPLICATE'), @('file', 'file/child'), @('empty/')
        )) {
            Test-Case "archive rejects $($names -join ',')" {
                $stream = New-TestArchive -Names $names
                try { Assert-Failure { Get-SandboxArchiveInfo $stream } 'Unsafe|Duplicate|collision|no files' }
                finally { $stream.Dispose() }
            }
        }
        Test-Case 'archive rejects symbolic links' {
            $stream = New-TestArchive -Link
            try { Assert-Failure { Get-SandboxArchiveInfo $stream } 'links and special' }
            finally { $stream.Dispose() }
        }
        Test-Case 'extraction never writes beyond validated ZIP length even with understated metadata' {
            $originalStream = New-TestArchive -Names @('payload.txt')
            try { $bytes = $originalStream.ToArray() } finally { $originalStream.Dispose() }
            for ($idx = 0; $idx -le $bytes.Length - 28; $idx++) {
                if ([BitConverter]::ToUInt32($bytes, $idx) -eq 0x02014b50) {
                    [Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $bytes, $idx + 24, 4)
                    break
                }
            }
            $stream = [IO.MemoryStream]::new($bytes, $false)
            try {
                $expandedBytes = Get-SandboxArchiveInfo $stream
                Assert-Test ($expandedBytes -eq 1) 'Test archive header declares one byte.'
                $destination = Join-Path $script:fixture 'bounded-extract'
                try { Expand-SandboxPackage $stream $destination }
                catch {
                    Assert-Test ($_.Exception.Message -match 'exceeded.*length|length mismatch|corrupt|invalid|CRC32') 'Framework must reject excess data or bound its own entry stream.'
                }
                Assert-Test ((Get-Item -LiteralPath (Join-Path $destination 'payload.txt')).Length -le 1) 'No runtime writes more than the validated expanded length.'
            } finally { $stream.Dispose() }
        }
        Test-Case 'reparse-point trees are rejected before enumeration' {
            $link = Join-Path $script:staging 'link'
            $null = New-Item -ItemType Junction -Path $link -Target $script:site
            try { Assert-Failure { Assert-SandboxTree $script:staging } 'Reparse points' }
            finally { [IO.Directory]::Delete($link) }
        }
        Test-Case 'recovery rejects stale journal hash and tampered backup without clearing block' {
            $identifier = New-TestUpload
            $script:fault = 'start-all'
            Assert-Failure { Complete-SandboxDeployment $identifier $script:packageHash } 'Recovery failed'
            $script:fault = ''
            Assert-Failure { Repair-SandboxDeployment 'mfa-sandbox.surepassid.com' $identifier ('A' * 64) } 'Journal changed'
            $journal = Get-Content -LiteralPath (Get-TestJournal) -Raw | ConvertFrom-Json
            [IO.File]::WriteAllText((Join-Path $script:fixture $journal.BackupName), 'tampered')
            Assert-Failure { Repair-SandboxDeployment 'mfa-sandbox.surepassid.com' $identifier (Get-TestJournalHash) } 'backup hash mismatch'
            Assert-Test (Test-Path -LiteralPath (Get-TestJournal)) 'Block retained.'
        }
        Test-Case 'interrupted prepared transaction recovers a partial IIS stop without a backup restore' {
            $identifier = New-TestUpload
            $journal = [pscustomobject]@{
                Version = 2; UploadId = $identifier; SiteName = $script:siteName; Phase = 'Prepared'
                BackupName = $script:siteName + '_2026-11-10_120000.zip'; BackupSha256 = ''
            }
            Write-SandboxJournal (Get-TestJournal) $journal -New
            $script:siteState = 'Stopped'
            Assert-Failure { New-SandboxUpload $script:siteName } 'unresolved'
            $null = Repair-SandboxDeployment $script:siteName $identifier (Get-TestJournalHash)
            Assert-Test ($script:siteState -eq 'Started' -and -not $script:events.Contains('replace')) 'Existing release restarted and verified, not copied from an incomplete backup.'
            Assert-Test (-not (Test-Path -LiteralPath (Get-TestJournal))) 'Verified interrupted-stop recovery unblocks site.'
        }
        Test-Case 'operator recovery rejects journal path traversal and a different upload' {
            $identifier = New-TestUpload
            $journal = [pscustomobject]@{
                Version = 2; UploadId = $identifier; SiteName = $script:siteName; Phase = 'Replacing'
                BackupName = '..\outside.zip'; BackupSha256 = 'A' * 64
            }
            Write-SandboxJournal (Get-TestJournal) $journal -New
            Assert-Failure { Repair-SandboxDeployment $script:siteName $identifier (Get-TestJournalHash) } 'Invalid recovery journal'
            $journal.BackupName = $script:siteName + '_2026-11-10_120000.zip'
            $journal.UploadId = 'a' * 32
            Write-SandboxJournal (Get-TestJournal) $journal
            Assert-Failure { Repair-SandboxDeployment $script:siteName $identifier (Get-TestJournalHash) } 'Invalid recovery journal'
            Assert-Test (-not $script:events.Contains('replace')) 'Invalid metadata never drives filesystem replacement.'
        }
        Test-Case 'unqualified app routes fail closed, not a caller-selected URL' {
            foreach ($siteName in @('oidc-alpha.surepassid.com', 'push-dev.surepassid.com', 'api-prod.surepassid.com', 'api-sandbox.surepassid.com.evil')) {
                Assert-Failure { Get-SandboxHealthUrl $siteName } 'not enabled'
                Assert-Failure { Assert-SandboxDeployableSite $siteName } 'not enabled'
            }
            Assert-Test ((Get-SandboxHealthUrl 'api-alpha.surepassid.com') -ceq 'https://api-alpha.surepassid.com/status') 'Pinned API health route.'
            Assert-Test ((Get-SandboxHealthUrl 'saml2-dev.surepassid.com') -ceq 'https://saml2-dev.surepassid.com/server/HealthCheck.aspx') 'Pinned SAML2 health route.'
        }
        Test-Case 'archive thresholds accept exact limits and reject one byte or entry beyond' {
            Assert-SandboxArchiveLimits 4GB 8GB 100000
            foreach ($limits in @(@(0L, 0L, 1L), @((4GB + 1L), 1L, 1L),
                @(1L, (8GB + 1L), 1L), @(1L, 1L, 100001L), @(1L, 1L, 0L))) {
                Assert-Failure { Assert-SandboxArchiveLimits $limits[0] $limits[1] $limits[2] } 'archive limits'
            }
        }
        Test-Case 'actual health loop accepts only exact 200 and never bypasses retries on redirect or failure' {
            function script:Start-Sleep { param($Milliseconds) }
            function script:Invoke-SandboxHealthRequest {
                param($Url)
                $script:requestCount++
                Assert-Test ($Url -ceq 'https://mfa-sandbox.surepassid.com/server/HealthCheck.aspx') 'Only fixed approved route.'
                if ($script:requestStatus -eq 0) { throw 'Simulated TLS/request timeout.' }
                return $script:requestStatus
            }
            try {
                foreach ($status in @(200, 201, 204, 301, 302, 307, 401, 500, 0)) {
                    $script:requestStatus = $status
                    $script:requestCount = 0
                    if ($status -eq 200) {
                        & $script:originals['Wait-SandboxHealth'] 'mfa-sandbox.surepassid.com'
                        Assert-Test ($script:requestCount -eq 1) 'Exact 200 succeeds without delay.'
                    } else {
                        Assert-Failure { & $script:originals['Wait-SandboxHealth'] 'mfa-sandbox.surepassid.com' } 'exact HTTPS 200 required'
                        Assert-Test ($script:requestCount -eq 10) 'Readiness is bounded at 10 five-second requests.'
                    }
                }
                $requestSource = $script:originals['Invoke-SandboxHealthRequest'].ToString()
                Assert-Test ($requestSource -match 'AllowAutoRedirect = \$false' -and
                    $requestSource -match 'ResponseHeadersRead' -and $requestSource -match 'FromSeconds\(5\)' -and
                    $requestSource -match 'SslProtocols.*Tls12' -and $requestSource -notmatch 'Certificate.*Callback|ReadAsString|ReadAsByte') 'Default certificate validation, explicit TLS, timeout, headers only, redirects disabled.'
            } finally {
                Remove-Item Function:\Start-Sleep
                Set-Item Function:\Invoke-SandboxHealthRequest $script:originals['Invoke-SandboxHealthRequest']
            }
        }
        return $script:passed
    } | ForEach-Object { $script:passed = $_ }
    Write-Host "RESULT: $script:passed isolated server-safety tests passed; IIS, network and privileged ACL creation mocked."
} finally {
    Remove-Module $module -Force
}
