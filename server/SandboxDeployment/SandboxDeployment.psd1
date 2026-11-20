@{
    RootModule = 'SandboxDeployment.psm1'
    ModuleVersion = '2.0.0'
    GUID = '8663ab7b-0418-4fc8-beef-d0f9b494898f'
    PowerShellVersion = '5.1'
    Description = 'Restricted sandbox transport and health-qualified API/MFA deployment.'
    FunctionsToExport = @('New-SandboxUpload', 'Add-SandboxUploadChunk',
        'Complete-SandboxDeployment', 'Remove-SandboxUpload')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
