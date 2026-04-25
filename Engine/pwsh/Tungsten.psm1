Set-StrictMode -Version Latest

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

function Invoke-TungstenCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        throw "python was not found on PATH."
    }

    $previousPythonPath = $env:PYTHONPATH
    $sourceRoot = Join-Path $script:ProjectRoot "src"
    $separator = [System.IO.Path]::PathSeparator
    $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($previousPythonPath)) {
        $sourceRoot
    }
    else {
        "$sourceRoot$separator$previousPythonPath"
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        & $python.Source -m tungsten @Arguments > $stdoutFile 2> $stderrFile
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:PYTHONPATH = $previousPythonPath
    }

    try {
        $stdout = if (Test-Path -LiteralPath $stdoutFile) {
            Get-Content -LiteralPath $stdoutFile -Raw
        }
        else {
            ""
        }
        $stderr = if (Test-Path -LiteralPath $stderrFile) {
            Get-Content -LiteralPath $stderrFile -Raw
        }
        else {
            ""
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }

    if (-not $AllowFailure -and $exitCode -ne 0) {
        $details = @()
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $details += "stderr:`n$stderr"
        }
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $details += "stdout:`n$stdout"
        }

        $detailText = if ($details.Count -gt 0) {
            "`n$($details -join ([Environment]::NewLine + [Environment]::NewLine))"
        }
        else {
            ""
        }

        throw "Tungsten CLI failed with exit code $exitCode.$detailText"
    }

    $text = ($stdout | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json -Depth 100
}

function Get-TungstenNotebookAssistantSelectorArguments {
    [CmdletBinding(DefaultParameterSetName = "CellIndex")]
    param(
        [Parameter(Mandatory)]
        [string] $ParameterSetName,

        [int] $CellIndex,

        [int[]] $CellPath,

        [string] $ExpressionUuid,

        [int] $CellId,

        [string] $CellTag
    )

    switch ($ParameterSetName) {
        "CellIndex" {
            return @("--cell-index", $CellIndex.ToString())
        }
        "CellPath" {
            return @("--cell-path", ($CellPath -join ","))
        }
        "ExpressionUuid" {
            return @("--expression-uuid", $ExpressionUuid)
        }
        "CellId" {
            return @("--cell-id", $CellId.ToString())
        }
        "CellTag" {
            return @("--cell-tag", $CellTag)
        }
        default {
            throw "Unsupported notebook assistant selector parameter set '$ParameterSetName'."
        }
    }
}

function New-TungstenNotebookAssistantFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ErrorType,

        [Parameter(Mandatory)]
        [string] $Message,

        [hashtable] $Extra = @{},

        $Evaluation
    )

    $assistant = [ordered]@{
        success = $false
        error_type = $ErrorType
        error = $Message
    }

    foreach ($key in $Extra.Keys) {
        $assistant[$key] = $Extra[$key]
    }

    [pscustomobject]@{
        assistant_success = $false
        assistant = [pscustomobject] $assistant
        evaluation = $Evaluation
    }
}

function Resolve-TungstenWinDeskModulePath {
    [CmdletBinding()]
    param(
        [switch] $BuildIfNeeded = $true
    )

    $repoRoot = Resolve-Path (Join-Path $script:ProjectRoot "..\..")
    $winDeskProjectRoot = Join-Path $repoRoot "src\WinDesk\src\WinDesk.PowerShell"
    $winDeskProjectFile = Join-Path $winDeskProjectRoot "WinDesk.PowerShell.csproj"

    $findModule = {
        @(Get-ChildItem -Path $winDeskProjectRoot -Recurse -Filter "WinDesk.PowerShell.dll" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\bin\\(Debug|Release)\\" } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1)
    }

    $module = @(& $findModule)
    if ($module.Count -gt 0) {
        return $module[0].FullName
    }

    if (-not $BuildIfNeeded) {
        throw "WinDesk.PowerShell.dll was not found under $winDeskProjectRoot."
    }

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        throw "dotnet was not found on PATH, so Tungsten cannot build the required WinDesk PowerShell module."
    }

    & $dotnet.Source build $winDeskProjectFile "-v" "minimal" "-p:UseSharedCompilation=false" "-m:1"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed while building the WinDesk PowerShell module."
    }

    $module = @(& $findModule)
    if ($module.Count -eq 0) {
        throw "WinDesk.PowerShell.dll was still not found after building $winDeskProjectFile."
    }

    return $module[0].FullName
}

function Import-TungstenWinDeskModule {
    [CmdletBinding()]
    param(
        [switch] $BuildIfNeeded = $true
    )

    if ($null -ne (Get-Command Get-WinDeskWindow -ErrorAction SilentlyContinue)) {
        return
    }

    $modulePath = Resolve-TungstenWinDeskModulePath -BuildIfNeeded:$BuildIfNeeded
    Import-Module $modulePath -Force
}

function Wait-TungstenWinDeskWindowByTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Title,

        [int] $TimeoutMilliseconds = 10000,

        [int] $PollIntervalMilliseconds = 200
    )

    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $matches = @(Get-WinDeskWindow -VisibleOnly | Where-Object { $_.Title -eq $Title })
        if ($matches.Count -gt 0) {
            return ($matches |
                Sort-Object `
                    @{ Expression = { [int] $_.IsForeground }; Descending = $true }, `
                    @{ Expression = { if ($null -eq $_.ZOrder) { [int]::MaxValue } else { [int] $_.ZOrder } }; Descending = $false } |
                Select-Object -First 1)
        }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    while ([DateTimeOffset]::UtcNow -lt $deadline)

    return $null
}

function Get-TungstenEnvironment {
    [CmdletBinding()]
    param(
        [switch] $Probe
    )

    $cliArgs = @("env", "show")
    if ($Probe) {
        $cliArgs += "--probe"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Invoke-TungstenKernel {
    [CmdletBinding(DefaultParameterSetName = "Code")]
    param(
        [Parameter(Mandatory, ParameterSetName = "Code")]
        [string] $Code,

        [Parameter(Mandatory, ParameterSetName = "File")]
        [string] $File,

        [string] $WorkingDirectory,

        [switch] $FrontEnd,

        [switch] $RequireSuccess
    )

    $cliArgs = @("kernel", "eval")
    if ($PSCmdlet.ParameterSetName -eq "Code") {
        $cliArgs += @("--code", $Code)
    }
    else {
        $cliArgs += @("--file", $File)
    }

    if ($WorkingDirectory) {
        $cliArgs += @("--working-directory", $WorkingDirectory)
    }

    if ($FrontEnd) {
        $cliArgs += "--front-end"
    }

    if ($RequireSuccess) {
        $cliArgs += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs -AllowFailure:$RequireSuccess
}

function Convert-TungstenExpression {
    [CmdletBinding(DefaultParameterSetName = "Code")]
    param(
        [Parameter(Mandatory, ParameterSetName = "Code")]
        [string] $Code,

        [Parameter(Mandatory, ParameterSetName = "File")]
        [string] $File,

        [ValidateSet("input", "fullform", "standard")]
        [string] $Form = "input"
    )

    $cliArgs = @("expr", "parse", "--form", $Form)
    if ($PSCmdlet.ParameterSetName -eq "Code") {
        $cliArgs += @("--code", $Code)
    }
    else {
        $cliArgs += @("--file", $File)
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Invoke-TungstenExpression {
    [CmdletBinding(DefaultParameterSetName = "Code")]
    param(
        [Parameter(Mandatory, ParameterSetName = "Code")]
        [string] $Code,

        [Parameter(Mandatory, ParameterSetName = "File")]
        [string] $File,

        [ValidateSet("input", "fullform", "standard")]
        [string] $Form = "input"
    )

    $cliArgs = @("expr", "evaluate", "--form", $Form)
    if ($PSCmdlet.ParameterSetName -eq "Code") {
        $cliArgs += @("--code", $Code)
    }
    else {
        $cliArgs += @("--file", $File)
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Get-TungstenParserCorpus {
    [CmdletBinding()]
    param(
        [string] $CorpusRoot = "C:\TestData\wolfram\tungsten-wolfram-parser-corpus",

        [string[]] $Extension = @(),

        [string[]] $IncludeGlob = @(),

        [string[]] $ExcludeGlob = @(),

        [Nullable[int]] $MaxFiles = $null,

        [switch] $Shuffle,

        [int] $Seed = 0,

        [int] $Sample = 20
    )

    $cliArgs = @("parser-corpus", "discover", "--corpus-root", $CorpusRoot, "--sample", $Sample, "--seed", $Seed)
    foreach ($item in $Extension) {
        $cliArgs += @("--extension", $item)
    }
    foreach ($item in $IncludeGlob) {
        $cliArgs += @("--include-glob", $item)
    }
    foreach ($item in $ExcludeGlob) {
        $cliArgs += @("--exclude-glob", $item)
    }
    if ($null -ne $MaxFiles) {
        $cliArgs += @("--max-files", $MaxFiles)
    }
    if ($Shuffle) {
        $cliArgs += "--shuffle"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Compare-TungstenParserCorpus {
    [CmdletBinding()]
    param(
        [string] $CorpusRoot = "C:\TestData\wolfram\tungsten-wolfram-parser-corpus",

        [string] $OutDir,

        [string[]] $Extension = @(),

        [string[]] $IncludeGlob = @(),

        [string[]] $ExcludeGlob = @(),

        [Nullable[int]] $MaxFiles = $null,

        [double] $MaxFileMB = 2.0,

        [Nullable[int]] $MaxBytes = $null,

        [switch] $NoMaxBytes,

        [ValidateSet("input", "fullform", "standard")]
        [string] $Form = "input",

        [switch] $SkipWolfram,

        [int] $KernelBatchSize = 100,

        [int] $TungstenWorkers = 1,

        [int] $PreviewChars = 2000,

        [switch] $NoWrite,

        [switch] $IncludeResults,

        [switch] $Shuffle,

        [int] $Seed = 0,

        [switch] $FailOnTungstenGap,

        [switch] $FailOnMismatch
    )

    $cliArgs = @(
        "parser-corpus",
        "compare",
        "--corpus-root", $CorpusRoot,
        "--max-file-mb", $MaxFileMB,
        "--form", $Form,
        "--kernel-batch-size", $KernelBatchSize,
        "--tungsten-workers", $TungstenWorkers,
        "--preview-chars", $PreviewChars,
        "--seed", $Seed
    )

    if ($OutDir) {
        $cliArgs += @("--out-dir", $OutDir)
    }
    foreach ($item in $Extension) {
        $cliArgs += @("--extension", $item)
    }
    foreach ($item in $IncludeGlob) {
        $cliArgs += @("--include-glob", $item)
    }
    foreach ($item in $ExcludeGlob) {
        $cliArgs += @("--exclude-glob", $item)
    }
    if ($null -ne $MaxFiles) {
        $cliArgs += @("--max-files", $MaxFiles)
    }
    if ($null -ne $MaxBytes) {
        $cliArgs += @("--max-bytes", $MaxBytes)
    }
    if ($NoMaxBytes) {
        $cliArgs += "--no-max-bytes"
    }
    if ($SkipWolfram) {
        $cliArgs += "--skip-wolfram"
    }
    if ($NoWrite) {
        $cliArgs += "--no-write"
    }
    if ($IncludeResults) {
        $cliArgs += "--include-results"
    }
    if ($Shuffle) {
        $cliArgs += "--shuffle"
    }
    if ($FailOnTungstenGap) {
        $cliArgs += "--fail-on-tungsten-gap"
    }
    if ($FailOnMismatch) {
        $cliArgs += "--fail-on-mismatch"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function New-TungstenInlineBoxString {
    [CmdletBinding()]
    param(
        [string] $Prefix = "",

        [string[]] $BoxExpression = @(),

        [string] $Suffix = ""
    )

    $cliArgs = @("inline-box", "compose")
    if ($Prefix -ne "") {
        $cliArgs += @("--prefix", $Prefix)
    }
    foreach ($expression in $BoxExpression) {
        $cliArgs += @("--box-expr", $expression)
    }
    if ($Suffix -ne "") {
        $cliArgs += @("--suffix", $Suffix)
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Get-TungstenNotebookCellInlineBoxes {
    [CmdletBinding(DefaultParameterSetName = "CellIndex")]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = "CellIndex")]
        [int] $CellIndex,

        [Parameter(Mandatory, ParameterSetName = "CellPath")]
        [int[]] $CellPath,

        [Parameter(Mandatory, ParameterSetName = "ExpressionUuid")]
        [string] $ExpressionUuid,

        [Parameter(Mandatory, ParameterSetName = "CellId")]
        [int] $CellId,

        [Parameter(Mandatory, ParameterSetName = "CellTag")]
        [string] $CellTag,

        [string] $Prefix = "",

        [string] $Suffix = "",

        [ValidateRange(0, 2147483647)]
        [int] $ObjectIndex = 0,

        [switch] $AllObjects,

        [switch] $RequireSuccess
    )

    $selectorArgs = Get-TungstenNotebookAssistantSelectorArguments `
        -ParameterSetName $PSCmdlet.ParameterSetName `
        -CellIndex $CellIndex `
        -CellPath $CellPath `
        -ExpressionUuid $ExpressionUuid `
        -CellId $CellId `
        -CellTag $CellTag

    $cliArgs = @("inline-box", "from-cell", "--file", $Path) + $selectorArgs
    if ($Prefix -ne "") {
        $cliArgs += @("--prefix", $Prefix)
    }
    if ($Suffix -ne "") {
        $cliArgs += @("--suffix", $Suffix)
    }
    if ($AllObjects) {
        $cliArgs += "--all-objects"
    }
    else {
        $cliArgs += @("--object-index", $ObjectIndex.ToString())
    }
    if ($RequireSuccess) {
        $cliArgs += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs -AllowFailure:$RequireSuccess
}

function Get-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Invoke-TungstenCliJson -Arguments @("notebook", "inspect", "--file", $Path)
}

function New-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Title,

        [string[]] $Cell = @()
    )

    $cliArgs = @("notebook", "create", "--file", $Path)
    if ($Title) {
        $cliArgs += @("--title", $Title)
    }
    foreach ($entry in $Cell) {
        $cliArgs += @("--cell", $entry)
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Set-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Spec,

        [string] $OutFile
    )

    $cliArgs = @("notebook", "patch", "--file", $Path, "--spec", $Spec)
    if ($OutFile) {
        $cliArgs += @("--out", $OutFile)
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Find-TungstenDocumentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,

        [int] $Limit = 10,

        [string] $IndexPath,

        [switch] $Rebuild
    )

    $cliArgs = @("docs", "search", $Query, "--limit", $Limit.ToString())
    if ($IndexPath) {
        $cliArgs += @("--index-path", $IndexPath)
    }
    if ($Rebuild) {
        $cliArgs += "--rebuild"
    }

    $payload = Invoke-TungstenCliJson -Arguments $cliArgs
    return $payload.hits
}

function Get-TungstenDocumentationPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Identifier,

        [string] $IndexPath,

        [switch] $Rebuild
    )

    $cliArgs = @("docs", "read", $Identifier)
    if ($IndexPath) {
        $cliArgs += @("--index-path", $IndexPath)
    }
    if ($Rebuild) {
        $cliArgs += "--rebuild"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs
}

function Open-TungstenDocumentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Identifier,

        [string] $IndexPath,

        [switch] $RequireSuccess
    )

    $cliArgs = @("frontend", "open-doc", $Identifier)
    if ($IndexPath) {
        $cliArgs += @("--index-path", $IndexPath)
    }
    if ($RequireSuccess) {
        $cliArgs += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs -AllowFailure:$RequireSuccess
}

function Open-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $RequireSuccess
    )

    $cliArgs = @("frontend", "open-notebook", "--file", $Path)
    if ($RequireSuccess) {
        $cliArgs += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs -AllowFailure:$RequireSuccess
}

function Invoke-TungstenFrontEnd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Code,

        [switch] $NoWrap,

        [switch] $RequireSuccess
    )

    $cliArgs = @("frontend", "run", "--code", $Code)
    if ($NoWrap) {
        $cliArgs += "--no-wrap"
    }
    if ($RequireSuccess) {
        $cliArgs += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $cliArgs -AllowFailure:$RequireSuccess
}

function Get-TungstenNotebookAssistantAskCliArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Question,

        [Parameter(Mandatory)]
        [string[]] $SelectorArgs,

        [switch] $InsertWolframCodeBelow,

        [switch] $InsertAllWolframCodeBelow,

        [switch] $Save,

        [switch] $CloseAssistantNotebook,

        [string] $ExtraInstructions,

        [string] $ModelService,

        [string] $ModelName,

        [switch] $RequireSuccess
    )

    $cliArgs = @("assistant", "ask-cell", "--file", $Path, "--question", $Question) + $SelectorArgs
    if ($InsertWolframCodeBelow) {
        $cliArgs += "--insert-wolfram-code-below"
    }
    if ($InsertAllWolframCodeBelow) {
        $cliArgs += "--insert-all-wolfram-code-below"
    }
    if ($Save) {
        $cliArgs += "--save"
    }
    if ($CloseAssistantNotebook) {
        $cliArgs += "--close-assistant-notebook"
    }
    if ($ExtraInstructions) {
        $cliArgs += @("--extra-instructions", $ExtraInstructions)
    }
    if ($ModelService) {
        $cliArgs += @("--model-service", $ModelService)
    }
    if ($ModelName) {
        $cliArgs += @("--model-name", $ModelName)
    }
    if ($RequireSuccess) {
        $cliArgs += "--require-success"
    }

    return $cliArgs
}

function Get-TungstenDesktopInlineAssistantWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Backend,

        [Parameter(Mandatory)]
        $Prepare,

        [ValidateRange(1000, 900000)]
        [int] $TimeoutMilliseconds
    )

    $windowTitle = [string] $Prepare.assistant.window_title
    if ([string]::IsNullOrWhiteSpace($windowTitle)) {
        return [pscustomobject]@{
            failure = New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowTitleUnavailable" `
                -Message "Tungsten opened the inline assistant, but the source notebook did not report a usable window title." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    prepare = $Prepare.assistant
                } `
                -Evaluation $Prepare.evaluation
        }
    }

    Import-TungstenWinDeskModule

    $window = Wait-TungstenWinDeskWindowByTitle -Title $windowTitle -TimeoutMilliseconds ([Math]::Min($TimeoutMilliseconds, 15000))
    if ($null -eq $window) {
        return [pscustomobject]@{
            failure = New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowNotVisible" `
                -Message "The notebook window '$windowTitle' was not visible to WinDesk." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    prepare = $Prepare.assistant
                } `
                -Evaluation $Prepare.evaluation
        }
    }

    if ($window.IsMinimized) {
        $restore = Set-WinDeskWindowState -Handle $window.Handle -State Restore
        if (-not $restore.Succeeded) {
            return [pscustomobject]@{
                failure = New-TungstenNotebookAssistantFailure `
                    -ErrorType "NotebookWindowRestoreFailed" `
                    -Message ($restore.Summary ?? "Unable to restore the notebook window before driving inline assistant input.") `
                    -Extra @{
                        backend = $Backend
                        notebook_path = $Path
                        window_title = $windowTitle
                        window_handle = $window.Handle
                        windesk = $restore
                    } `
                    -Evaluation $Prepare.evaluation
            }
        }

        Start-Sleep -Milliseconds 250
        $window = Get-WinDeskWindow -Handle $window.Handle | Select-Object -First 1
    }

    $activation = Set-WinDeskForegroundWindow -Handle $window.Handle
    if (-not $activation.Succeeded) {
        return [pscustomobject]@{
            failure = New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowActivationFailed" `
                -Message ($activation.Summary ?? "WinDesk could not activate the notebook window.") `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $window.Handle
                    windesk = $activation
                } `
                -Evaluation $Prepare.evaluation
        }
    }

    Start-Sleep -Milliseconds 250
    $window = Get-WinDeskWindow -Handle $window.Handle | Select-Object -First 1
    if ($null -eq $window -or -not $window.IsForeground) {
        $currentWindowHandle = if ($null -ne $window) { $window.Handle } else { $null }
        return [pscustomobject]@{
            failure = New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowNotForeground" `
                -Message "The notebook window could not be confirmed as the foreground window, so Tungsten refused to inject input into the desktop." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $currentWindowHandle
                } `
                -Evaluation $Prepare.evaluation
        }
    }

    return [pscustomobject]@{
        failure = $null
        window = $window
        window_title = $windowTitle
    }
}

function Wait-TungstenInlineAssistantCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Backend,

        [Parameter(Mandatory)]
        [string[]] $SelectorArgs,

        [Parameter(Mandatory)]
        [string] $WindowTitle,

        [Parameter(Mandatory)]
        [object] $WindowHandle,

        [Parameter(Mandatory)]
        $Prepare,

        [ValidateRange(1000, 900000)]
        [int] $TimeoutMilliseconds,

        [ValidateRange(100, 60000)]
        [int] $PollIntervalMilliseconds
    )

    $captureArgs = @("assistant", "capture-inline", "--file", $Path) + $SelectorArgs
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $lastCapture = $null

    do {
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
        $lastCapture = Invoke-TungstenCliJson -Arguments $captureArgs
        if ($null -eq $lastCapture) {
            return [pscustomobject]@{
                failure = New-TungstenNotebookAssistantFailure `
                    -ErrorType "InlineAssistantCaptureFailed" `
                    -Message "capture-inline did not return a payload while waiting for the inline assistant response." `
                    -Extra @{
                        backend = $Backend
                        notebook_path = $Path
                        window_title = $WindowTitle
                        window_handle = $WindowHandle
                    } `
                    -Evaluation $Prepare.evaluation
            }
        }

        if (-not $lastCapture.assistant_success) {
            return [pscustomobject]@{
                failure = $lastCapture
            }
        }
    }
    while (-not $lastCapture.assistant.completed -and [DateTimeOffset]::UtcNow -lt $deadline)

    if (-not $lastCapture.assistant.completed) {
        return [pscustomobject]@{
            failure = New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantTimedOut" `
                -Message "The inline Notebook Assistant did not finish before the configured timeout elapsed." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $WindowTitle
                    window_handle = $WindowHandle
                    prepare = $Prepare.assistant
                    last_capture = $lastCapture.assistant
                } `
                -Evaluation $lastCapture.evaluation
        }
    }

    return [pscustomobject]@{
        failure = $null
        capture_args = $captureArgs
        last_capture = $lastCapture
    }
}

function Complete-TungstenInlineAssistantCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Backend,

        [Parameter(Mandatory)]
        [string] $WindowTitle,

        [Parameter(Mandatory)]
        [object] $WindowHandle,

        [Parameter(Mandatory)]
        [string[]] $CaptureArgs,

        [Parameter(Mandatory)]
        $LastCapture,

        [switch] $InsertWolframCodeBelow,

        [switch] $InsertAllWolframCodeBelow,

        [switch] $Save
    )

    $final = $LastCapture
    if ($InsertWolframCodeBelow -or $InsertAllWolframCodeBelow -or $Save) {
        $finalArgs = @($CaptureArgs)
        if ($InsertWolframCodeBelow) {
            $finalArgs += "--insert-wolfram-code-below"
        }
        if ($InsertAllWolframCodeBelow) {
            $finalArgs += "--insert-all-wolfram-code-below"
        }
        if ($Save) {
            $finalArgs += "--save"
        }

        $final = Invoke-TungstenCliJson -Arguments $finalArgs
        if ($null -eq $final) {
            return [pscustomobject]@{
                failure = New-TungstenNotebookAssistantFailure `
                    -ErrorType "InlineAssistantFinalizeFailed" `
                    -Message "capture-inline did not return a payload during the final insert/save step." `
                    -Extra @{
                        backend = $Backend
                        notebook_path = $Path
                        window_title = $WindowTitle
                        window_handle = $WindowHandle
                    } `
                    -Evaluation $LastCapture.evaluation
            }
        }

        if (-not $final.assistant_success) {
            return [pscustomobject]@{
                failure = $final
            }
        }
    }

    return [pscustomobject]@{
        failure = $null
        final = $final
    }
}

function Invoke-TungstenDesktopInlineNotebookAssistant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Question,

        [Parameter(Mandatory)]
        [string[]] $SelectorArgs,

        [Parameter(Mandatory)]
        [string] $Backend,

        [ValidateSet("ClipboardPaste", "Keyboard")]
        [string] $InputMethod,

        [ValidateRange(1000, 900000)]
        [int] $TimeoutMilliseconds,

        [ValidateRange(100, 60000)]
        [int] $PollIntervalMilliseconds,

        [switch] $InsertWolframCodeBelow,

        [switch] $InsertAllWolframCodeBelow,

        [switch] $Save
    )

    $prepare = $null
    $lastCapture = $null

    try {
        $prepare = Invoke-TungstenCliJson -Arguments (@("assistant", "prepare-inline", "--file", $Path) + $SelectorArgs)
        if ($null -eq $prepare) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantPrepareFailed" `
                -Message "prepare-inline did not return a payload." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                }
        }

        if (-not $prepare.assistant_success) {
            return $prepare
        }

        $windowState = Get-TungstenDesktopInlineAssistantWindow `
            -Path $Path `
            -Backend $Backend `
            -Prepare $prepare `
            -TimeoutMilliseconds $TimeoutMilliseconds
        if ($null -ne $windowState.failure) {
            return $windowState.failure
        }

        $window = $windowState.window
        $windowTitle = [string] $windowState.window_title

        $textResult = Send-WinDeskText -Text $Question -Method $InputMethod -ExpectedForegroundWindowHandle $window.Handle
        if (-not $textResult.Succeeded) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantTextInjectionFailed" `
                -Message ($textResult.Summary ?? "WinDesk could not send the assistant question.") `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $window.Handle
                    windesk = $textResult
                } `
                -Evaluation $prepare.evaluation
        }

        $enterResult = Send-WinDeskKeys -Gesture Enter -ExpectedForegroundWindowHandle $window.Handle
        if (-not $enterResult.Succeeded) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantSubmitFailed" `
                -Message ($enterResult.Summary ?? "WinDesk could not submit the assistant question.") `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $window.Handle
                    windesk = $enterResult
                } `
                -Evaluation $prepare.evaluation
        }

        $waitResult = Wait-TungstenInlineAssistantCompletion `
            -Path $Path `
            -Backend $Backend `
            -SelectorArgs $SelectorArgs `
            -WindowTitle $windowTitle `
            -WindowHandle $window.Handle `
            -Prepare $prepare `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -PollIntervalMilliseconds $PollIntervalMilliseconds
        if ($null -ne $waitResult.failure) {
            return $waitResult.failure
        }

        $lastCapture = $waitResult.last_capture

        $finalResult = Complete-TungstenInlineAssistantCapture `
            -Path $Path `
            -Backend $Backend `
            -WindowTitle $windowTitle `
            -WindowHandle $window.Handle `
            -CaptureArgs $waitResult.capture_args `
            -LastCapture $lastCapture `
            -InsertWolframCodeBelow:$InsertWolframCodeBelow `
            -InsertAllWolframCodeBelow:$InsertAllWolframCodeBelow `
            -Save:$Save
        if ($null -ne $finalResult.failure) {
            return $finalResult.failure
        }

        $final = $finalResult.final
        $desktopAutomation = [pscustomobject]@{
            backend = $Backend
            input_method = $InputMethod
            timeout_milliseconds = $TimeoutMilliseconds
            poll_interval_milliseconds = $PollIntervalMilliseconds
            window_title = $windowTitle
            window_handle = $window.Handle
        }
        $final.assistant | Add-Member -NotePropertyName "desktop_automation" -NotePropertyValue $desktopAutomation -Force
        return $final
    }
    catch {
        $preparePayload = if ($null -ne $prepare) { $prepare.assistant } else { $null }
        $lastCapturePayload = if ($null -ne $lastCapture) { $lastCapture.assistant } else { $null }
        $evaluation = if ($null -ne $lastCapture) {
            $lastCapture.evaluation
        }
        elseif ($null -ne $prepare) {
            $prepare.evaluation
        }
        else {
            $null
        }

        return New-TungstenNotebookAssistantFailure `
            -ErrorType "DesktopInlineAutomationFailed" `
            -Message $_.Exception.Message `
            -Extra @{
                backend = $Backend
                notebook_path = $Path
                prepare = $preparePayload
                last_capture = $lastCapturePayload
            } `
            -Evaluation $evaluation
    }
}

function Invoke-TungstenNotebookAssistant {
    [CmdletBinding(DefaultParameterSetName = "CellIndex")]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Question,

        [Parameter(Mandatory, ParameterSetName = "CellIndex")]
        [int] $CellIndex,

        [Parameter(Mandatory, ParameterSetName = "CellPath")]
        [int[]] $CellPath,

        [Parameter(Mandatory, ParameterSetName = "ExpressionUuid")]
        [string] $ExpressionUuid,

        [Parameter(Mandatory, ParameterSetName = "CellId")]
        [int] $CellId,

        [Parameter(Mandatory, ParameterSetName = "CellTag")]
        [string] $CellTag,

        [switch] $InsertWolframCodeBelow,

        [switch] $InsertAllWolframCodeBelow,

        [switch] $Save,

        [switch] $CloseAssistantNotebook,

        [string] $ExtraInstructions,

        [string] $ModelService,

        [string] $ModelName,

        [ValidateSet("NotebookChatCell", "DesktopInline", "KernelWindow")]
        [string] $Backend = "NotebookChatCell",

        [ValidateSet("ClipboardPaste", "Keyboard")]
        [string] $InputMethod = "ClipboardPaste",

        [ValidateRange(1000, 900000)]
        [int] $TimeoutMilliseconds = 180000,

        [ValidateRange(100, 60000)]
        [int] $PollIntervalMilliseconds = 1500,

        [switch] $RequireSuccess
    )

    $selectorArgs = Get-TungstenNotebookAssistantSelectorArguments `
        -ParameterSetName $PSCmdlet.ParameterSetName `
        -CellIndex $CellIndex `
        -CellPath $CellPath `
        -ExpressionUuid $ExpressionUuid `
        -CellId $CellId `
        -CellTag $CellTag

    if ($Backend -in @("NotebookChatCell", "KernelWindow")) {
        $cliArgs = Get-TungstenNotebookAssistantAskCliArguments `
            -Path $Path `
            -Question $Question `
            -SelectorArgs $selectorArgs `
            -InsertWolframCodeBelow:$InsertWolframCodeBelow `
            -InsertAllWolframCodeBelow:$InsertAllWolframCodeBelow `
            -Save:$Save `
            -CloseAssistantNotebook:$CloseAssistantNotebook `
            -ExtraInstructions $ExtraInstructions `
            -ModelService $ModelService `
            -ModelName $ModelName `
            -RequireSuccess:$RequireSuccess

        return Invoke-TungstenCliJson -Arguments $cliArgs -AllowFailure:$RequireSuccess
    }

    if ($CloseAssistantNotebook) {
        return New-TungstenNotebookAssistantFailure `
            -ErrorType "UnsupportedDesktopInlineOption" `
            -Message "DesktopInline backend does not use a separate assistant notebook, so -CloseAssistantNotebook is not applicable." `
            -Extra @{
                backend = $Backend
                notebook_path = $Path
            }
    }

    if ($ExtraInstructions -or $ModelService -or $ModelName) {
        return New-TungstenNotebookAssistantFailure `
            -ErrorType "UnsupportedDesktopInlineOption" `
            -Message "DesktopInline backend currently drives the built-in inline Notebook Assistant UI and does not yet support -ExtraInstructions, -ModelService, or -ModelName overrides." `
            -Extra @{
                backend = $Backend
                notebook_path = $Path
            }
    }

    return Invoke-TungstenDesktopInlineNotebookAssistant `
        -Path $Path `
        -Question $Question `
        -SelectorArgs $selectorArgs `
        -Backend $Backend `
        -InputMethod $InputMethod `
        -TimeoutMilliseconds $TimeoutMilliseconds `
        -PollIntervalMilliseconds $PollIntervalMilliseconds `
        -InsertWolframCodeBelow:$InsertWolframCodeBelow `
        -InsertAllWolframCodeBelow:$InsertAllWolframCodeBelow `
        -Save:$Save
}

Export-ModuleMember -Function @(
    "Compare-TungstenParserCorpus",
    "Convert-TungstenExpression",
    "Find-TungstenDocumentation",
    "Get-TungstenDocumentationPage",
    "Get-TungstenEnvironment",
    "Get-TungstenNotebook",
    "Get-TungstenNotebookCellInlineBoxes",
    "Get-TungstenParserCorpus",
    "Invoke-TungstenFrontEnd",
    "Invoke-TungstenKernel",
    "Invoke-TungstenNotebookAssistant",
    "Invoke-TungstenExpression",
    "New-TungstenInlineBoxString",
    "New-TungstenNotebook",
    "Open-TungstenDocumentation",
    "Open-TungstenNotebook",
    "Set-TungstenNotebook"
)
