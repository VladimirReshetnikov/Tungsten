using System.Text.Json;
using Xunit;

namespace Tungsten.DotNet.Tests;

public sealed class TungstenClientTests
{
    [Fact]
    public async Task GetEnvironmentAsync_UsesProbeAndPrependsPythonPathAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var workingDirectory = Path.Combine(tempRoot, "cwd");
            Directory.CreateDirectory(workingDirectory);

            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                    WorkingDirectory = workingDirectory,
                    TungstenSourceRoot = @"C:\fake\tungsten\src",
                });

            var response = await client.GetEnvironmentAsync(probe: true);

            Assert.Equal("Wolfram", response.Product);
            Assert.Equal("wolfram", response.ProductFamily);
            Assert.Equal("15.0", response.Version);
            Assert.Equal(@"C:\Program Files\Wolfram Research\Wolfram\15.0", response.InstallDir);
            Assert.Equal("default-product-preference", response.SelectionReason);
            Assert.Equal("engine", response.AvailableInstallations[1].ProductFamily);
            Assert.True(response.ExtensionData.ContainsKey("forwarded_args"));
            Assert.Equal(
                ["env", "show", "--probe"],
                response.ExtensionData["forwarded_args"].Deserialize<string[]>()!);
            var ambientPythonPath = Environment.GetEnvironmentVariable("PYTHONPATH");
            var expectedPythonPath = string.IsNullOrWhiteSpace(ambientPythonPath)
                ? @"C:\fake\tungsten\src"
                : string.Join(Path.PathSeparator, @"C:\fake\tungsten\src", ambientPythonPath);
            Assert.Equal(expectedPythonPath, response.ExtensionData["pythonpath"].GetString());
            Assert.Equal(workingDirectory, response.ExtensionData["cwd"].GetString());
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task CreateNotebookAsync_BuildsCellArgumentsAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var notebookPath = Path.Combine(tempRoot, "sample.nb");

            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                });

            var response = await client.CreateNotebookAsync(
                notebookPath,
                title: "CLI Notebook",
                cells:
                [
                    new TungstenNotebookCellSpec("Text", "Hello"),
                    new TungstenNotebookCellSpec("Input", "2+2"),
                ]);

            Assert.Equal("CLI Notebook", response.Title);
            Assert.Equal(2, response.CellCount);
            var forwarded = response.ExtensionData["forwarded_args"].Deserialize<string[]>()!;
            Assert.Contains("--title", forwarded);
            Assert.Contains("Text:Hello", forwarded);
            Assert.Contains("Input:2+2", forwarded);
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task EvaluateExpressionAsync_ParsesTypedPayloadAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                });

            var response = await client.EvaluateExpressionAsync(
                TungstenInputSource.FromCode("ReplacePart[f[a, b, c], 2 -> x]"));

            Assert.Equal("evaluate", response.Command);
            Assert.Equal("f[a, x, c]", response.Result?.FullForm);
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task OpenDocumentationInFrontEndAsync_PassesIdentifierAndIndexPathAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                });

            var response = await client.OpenDocumentationInFrontEndAsync(
                "NotebookGet",
                indexPath: @"C:\docs\index.sqlite3",
                requireSuccess: true);

            Assert.True(response.Success);
            Assert.Equal("NotebookObject", response.ResultHead);
            var forwarded = response.ExtensionData["forwarded_args"].Deserialize<string[]>()!;
            Assert.Equal(["frontend", "open-doc", "NotebookGet", "--index-path", @"C:\docs\index.sqlite3", "--require-success"], forwarded);
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task AskNotebookAssistantAsync_ParsesTypedPayloadAndForwardsOptionsAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                });

            var response = await client.AskNotebookAssistantAsync(
                new TungstenNotebookAssistantAskOptions
                {
                    NotebookPath = Path.Combine(tempRoot, "assistant.nb"),
                    CellSelector = TungstenNotebookCellSelector.ByExpressionUuid("uuid-source"),
                    Question = "Reply only with Wolfram Language code.",
                    InsertWolframCodeBelow = true,
                    Save = true,
                    CloseAssistantNotebook = true,
                    ModelService = "OpenAI",
                    ModelName = "gpt-5.4",
                    RequireSuccess = true,
                });

            Assert.True(response.AssistantSuccess);
            Assert.Equal("2 + 2", response.Assistant?.WolframCodeBlocks[0].GetProperty("code").GetString());
            Assert.Equal("String", response.Evaluation?.ResultHead);
            var forwarded = response.ExtensionData["forwarded_args"].Deserialize<string[]>()!;
            Assert.Contains("--expression-uuid", forwarded);
            Assert.Contains("uuid-source", forwarded);
            Assert.Contains("--insert-wolfram-code-below", forwarded);
            Assert.Contains("--close-assistant-notebook", forwarded);
            Assert.Contains("--model-service", forwarded);
            Assert.Contains("--require-success", forwarded);
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task ExtractInlineBoxesFromNotebookCellAsync_UsesCellSelectorAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var notebookPath = Path.Combine(tempRoot, "inline-box.nb");

            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                });

            var response = await client.ExtractInlineBoxesFromNotebookCellAsync(
                notebookPath,
                TungstenNotebookCellSelector.ByExpressionUuid("uuid-inline-box"),
                prefix: "icon: ",
                requireSuccess: true);

            Assert.True(response.Success);
            Assert.Equal("GraphicsBox", response.SelectedBoxes[0].Head);
            var forwarded = response.ExtensionData["forwarded_args"].Deserialize<string[]>()!;
            Assert.Contains("--expression-uuid", forwarded);
            Assert.Contains("uuid-inline-box", forwarded);
            Assert.Contains("--require-success", forwarded);
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task InvokeJsonAsync_ThrowsCommandExceptionOnNonZeroExitAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                });

            var exception = await Assert.ThrowsAsync<TungstenCommandException>(
                () => client.InvokeJsonAsync<JsonElement>(["fail"], CancellationToken.None));

            Assert.Equal(17, exception.ExitCode);
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task InvokeJsonAsync_ThrowsProtocolExceptionOnInvalidJsonAsync()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var scriptPath = await WriteFakeScriptAsync(tempRoot);
            var client = new TungstenClient(
                new TungstenClientOptions
                {
                    ExecutablePath = "pwsh",
                    LauncherArguments = ["-NoLogo", "-NoProfile", "-File", scriptPath],
                });

            await Assert.ThrowsAsync<TungstenProtocolException>(
                () => client.InvokeJsonAsync<JsonElement>(["broken"], CancellationToken.None));
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public void DefaultOptions_UseCppExecutableFromPath()
    {
        var options = new TungstenClientOptions();

        Assert.Equal("tungsten-cpp", options.ExecutablePath);
        Assert.Empty(options.LauncherArguments);
    }

    [Fact]
    public void NotebookCellSelector_RejectsEmptyPath()
    {
        Assert.Throws<ArgumentException>(() => TungstenNotebookCellSelector.ByPath());
    }

    [Fact]
    public void RepositoryOptions_DiscoverCppLayoutAndBuildArtifacts()
    {
        var tempRoot = CreateTempDirectory();
        var previousExecutable = Environment.GetEnvironmentVariable("TUNGSTEN_EXECUTABLE");
        try
        {
            Environment.SetEnvironmentVariable("TUNGSTEN_EXECUTABLE", null);
            var tungstenRoot = CreateCppRepositoryLayout(tempRoot);
            var executableName = OperatingSystem.IsWindows() ? "tungsten-cpp.exe" : "tungsten-cpp";
            var releaseExecutable = Path.Combine(
                tungstenRoot,
                "build",
                "cpp",
                "Release",
                executableName);
            Directory.CreateDirectory(Path.GetDirectoryName(releaseExecutable)!);
            File.WriteAllText(releaseExecutable, string.Empty);

            var releaseOptions = TungstenClientOptions.CreateForRepositoryRoot(tempRoot);

            Assert.Equal(releaseExecutable, releaseOptions.ExecutablePath);
            Assert.Equal(tungstenRoot, releaseOptions.WorkingDirectory);

            var directExecutable = Path.Combine(tungstenRoot, "build", "cpp", executableName);
            File.WriteAllText(directExecutable, string.Empty);
            var directOptions = TungstenClientOptions.CreateForRepositoryRoot(tempRoot);
            Assert.Equal(directExecutable, directOptions.ExecutablePath);

            var nestedDirectory = Path.Combine(tungstenRoot, "dotnet", "tests", "nested");
            Directory.CreateDirectory(nestedDirectory);
            Assert.Equal(
                tempRoot,
                TungstenClientOptions.TryFindRepositoryRoot(nestedDirectory));
        }
        finally
        {
            Environment.SetEnvironmentVariable("TUNGSTEN_EXECUTABLE", previousExecutable);
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public void RepositoryOptions_RetainEnvironmentOverrideAndCustomLauncher()
    {
        var tempRoot = CreateTempDirectory();
        var previousExecutable = Environment.GetEnvironmentVariable("TUNGSTEN_EXECUTABLE");
        try
        {
            CreateCppRepositoryLayout(tempRoot);
            Environment.SetEnvironmentVariable("TUNGSTEN_EXECUTABLE", "custom-tungsten-launcher");

            var configured = TungstenClientOptions.CreateForRepositoryRoot(tempRoot);
            var explicitLauncher = TungstenClientOptions.CreateForRepositoryRoot(
                tempRoot,
                executablePath: "pwsh");

            Assert.Equal("custom-tungsten-launcher", configured.ExecutablePath);
            Assert.Equal("pwsh", explicitLauncher.ExecutablePath);
        }
        finally
        {
            Environment.SetEnvironmentVariable("TUNGSTEN_EXECUTABLE", previousExecutable);
            DeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task RealRepositoryExpressionEvaluation_WorksAsync()
    {
        var repositoryRoot = TungstenClientOptions.TryFindRepositoryRoot(AppContext.BaseDirectory);
        Assert.False(string.IsNullOrWhiteSpace(repositoryRoot));

        var client = TungstenClient.CreateForRepositoryRoot(repositoryRoot!);
        var response = await client.EvaluateExpressionAsync(
            TungstenInputSource.FromCode("ReplacePart[f[a, b, c], 2 -> x]"));

        Assert.Equal("f[a, x, c]", response.Result?.FullForm);
    }

    [Fact]
    public async Task RealRepositoryNotebookPatch_WritesNativeCompatibleUtf8Async()
    {
        var repositoryRoot = TungstenClientOptions.TryFindRepositoryRoot(AppContext.BaseDirectory);
        Assert.False(string.IsNullOrWhiteSpace(repositoryRoot));

        var tempRoot = CreateTempDirectory();
        try
        {
            var client = TungstenClient.CreateForRepositoryRoot(repositoryRoot!);
            var notebookPath = Path.Combine(tempRoot, "unicode notebook.nb");
            await client.CreateNotebookAsync(
                notebookPath,
                title: "Projection notebook",
                cells: [new TungstenNotebookCellSpec("Text", "first")]);

            var patched = await client.PatchNotebookAsync(
                notebookPath,
                new
                {
                    operations = new[]
                    {
                        new { op = "append_cell", style = "Text", text = "café λ" },
                    },
                });

            Assert.Equal(2, patched.CellCount);
            Assert.Equal("café λ", patched.Cells[1].Preview);
        }
        finally
        {
            DeleteDirectory(tempRoot);
        }
    }

    private static string CreateTempDirectory()
    {
        var root = Path.Combine(Path.GetTempPath(), $"tungsten-dotnet-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        return root;
    }

    private static string CreateCppRepositoryLayout(string repositoryRoot)
    {
        var tungstenRoot = Path.Combine(repositoryRoot, "Engine");
        var cppSourceRoot = Path.Combine(tungstenRoot, "cpp", "src");
        Directory.CreateDirectory(cppSourceRoot);
        File.WriteAllText(Path.Combine(tungstenRoot, "CMakeLists.txt"), string.Empty);
        File.WriteAllText(Path.Combine(cppSourceRoot, "main.cpp"), string.Empty);
        return tungstenRoot;
    }

    private static void DeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
            // Best-effort cleanup only.
        }
    }

    private static async Task<string> WriteFakeScriptAsync(string directory)
    {
        var scriptPath = Path.Combine(directory, "fake-tungsten.ps1");
        var script = """
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $ForwardedArgs)

function Write-Json([object] $Payload) {
    $Payload | ConvertTo-Json -Depth 20
}

switch ($ForwardedArgs[0]) {
    "fail" {
        Write-Error "simulated failure"
        exit 17
    }
    "broken" {
        Write-Output "not-json"
        exit 0
    }
    "env" {
        Write-Json @{
            product = "Wolfram"
            product_family = "wolfram"
            version = "15.0"
            install_dir = "C:\Program Files\Wolfram Research\Wolfram\15.0"
            kernel_cli = "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe"
            docs_roots = @("C:\Docs")
            default_index_path = "C:\Docs\index.sqlite3"
            user_base = "C:\Users\vresh\AppData\Roaming\Wolfram"
            system_base = "C:\ProgramData\Wolfram"
            mathpass_candidates = @("C:\ProgramData\Wolfram\Licensing\mathpass")
            available_installations = @(
                @{
                    product = "Wolfram"
                    product_family = "wolfram"
                    version = "15.0"
                    install_dir = "C:\Program Files\Wolfram Research\Wolfram\15.0"
                    kernel_cli = "C:\Program Files\Wolfram Research\Wolfram\15.0\wolfram.exe"
                    wolframscript = "C:\Program Files\Wolfram Research\Wolfram\15.0\wolframscript.exe"
                },
                @{
                    product = "Wolfram Engine"
                    product_family = "engine"
                    version = "14.3"
                    install_dir = "C:\Program Files\Wolfram Research\Wolfram Engine\14.3"
                    kernel_cli = "C:\Program Files\Wolfram Research\Wolfram Engine\14.3\wolfram.exe"
                    wolframscript = "C:\Program Files\Wolfram Research\Wolfram Engine\14.3\wolframscript.exe"
                }
            )
            selection_reason = "default-product-preference"
            probe = if ($ForwardedArgs -contains "--probe") { @{ evaluation = @{ success = $true } } } else { $null }
            forwarded_args = $ForwardedArgs
            pythonpath = $env:PYTHONPATH
            cwd = (Get-Location).Path
        }
        exit 0
    }
    "notebook" {
        Write-Json @{
            path = $ForwardedArgs[[Array]::IndexOf($ForwardedArgs, "--file") + 1]
            title = "CLI Notebook"
            cell_count = 2
            group_count = 0
            options = @()
            cells = @(
                @{
                    index = 0
                    kind = "cell"
                    path = @(0)
                    depth = 0
                    style = "Text"
                    preview = "Hello"
                    cell_tags = @()
                    options = @()
                },
                @{
                    index = 1
                    kind = "cell"
                    path = @(1)
                    depth = 0
                    style = "Input"
                    preview = "2+2"
                    cell_tags = @()
                    options = @()
                }
            )
            forwarded_args = $ForwardedArgs
        }
        exit 0
    }
    "expr" {
        if ($ForwardedArgs[1] -eq "evaluate") {
            Write-Json @{
                command = "evaluate"
                form = "input"
                source = "ReplacePart[f[a, b, c], 2 -> x]"
                parsed_input_form = "ReplacePart[f[a, b, c], 2 -> x]"
                parsed_full_form = "ReplacePart[f[a, b, c], Rule[2, x]]"
                result = @{
                    input_form = "f[a, x, c]"
                    full_form = "f[a, x, c]"
                    depth = 2
                    length = 3
                    tree = @{ type = "call" }
                }
            }
            exit 0
        }

        Write-Json @{
            command = "parse"
            form = "input"
            source = "1 + 2 x^3"
            input_form = "1 + (2 * (x^3))"
            full_form = "Plus[1, Times[2, Power[x, 3]]]"
            depth = 4
            length = 2
            tree = @{ type = "call" }
        }
        exit 0
    }
    "inline-box" {
        Write-Json @{
            success = $true
            selected_boxes = @(
                @{
                    index = 0
                    head = "GraphicsBox"
                    box_expression = "GraphicsBox[{CircleBox[]}]"
                    inline_box_escape = '\!\(\*GraphicsBox[{CircleBox[]}]\)'
                }
            )
            selected_box_count = 1
            forwarded_args = $ForwardedArgs
        }
        exit 0
    }
    "frontend" {
        Write-Json @{
            command = @("wolfram.exe", "-script", "frontend.wl")
            exit_code = 0
            success = $true
            result = 'NotebookObject[FrontEndObject[LinkObject["test", 1, 1]], 1]'
            result_head = "NotebookObject"
            messages = @()
            messages_text = @()
            output = @()
            evaluation_available = $true
            forwarded_args = $ForwardedArgs
        }
        exit 0
    }
    "assistant" {
        Write-Json @{
            assistant_success = $true
            assistant = @{
                success = $true
                response_text = @'
```wolfram
2 + 2
```
'@
                insert_mode = "first"
                wolfram_code_blocks = @(
                    @{
                        language = "wolfram"
                        code = "2 + 2"
                        insertable = $true
                    }
                )
                inserted = @(
                    @{
                        style = "Input"
                        text = "2 + 2"
                    }
                )
                saved_notebook = $true
            }
            evaluation = @{
                command = @("wolfram.exe", "-script", "assistant.wl")
                exit_code = 0
                success = $true
                result = '"assistant payload"'
                result_head = "String"
                messages = @()
                messages_text = @()
                output = @()
                evaluation_available = $true
            }
            forwarded_args = $ForwardedArgs
        }
        exit 0
    }
    default {
        Write-Json @{
            forwarded_args = $ForwardedArgs
            pythonpath = $env:PYTHONPATH
            cwd = (Get-Location).Path
        }
        exit 0
    }
}
""";
        await File.WriteAllTextAsync(scriptPath, script);
        return scriptPath;
    }
}
