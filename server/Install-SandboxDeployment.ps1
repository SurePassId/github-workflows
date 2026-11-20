[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$StagePath,
    [string]$BackupRoot,
    [string]$PackagePath = 'C:\Windows\Temp\sandbox-deployment-v2-stage.zip',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedPackageSha256 = '47B0669C18C32AF041147F49CEF64B303AFDA057D6E2317202FCEDE45F525D56',
    [switch]$RepairRoleLayout
)
$ErrorActionPreference = 'Stop'

function Assert-InstallTree {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Reparse points are forbidden in installation paths.'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        foreach ($child in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            Assert-InstallTree $child.FullName
        }
    }
}

function Assert-InstallPrivateDirectory {
    param([string]$Path)
    Assert-InstallTree $Path
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { throw 'Installation backup and staging directories require protected private ACLs.' }
    $allowed = @('S-1-5-18', 'S-1-5-32-544')
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -notin $allowed) {
            throw 'Unexpected access in a private installation directory.'
        }
    }
    foreach ($requiredSid in $allowed) {
        if (-not @($rules | Where-Object {
            $_.IdentityReference.Value -eq $requiredSid -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                [Security.AccessControl.FileSystemRights]::FullControl
        }).Count) { throw 'SYSTEM/Administrators FullControl is required.' }
    }
}

function Assert-InstallIdle {
    $shells = @(Get-WSManInstance -ResourceURI 'shell' -Enumerate -ErrorAction Stop)
    if ($shells.Count) { throw 'WinRM shells are active. No sessions were closed; quiesce deployment before installing.' }
    $root = Join-Path $env:ProgramData 'SurePassID-SandboxDeploy'
    Assert-InstallPrivateDirectory $root
    $pending = @(Get-ChildItem -LiteralPath $root -Force | Where-Object {
        $_.Name -cmatch '^[a-f0-9]{32}$' -or $_.Name -like '*.recovery.json'
    })
    if ($pending.Count) { throw 'Uploads or recovery journals exist; operator review is required before installation.' }
}

function Assert-InstallFiles {
    param([string]$Root, [object[]]$Records)
    Assert-InstallTree $Root
    foreach ($record in $Records) {
        $path = Join-Path $Root $record.Path.Replace('/', '\')
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $record.Sha256) {
            throw "Installation source verification failed: $($record.Path)"
        }
    }
}

function Invoke-SandboxModuleSwitch {
    param([string]$PreparedPath, [string]$ModuleRoot, [string]$RetiredPath, [scriptblock]$Validate)
    if (Test-Path -LiteralPath $RetiredPath) { throw 'Retired-module destination already exists; nothing was moved.' }
    $oldMoved = $false
    $newMoved = $false
    try {
        [IO.Directory]::Move($ModuleRoot, $RetiredPath)
        $oldMoved = $true
        [IO.Directory]::Move($PreparedPath, $ModuleRoot)
        $newMoved = $true
        & $Validate | Out-Null
    } catch {
        $originalFailure = $_
        try {
            if ($newMoved) { [IO.Directory]::Move($ModuleRoot, $PreparedPath) }
            if ($oldMoved) { [IO.Directory]::Move($RetiredPath, $ModuleRoot) }
        } catch {
            throw "Installation failed: $($originalFailure.Exception.Message). Module rollback failed: $($_.Exception.Message). Keep $RetiredPath and $PreparedPath; do not resume deployment."
        }
        throw "Installation failed: $($originalFailure.Exception.Message). Previous module location restored; prepared files retained at $PreparedPath."
    }
}

function Get-SandboxInstalledFileRecords {
    param([object[]]$Records)
    foreach ($record in $Records) {
        if ($record.Path -like 'SandboxDeployment/*') {
            [pscustomobject]@{
                Path = $record.Path.Substring('SandboxDeployment/'.Length).Replace(
                    '2.0.0/RoleCapabilities/', 'RoleCapabilities/')
                Sha256 = $record.Sha256
            }
        }
    }
}

function New-SandboxModuleCandidate {
    param([string]$StagePath, [string]$PreparedPath)
    $versionPath = Join-Path $PreparedPath '2.0.0'
    $rolePath = Join-Path $PreparedPath 'RoleCapabilities'
    $null = [IO.Directory]::CreateDirectory($versionPath)
    $null = [IO.Directory]::CreateDirectory($rolePath)
    foreach ($fileName in @('SandboxDeployment.psd1', 'SandboxDeployment.psm1')) {
        Copy-Item -LiteralPath (Join-Path $StagePath "SandboxDeployment\2.0.0\$fileName") -Destination $versionPath
    }
    Copy-Item -LiteralPath (Join-Path $StagePath 'SandboxDeployment\2.0.0\RoleCapabilities\SurePassIDSandboxDeployer.psrc') `
        -Destination $rolePath
}

function Assert-SandboxRoleDiscovery {
    param([string]$ConfigurationPath)
    $configuration = Import-PowerShellDataFile -LiteralPath $ConfigurationPath
    if ('SurePassIDSandboxDeployer' -notin
        @($configuration.RoleDefinitions['SANDBOX-APP\github-deploy'].RoleCapabilities)) {
        throw 'Expected deployment account role mapping is missing.'
    }
    $roleFilter = [Func[string, bool]] {
        param($principalName)
        return $principalName -ieq 'SANDBOX-APP\github-deploy'
    }
    $state = [Management.Automation.Runspaces.InitialSessionState]::CreateFromSessionConfigurationFile(
        $ConfigurationPath, $roleFilter)
    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($state)
    try { $runspace.Open() } finally { $runspace.Dispose() }
}

function Set-SandboxRoleCapability {
    param([string]$CandidatePath, [string]$InstalledPath, [string]$BackupPath,
        [string]$ExpectedCurrentSha256, [string]$ExpectedNewSha256, [scriptblock]$Validate)
    if (Test-Path -LiteralPath $BackupPath) { throw 'Role backup already exists; nothing was replaced.' }
    if ((Get-FileHash -LiteralPath $InstalledPath -Algorithm SHA256).Hash -cne $ExpectedCurrentSha256 -or
        (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash -cne $ExpectedNewSha256) {
        throw 'Role replacement hashes do not match the reviewed pair.'
    }
    $replaced = $false
    try {
        [IO.File]::Replace($CandidatePath, $InstalledPath, $BackupPath)
        $replaced = $true
        if ((Get-FileHash -LiteralPath $InstalledPath -Algorithm SHA256).Hash -cne $ExpectedNewSha256) {
            throw 'Replaced role hash mismatch.'
        }
        & $Validate | Out-Null
    } catch {
        $originalFailure = $_
        try {
            if ($replaced) { [IO.File]::Replace($BackupPath, $InstalledPath, $CandidatePath) }
        } catch {
            throw "Role import repair failed: $($originalFailure.Exception.Message). Role rollback failed: $($_.Exception.Message). Preserve all paths and keep deployment paused."
        }
        throw "Role import repair failed: $($originalFailure.Exception.Message). Original role bytes preserved or restored."
    }
}

function Update-SandboxRoleImport {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$BackupRoot)
    if ($env:COMPUTERNAME -ine 'sandbox-app' -or $PSVersionTable.PSEdition -ne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5) { throw 'Run locally on sandbox-app using Windows PowerShell 5.1.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }
    $BackupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($BackupRoot) -ine [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\') -or
        [IO.Path]::GetFileName($BackupRoot) -cnotmatch '^SurePassID-DeployBackup-\d{8}-\d{6}-[a-f0-9]{32}$') {
        throw 'Use the previously verified ProgramData backup directory.'
    }
    Assert-InstallPrivateDirectory $BackupRoot
    Assert-InstallTree $SourcePath
    $expectedNew = 'D291405AEC00B4E80496D7D5A41C2972EB99CE7E43AB11758872F82834FE69F2'
    $expectedOld = 'CEF1AB6E32DD0DAEB5343E005158768569AFBB7D8285A5460BDC63525840D0C9'
    if ((Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash -cne $expectedNew) {
        throw 'The reviewed exact-path role file is required.'
    }
    $moduleRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\SandboxDeployment'
    Assert-InstallPrivateDirectory $moduleRoot
    # This repair accepts only the original reviewed v2 code and role snapshot.
    $currentRecords = @(
        @{ Path = '2.0.0/SandboxDeployment.psd1'; Sha256 = 'BE161AE6127CA383F75E88D0D835330E7939FFB9EA39F30A64CD72A6EC8CCC2D' }
        @{ Path = '2.0.0/SandboxDeployment.psm1'; Sha256 = '044358C40657AADB01947157E5FD025F9C6D93491C16F690B4FDFF51E5E1FEF0' }
        @{ Path = 'RoleCapabilities/SurePassIDSandboxDeployer.psrc'; Sha256 = $expectedOld }
    )
    Assert-InstallFiles $moduleRoot $currentRecords
    $installedPath = Join-Path $moduleRoot 'RoleCapabilities\SurePassIDSandboxDeployer.psrc'
    $rolePaths = @(foreach ($directory in ($env:PSModulePath -split ';' | Select-Object -Unique)) {
        if ($directory -and (Test-Path -LiteralPath $directory -PathType Container)) {
            Get-ChildItem -LiteralPath $directory -Recurse -File -Force -Filter 'SurePassIDSandboxDeployer.psrc'
        }
    }) | Sort-Object FullName -Unique
    if (@($rolePaths).Count -ne 1 -or $rolePaths.FullName -ine $installedPath) {
        throw 'Repair requires exactly one role at the module-root location.'
    }
    $endpoint = Get-PSSessionConfiguration -Name 'SurePassID.SandboxDeploy' -ErrorAction Stop
    $endpointHash = (Get-FileHash -LiteralPath $endpoint.ConfigFilePath -Algorithm SHA256).Hash
    if ($endpointHash -cne (Get-FileHash -LiteralPath (Join-Path $BackupRoot 'Endpoint.pssc') -Algorithm SHA256).Hash) {
        throw 'Endpoint configuration changed since backup.'
    }
    Assert-InstallIdle
    if ($PSCmdlet.ShouldProcess($installedPath, 'Replace only the reviewed role import specification; keep the exact versioned manifest path and command restrictions')) {
        $installationLock = [IO.File]::Open((Join-Path $BackupRoot 'module-switch.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $identifier = [guid]::NewGuid().ToString('N')
            $candidatePath = Join-Path $BackupRoot "RoleCandidate-v2-$identifier.psrc"
            $roleBackup = Join-Path $BackupRoot "RoleBeforeImportFix-v2-$identifier.psrc"
            Copy-Item -LiteralPath $SourcePath -Destination $candidatePath
            Assert-InstallIdle
            Set-SandboxRoleCapability $candidatePath $installedPath $roleBackup $expectedOld $expectedNew {
                Assert-InstallPrivateDirectory $moduleRoot
                $updatedRecords = @($currentRecords[0], $currentRecords[1],
                    @{ Path = 'RoleCapabilities/SurePassIDSandboxDeployer.psrc'; Sha256 = $expectedNew })
                Assert-InstallFiles $moduleRoot $updatedRecords
                Assert-SandboxRoleDiscovery $endpoint.ConfigFilePath
                if ((Get-FileHash -LiteralPath $endpoint.ConfigFilePath -Algorithm SHA256).Hash -cne $endpointHash) {
                    throw 'Endpoint configuration changed during repair.'
                }
            }
            [pscustomobject]@{
                InstalledVersion = '2.0.0'; RoleCapabilityPath = $installedPath; RoleBackupPath = $roleBackup
                NativeConstrainedInitializationPassed = $true
                EndpointConfigurationUnchanged = $true; LiveQualificationPending = $true
            } | Format-List
        } finally { $installationLock.Dispose() }
    }
}

function Move-SandboxRoleCapability {
    param([string]$ModuleRoot, [string]$ExpectedSha256, [scriptblock]$Validate)
    $source = Join-Path $ModuleRoot '2.0.0\RoleCapabilities\SurePassIDSandboxDeployer.psrc'
    $destinationDirectory = Join-Path $ModuleRoot 'RoleCapabilities'
    $destination = Join-Path $destinationDirectory 'SurePassIDSandboxDeployer.psrc'
    Assert-InstallTree $ModuleRoot
    if (Test-Path -LiteralPath $destination) { throw 'Root-level role already exists; stop for review.' }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $ExpectedSha256) {
        throw 'Installed role bytes do not match the verified package.'
    }
    $null = [IO.Directory]::CreateDirectory($destinationDirectory)
    $moved = $false
    try {
        [IO.File]::Move($source, $destination)
        $moved = $true
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $ExpectedSha256) {
            throw 'Moved role hash mismatch.'
        }
        & $Validate | Out-Null
    } catch {
        $originalFailure = $_
        try {
            if ($moved) { [IO.File]::Move($destination, $source) }
        } catch {
            throw "Role layout repair failed: $($originalFailure.Exception.Message). Role rollback failed: $($_.Exception.Message). Preserve both paths; keep deployment paused."
        }
        throw "Role layout repair failed: $($originalFailure.Exception.Message). Original role location preserved or restored."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($env:COMPUTERNAME -ine 'sandbox-app' -or $PSVersionTable.PSEdition -ne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5) { throw 'Run locally on sandbox-app using Windows PowerShell 5.1.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }
    if (-not $StagePath -or -not $BackupRoot) { throw 'StagePath and BackupRoot are required.' }
    $StagePath = [IO.Path]::GetFullPath($StagePath).TrimEnd('\')
    $BackupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
    $programData = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($StagePath) -ine $programData -or
        [IO.Path]::GetFileName($StagePath) -cnotmatch '^SurePassID-DeployStage-v2-[a-f0-9]{32}$' -or
        [IO.Path]::GetDirectoryName($BackupRoot) -ine $programData -or
        [IO.Path]::GetFileName($BackupRoot) -cnotmatch '^SurePassID-DeployBackup-\d{8}-\d{6}-[a-f0-9]{32}$') {
        throw 'Use the previously verified ProgramData staging and backup directories.'
    }
    Assert-InstallPrivateDirectory $BackupRoot
    Assert-InstallTree $StagePath
    Assert-InstallTree $PackagePath
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $package = [IO.File]::Open($PackagePath, 'Open', 'Read', 'Read')
    try {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $packageHash = [BitConverter]::ToString($algorithm.ComputeHash($package)).Replace('-', '') }
        finally { $algorithm.Dispose(); $package.Position = 0 }
        if ($packageHash -ine $ExpectedPackageSha256) {
            throw 'The package must match the explicitly approved SHA-256.'
        }
        $archive = [IO.Compression.ZipArchive]::new($package, 'Read', $true)
        try {
            $reader = [IO.StreamReader]::new($archive.GetEntry('package-manifest.json').Open())
            try { $records = @((($reader.ReadToEnd() | ConvertFrom-Json).Files)) } finally { $reader.Dispose() }
        } finally { $archive.Dispose() }
    } finally { $package.Dispose() }
    if ($records.Count -ne 4) { throw 'Unexpected pinned package manifest.' }
    Assert-InstallFiles $StagePath $records
    $moduleRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\SandboxDeployment'
    $endpoint = Get-PSSessionConfiguration -Name 'SurePassID.SandboxDeploy' -ErrorAction Stop
    $endpointHash = (Get-FileHash -LiteralPath $endpoint.ConfigFilePath -Algorithm SHA256).Hash
    if ($endpointHash -cne (Get-FileHash -LiteralPath (Join-Path $BackupRoot 'Endpoint.pssc') -Algorithm SHA256).Hash) {
        throw 'Endpoint configuration changed since backup; stop for review.'
    }
    $rolePaths = @(foreach ($directory in ($env:PSModulePath -split ';' | Select-Object -Unique)) {
        if ($directory -and (Test-Path -LiteralPath $directory -PathType Container)) {
            Get-ChildItem -LiteralPath $directory -Recurse -File -Force -Filter 'SurePassIDSandboxDeployer.psrc'
        }
    }) | Sort-Object FullName -Unique
    if ($RepairRoleLayout) {
        Assert-InstallPrivateDirectory $moduleRoot
        $versionedRecords = @($records | Where-Object { $_.Path -like 'SandboxDeployment/*' } | ForEach-Object {
            [pscustomobject]@{ Path = $_.Path.Substring('SandboxDeployment/'.Length); Sha256 = $_.Sha256 }
        })
        Assert-InstallFiles $moduleRoot $versionedRecords
        if (@($rolePaths).Count -ne 1 -or $rolePaths.FullName -ine
            (Join-Path $moduleRoot '2.0.0\RoleCapabilities\SurePassIDSandboxDeployer.psrc')) {
            throw 'Repair requires exactly one role at the original versioned location.'
        }
        $manifestPath = Join-Path $moduleRoot '2.0.0\SandboxDeployment.psd1'
        if ((Test-ModuleManifest -Path $manifestPath).Version -ne [version]'2.0.0') {
            throw 'Repair requires the verified v2 module.'
        }
        Assert-InstallIdle
        if ($PSCmdlet.ShouldProcess($moduleRoot, 'Move the verified v2 role to root-level RoleCapabilities; preserve versioned code and endpoint')) {
            $installationLock = [IO.File]::Open((Join-Path $BackupRoot 'module-switch.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            try {
                Assert-InstallIdle
                $roleRecord = $records | Where-Object { $_.Path -like '*/SurePassIDSandboxDeployer.psrc' }
                Move-SandboxRoleCapability $moduleRoot $roleRecord.Sha256 {
                    Assert-InstallPrivateDirectory $moduleRoot
                    Assert-InstallFiles $moduleRoot @(Get-SandboxInstalledFileRecords $records)
                    Assert-SandboxRoleDiscovery $endpoint.ConfigFilePath
                    if ((Get-FileHash -LiteralPath $endpoint.ConfigFilePath -Algorithm SHA256).Hash -cne $endpointHash) {
                        throw 'Endpoint configuration changed during repair.'
                    }
                }
                [pscustomobject]@{
                    InstalledVersion = '2.0.0'
                    RoleCapabilityPath = Join-Path $moduleRoot 'RoleCapabilities\SurePassIDSandboxDeployer.psrc'
                    NativeRoleDiscoveryPassed = $true
                    EndpointConfigurationUnchanged = $true
                    LiveQualificationPending = $true
                } | Format-List
            } finally { $installationLock.Dispose() }
        }
        return
    }
    $oldBackup = Join-Path $BackupRoot 'SandboxDeployment'
    Assert-InstallTree $moduleRoot
    Assert-InstallTree $oldBackup
    $originalFiles = @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -File -Force)
    if ($originalFiles.Count -ne 8 -or
        $originalFiles.Count -ne @(Get-ChildItem -LiteralPath $oldBackup -Recurse -File -Force).Count) {
        throw 'Installed v1 differs from the verified backup; no switch is permitted.'
    }
    foreach ($file in $originalFiles) {
        $relative = $file.FullName.Substring($moduleRoot.Length + 1)
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath (Join-Path $oldBackup $relative) -Algorithm SHA256).Hash) {
            throw 'Installed v1 changed since backup; no switch is permitted.'
        }
    }
    if (@($rolePaths).Count -ne 1 -or $rolePaths.FullName -ine
        (Join-Path $moduleRoot 'RoleCapabilities\SurePassIDSandboxDeployer.psrc')) {
        throw 'Unexpected or duplicate role capability; no switch is permitted.'
    }
    $currentManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $moduleRoot 'SandboxDeployment.psd1')
    if ($currentManifest.ModuleVersion -cne '1.0.0') { throw 'Only the verified v1-to-v2 transition is supported.' }
    Assert-InstallIdle
    if ($PSCmdlet.ShouldProcess($moduleRoot, 'Replace verified v1 with v2; preserve v1 outside PSModulePath; no endpoint or IIS changes')) {
        $installationLock = [IO.File]::Open((Join-Path $BackupRoot 'module-switch.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $identifier = [guid]::NewGuid().ToString('N')
            $preparedPath = Join-Path $BackupRoot "PreparedModule-v2-$identifier"
            $retiredPath = Join-Path $BackupRoot "RetiredModule-v1-$identifier"
            $null = [IO.Directory]::CreateDirectory($preparedPath)
            Set-Acl -LiteralPath $preparedPath -AclObject (Get-Acl -LiteralPath $BackupRoot)
            Assert-InstallPrivateDirectory $preparedPath
            New-SandboxModuleCandidate $StagePath $preparedPath
            $moduleRecords = @(Get-SandboxInstalledFileRecords $records)
            Assert-InstallFiles $preparedPath $moduleRecords
            $recoveryPath = Join-Path $BackupRoot "Repair-SandboxDeployment-v2-$identifier.ps1"
            Copy-Item -LiteralPath (Join-Path $StagePath 'Repair-SandboxDeployment.ps1') -Destination $recoveryPath
            $recoveryRecord = $records | Where-Object { $_.Path -ceq 'Repair-SandboxDeployment.ps1' }
            if ((Get-FileHash -LiteralPath $recoveryPath -Algorithm SHA256).Hash -cne $recoveryRecord.Sha256) {
                throw 'Recovery script copy verification failed.'
            }
            Assert-InstallIdle
            Invoke-SandboxModuleSwitch $preparedPath $moduleRoot $retiredPath {
                Assert-InstallPrivateDirectory $moduleRoot
                Assert-InstallFiles $moduleRoot $moduleRecords
                $manifestPath = Join-Path $moduleRoot '2.0.0\SandboxDeployment.psd1'
                $null = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
                $imported = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
                try {
                    if ($imported.Version -ne [version]'2.0.0' -or $imported.ExportedFunctions.Count -ne 4) {
                        throw 'Installed module version or exports mismatch.'
                    }
                } finally { Remove-Module -ModuleInfo $imported -Force -ErrorAction Stop }
                Assert-SandboxRoleDiscovery $endpoint.ConfigFilePath
                if ((Get-FileHash -LiteralPath $endpoint.ConfigFilePath -Algorithm SHA256).Hash -cne $endpointHash) {
                    throw 'Endpoint configuration changed during installation; deployment must stay paused.'
                }
            }
            [pscustomobject]@{
                InstalledVersion = '2.0.0'; ModulePath = Join-Path $moduleRoot '2.0.0\SandboxDeployment.psd1'
                RetiredModulePath = $retiredPath; RecoveryScriptPath = $recoveryPath
                EndpointConfigurationUnchanged = $true; LiveQualificationPending = $true
            } | Format-List
        } finally { $installationLock.Dispose() }
    }
}
