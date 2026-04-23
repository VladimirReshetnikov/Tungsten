@{
    RootModule = "Tungsten.psm1"
    ModuleVersion = "0.1.0"
    GUID = "2af0c24f-2be4-4bbb-a6ce-1e1dbf274f4f"
    Author = "OpenAI Codex"
    CompanyName = "OpenAI"
    Copyright = "MIT-0"
    PowerShellVersion = "7.4"
    FunctionsToExport = @(
        "Find-TungstenDocumentation",
        "Get-TungstenDocumentationPage",
        "Get-TungstenEnvironment",
        "Get-TungstenNotebook",
        "Invoke-TungstenFrontEnd",
        "Invoke-TungstenKernel",
        "Invoke-TungstenNotebookAssistant",
        "New-TungstenNotebook",
        "Open-TungstenDocumentation",
        "Open-TungstenNotebook",
        "Set-TungstenNotebook"
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
