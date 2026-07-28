param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-TungstenContract {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$modulePath = Join-Path $projectRoot "pwsh/Tungsten.psd1"
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "tungsten-pwsh-contract-" + [Guid]::NewGuid().ToString("N")
)
$argumentsPath = Join-Path $tempDirectory "arguments.txt"
$previousExecutable = $env:TUNGSTEN_EXECUTABLE
$previousArgumentsPath = $env:TUNGSTEN_FAKE_ARGUMENTS_FILE

try {
    $null = New-Item -ItemType Directory -Path $tempDirectory

    if ($IsWindows) {
        $fakeExecutable = Join-Path $tempDirectory "fake-tungsten.cmd"
        @'
@echo off
> "%TUNGSTEN_FAKE_ARGUMENTS_FILE%" echo %*
set "TUNGSTEN_FAKE_EXIT_CODE=0"
echo %* | findstr /C:"--require-success" >nul && set "TUNGSTEN_FAKE_EXIT_CODE=1"
echo {"success":null,"failure_type":"KernelNotFound","stderr":"synthetic unavailable kernel"}
>&2 echo synthetic native stderr
exit /b %TUNGSTEN_FAKE_EXIT_CODE%
'@ | Set-Content -LiteralPath $fakeExecutable -Encoding Ascii
    }
    else {
        $fakeExecutable = Join-Path $tempDirectory "fake-tungsten"
        @'
#!/bin/sh
printf '%s\n' "$@" > "${TUNGSTEN_FAKE_ARGUMENTS_FILE}"
exit_code=0
for argument in "$@"; do
    if [ "$argument" = "--require-success" ]; then
        exit_code=1
    fi
done
printf '%s\n' '{"success":null,"failure_type":"KernelNotFound","stderr":"synthetic unavailable kernel"}'
printf '%s\n' 'synthetic native stderr' >&2
exit "$exit_code"
'@ | Set-Content -LiteralPath $fakeExecutable -Encoding utf8NoBOM
        & chmod +x -- $fakeExecutable
        if ($LASTEXITCODE -ne 0) {
            throw "Could not make the fake Tungsten executable runnable."
        }
    }

    $env:TUNGSTEN_EXECUTABLE = $fakeExecutable
    $env:TUNGSTEN_FAKE_ARGUMENTS_FILE = $argumentsPath
    Import-Module $modulePath -Force

    $contracts = @(
        [pscustomobject]@{
            Name = "Invoke-TungstenKernel"
            Command = "Invoke-TungstenKernel"
            Parameters = @{ Code = "1/0" }
        },
        [pscustomobject]@{
            Name = "Get-TungstenNotebookCellInlineBoxes"
            Command = "Get-TungstenNotebookCellInlineBoxes"
            Parameters = @{ Path = "synthetic.nb"; CellIndex = 1 }
        },
        [pscustomobject]@{
            Name = "Open-TungstenDocumentation"
            Command = "Open-TungstenDocumentation"
            Parameters = @{ Identifier = "paclet:ref/SyntheticFailure" }
        },
        [pscustomobject]@{
            Name = "Open-TungstenNotebook"
            Command = "Open-TungstenNotebook"
            Parameters = @{ Path = "synthetic.nb" }
        },
        [pscustomobject]@{
            Name = "Invoke-TungstenFrontEnd"
            Command = "Invoke-TungstenFrontEnd"
            Parameters = @{ Code = '$Failed' }
        },
        [pscustomobject]@{
            Name = "Invoke-TungstenNotebookAssistant"
            Command = "Invoke-TungstenNotebookAssistant"
            Parameters = @{
                Path = "synthetic.nb"
                Question = "Fail synthetically."
                CellIndex = 1
                Backend = "NotebookChatCell"
            }
        }
    )

    foreach ($contract in $contracts) {
        $nonStrictParameters = @{} + $contract.Parameters
        $payload = & $contract.Command @nonStrictParameters
        Assert-TungstenContract `
            -Condition ($null -eq $payload.success) `
            -Message "$($contract.Name) did not preserve an unavailable result in non-strict mode."
        Assert-TungstenContract `
            -Condition ($payload.failure_type -eq "KernelNotFound") `
            -Message "$($contract.Name) returned an unexpected non-strict failure payload."

        $nonStrictArguments = Get-Content -LiteralPath $argumentsPath -Raw
        Assert-TungstenContract `
            -Condition (-not $nonStrictArguments.Contains("--require-success")) `
            -Message "$($contract.Name) unexpectedly requested strict native behavior by default."

        $strictParameters = @{} + $contract.Parameters
        $strictParameters.RequireSuccess = $true
        $strictException = $null
        try {
            $null = & $contract.Command @strictParameters
        }
        catch {
            $strictException = $_
        }

        Assert-TungstenContract `
            -Condition ($null -ne $strictException) `
            -Message "$($contract.Name) accepted a nonzero structured failure in strict mode."
        Assert-TungstenContract `
            -Condition ($strictException.Exception.Message.Contains("exit code 1")) `
            -Message "$($contract.Name) did not surface the strict native exit code."

        $strictArguments = Get-Content -LiteralPath $argumentsPath -Raw
        Assert-TungstenContract `
            -Condition ($strictArguments.Contains("--require-success")) `
            -Message "$($contract.Name) did not pass --require-success in strict mode."
    }

    Write-Host "PowerShell strict-success contracts passed for $($contracts.Count) wrappers."
}
finally {
    if ($null -eq $previousExecutable) {
        Remove-Item Env:TUNGSTEN_EXECUTABLE -ErrorAction SilentlyContinue
    }
    else {
        $env:TUNGSTEN_EXECUTABLE = $previousExecutable
    }

    if ($null -eq $previousArgumentsPath) {
        Remove-Item Env:TUNGSTEN_FAKE_ARGUMENTS_FILE -ErrorAction SilentlyContinue
    }
    else {
        $env:TUNGSTEN_FAKE_ARGUMENTS_FILE = $previousArgumentsPath
    }

    Remove-Module Tungsten -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
