[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^(api|mfa)-(alpha|dev|sandbox)\.surepassid\.com$')][string]$SiteName,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$UploadId,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$ExpectedJournalSha256
)
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'sandbox-app' -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run locally on sandbox-app in Windows PowerShell 5.1, never through the deployment endpoint.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Local elevated operator recovery is required.'
}
if ($PSCmdlet.ShouldProcess($SiteName, 'Restore previous release if replacement began, verify HTTPS health, and clear the recovery journal')) {
    $modulePath = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\SandboxDeployment\2.0.0\SandboxDeployment.psd1'
    $module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop
    & $module {
        param($Name, $Identifier, $JournalHash)
        Repair-SandboxDeployment -SiteName $Name -UploadId $Identifier -ExpectedJournalSha256 $JournalHash
    } $SiteName $UploadId $ExpectedJournalSha256
}
