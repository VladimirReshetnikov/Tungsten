using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Tungsten.DotNet;

/// <summary>
/// Typed .NET client for Tungsten's JSON-first CLI.
/// </summary>
public sealed class TungstenClient
{
    /// <summary>
    /// Initializes a new instance of the <see cref="TungstenClient"/> class.
    /// </summary>
    public TungstenClient(TungstenClientOptions? options = null)
    {
        Options = options ?? new TungstenClientOptions();
    }

    /// <summary>
    /// Gets the client options.
    /// </summary>
    public TungstenClientOptions Options { get; }

    /// <summary>
    /// Creates a Tungsten client configured for this repository's checked-out Tungsten layout.
    /// </summary>
    public static TungstenClient CreateForRepositoryRoot(string repositoryRoot, string executablePath = "python") =>
        new(TungstenClientOptions.CreateForRepositoryRoot(repositoryRoot, executablePath));

    /// <summary>
    /// Discovers a repository root containing Tungsten and creates a client configured for it.
    /// </summary>
    public static TungstenClient CreateForDiscoveredRepository(string? startDirectory = null, string executablePath = "python") =>
        new(TungstenClientOptions.CreateForDiscoveredRepository(startDirectory, executablePath));

    /// <summary>
    /// Shows the discovered Tungsten/Wolfram environment.
    /// </summary>
    public Task<TungstenEnvironmentResponse> GetEnvironmentAsync(bool probe = false, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "env", "show" };
        if (probe)
        {
            arguments.Add("--probe");
        }

        return InvokeJsonAsync<TungstenEnvironmentResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Runs Wolfram Language code through Tungsten's kernel command.
    /// </summary>
    public Task<TungstenKernelEvaluationResponse> EvaluateKernelAsync(
        TungstenInputSource source,
        string? workingDirectory = null,
        bool requireFrontEnd = false,
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);

        var arguments = new List<string> { "kernel", "eval" };
        source.AppendArguments(arguments);
        if (!string.IsNullOrWhiteSpace(workingDirectory))
        {
            arguments.Add("--working-directory");
            arguments.Add(workingDirectory);
        }

        if (requireFrontEnd)
        {
            arguments.Add("--front-end");
        }

        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenKernelEvaluationResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Inspects a Wolfram notebook file.
    /// </summary>
    public Task<TungstenNotebookDocumentResponse> InspectNotebookAsync(string notebookPath, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(notebookPath);
        return InvokeJsonAsync<TungstenNotebookDocumentResponse>(["notebook", "inspect", "--file", notebookPath], cancellationToken);
    }

    /// <summary>
    /// Creates a notebook file with the requested title and cells.
    /// </summary>
    public Task<TungstenNotebookDocumentResponse> CreateNotebookAsync(
        string notebookPath,
        string? title = null,
        IEnumerable<TungstenNotebookCellSpec>? cells = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(notebookPath);

        var arguments = new List<string> { "notebook", "create", "--file", notebookPath };
        if (!string.IsNullOrWhiteSpace(title))
        {
            arguments.Add("--title");
            arguments.Add(title);
        }

        if (cells is not null)
        {
            foreach (var cell in cells)
            {
                ArgumentNullException.ThrowIfNull(cell);
                arguments.Add("--cell");
                arguments.Add($"{cell.Style}:{cell.Text}");
            }
        }

        return InvokeJsonAsync<TungstenNotebookDocumentResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Applies a Tungsten notebook patch spec from a file.
    /// </summary>
    public Task<TungstenNotebookDocumentResponse> PatchNotebookFromFileAsync(
        string notebookPath,
        string patchSpecPath,
        string? outputPath = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(notebookPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(patchSpecPath);

        var arguments = new List<string> { "notebook", "patch", "--file", notebookPath, "--spec", patchSpecPath };
        if (!string.IsNullOrWhiteSpace(outputPath))
        {
            arguments.Add("--out");
            arguments.Add(outputPath);
        }

        return InvokeJsonAsync<TungstenNotebookDocumentResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Applies a Tungsten notebook patch spec supplied as a .NET object or JSON element.
    /// </summary>
    public async Task<TungstenNotebookDocumentResponse> PatchNotebookAsync(
        string notebookPath,
        object patchSpec,
        string? outputPath = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(notebookPath);
        ArgumentNullException.ThrowIfNull(patchSpec);

        var tempFile = Path.Combine(Path.GetTempPath(), $"tungsten-patch-{Guid.NewGuid():N}.json");
        try
        {
            var json = JsonSerializer.Serialize(patchSpec, Options.JsonSerializerOptions);
            await File.WriteAllTextAsync(tempFile, json, Encoding.UTF8, cancellationToken).ConfigureAwait(false);
            return await PatchNotebookFromFileAsync(notebookPath, tempFile, outputPath, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            TryDeleteFile(tempFile);
        }
    }

    /// <summary>
    /// Parses a Wolfram expression without a kernel.
    /// </summary>
    public Task<TungstenExpressionParseResponse> ParseExpressionAsync(
        TungstenInputSource source,
        TungstenExpressionForm form = TungstenExpressionForm.Input,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);

        var arguments = new List<string> { "expr", "parse" };
        source.AppendArguments(arguments);
        arguments.Add("--form");
        arguments.Add(ToCliForm(form));
        return InvokeJsonAsync<TungstenExpressionParseResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Structurally evaluates a Wolfram expression without a kernel.
    /// </summary>
    public Task<TungstenExpressionEvaluationResponse> EvaluateExpressionAsync(
        TungstenInputSource source,
        TungstenExpressionForm form = TungstenExpressionForm.Input,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);

        var arguments = new List<string> { "expr", "evaluate" };
        source.AppendArguments(arguments);
        arguments.Add("--form");
        arguments.Add(ToCliForm(form));
        return InvokeJsonAsync<TungstenExpressionEvaluationResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Builds or rebuilds Tungsten's documentation index.
    /// </summary>
    public Task<TungstenDocumentationIndexResponse> BuildDocumentationIndexAsync(
        string? indexPath = null,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "docs", "index" };
        if (!string.IsNullOrWhiteSpace(indexPath))
        {
            arguments.Add("--path");
            arguments.Add(indexPath);
        }

        return InvokeJsonAsync<TungstenDocumentationIndexResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Searches Tungsten's documentation index.
    /// </summary>
    public Task<TungstenDocumentationSearchResponse> SearchDocumentationAsync(
        string query,
        int limit = 10,
        string? indexPath = null,
        bool rebuild = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(query);

        var arguments = new List<string>
        {
            "docs",
            "search",
            query,
            "--limit",
            limit.ToString(CultureInfo.InvariantCulture),
        };

        if (!string.IsNullOrWhiteSpace(indexPath))
        {
            arguments.Add("--index-path");
            arguments.Add(indexPath);
        }

        if (rebuild)
        {
            arguments.Add("--rebuild");
        }

        return InvokeJsonAsync<TungstenDocumentationSearchResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Reads a documentation record from Tungsten's documentation index.
    /// </summary>
    public Task<TungstenDocumentationRecord> ReadDocumentationAsync(
        string identifier,
        string? indexPath = null,
        bool rebuild = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(identifier);

        var arguments = new List<string> { "docs", "read", identifier };
        if (!string.IsNullOrWhiteSpace(indexPath))
        {
            arguments.Add("--index-path");
            arguments.Add(indexPath);
        }

        if (rebuild)
        {
            arguments.Add("--rebuild");
        }

        return InvokeJsonAsync<TungstenDocumentationRecord>(arguments, cancellationToken);
    }

    /// <summary>
    /// Runs a hidden FrontEnd availability probe.
    /// </summary>
    public Task<TungstenKernelEvaluationResponse> ProbeFrontEndAsync(
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "frontend", "probe" };
        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenKernelEvaluationResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Opens a notebook file in the Wolfram FrontEnd.
    /// </summary>
    public Task<TungstenKernelEvaluationResponse> OpenNotebookInFrontEndAsync(
        string notebookPath,
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(notebookPath);

        var arguments = new List<string> { "frontend", "open-notebook", "--file", notebookPath };
        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenKernelEvaluationResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Opens a documentation page in the Wolfram FrontEnd.
    /// </summary>
    public Task<TungstenKernelEvaluationResponse> OpenDocumentationInFrontEndAsync(
        string identifier,
        string? indexPath = null,
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(identifier);

        var arguments = new List<string> { "frontend", "open-doc", identifier };
        if (!string.IsNullOrWhiteSpace(indexPath))
        {
            arguments.Add("--index-path");
            arguments.Add(indexPath);
        }

        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenKernelEvaluationResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Runs Wolfram code targeted at the FrontEnd.
    /// </summary>
    public Task<TungstenKernelEvaluationResponse> RunFrontEndCodeAsync(
        string code,
        bool wrapUsingFrontEnd = true,
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(code);

        var arguments = new List<string> { "frontend", "run", "--code", code };
        if (!wrapUsingFrontEnd)
        {
            arguments.Add("--no-wrap");
        }

        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenKernelEvaluationResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Executes a FrontEnd token, optionally against a specific notebook.
    /// </summary>
    public Task<TungstenKernelEvaluationResponse> ExecuteFrontEndTokenAsync(
        string token,
        string? notebookPath = null,
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(token);

        var arguments = new List<string> { "frontend", "token", token };
        if (!string.IsNullOrWhiteSpace(notebookPath))
        {
            arguments.Add("--file");
            arguments.Add(notebookPath);
        }

        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenKernelEvaluationResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Asks Notebook Assistant about a selected cell and optionally inserts Wolfram Language code below it.
    /// </summary>
    public Task<TungstenNotebookAssistantResponse> AskNotebookAssistantAsync(
        TungstenNotebookAssistantAskOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);

        var arguments = new List<string>();
        options.AppendArguments(arguments);
        return InvokeJsonAsync<TungstenNotebookAssistantResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Opens inline Notebook Assistant for a selected cell and focuses its input field.
    /// </summary>
    public Task<TungstenNotebookAssistantResponse> PrepareInlineNotebookAssistantAsync(
        string notebookPath,
        TungstenNotebookCellSelector selector,
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(notebookPath);
        ArgumentNullException.ThrowIfNull(selector);

        var arguments = new List<string> { "assistant", "prepare-inline", "--file", notebookPath };
        selector.AppendArguments(arguments);
        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenNotebookAssistantResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Captures the current inline Notebook Assistant state and optionally inserts Wolfram Language code below the source cell.
    /// </summary>
    public Task<TungstenNotebookAssistantResponse> CaptureInlineNotebookAssistantAsync(
        TungstenNotebookAssistantCaptureOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);

        var arguments = new List<string>();
        options.AppendArguments(arguments);
        return InvokeJsonAsync<TungstenNotebookAssistantResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Builds a Wolfram string literal containing inline box escapes.
    /// </summary>
    public Task<TungstenInlineBoxComposeResponse> ComposeInlineBoxAsync(
        IEnumerable<string> boxExpressions,
        string prefix = "",
        string suffix = "",
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(boxExpressions);

        var arguments = new List<string> { "inline-box", "compose", "--prefix", prefix, "--suffix", suffix };
        foreach (var boxExpression in boxExpressions)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(boxExpression);
            arguments.Add("--box-expr");
            arguments.Add(boxExpression);
        }

        return InvokeJsonAsync<TungstenInlineBoxComposeResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Extracts inline-box objects from a notebook cell and composes a ready-to-use Wolfram string literal.
    /// </summary>
    public Task<TungstenInlineBoxExtractionResponse> ExtractInlineBoxesFromNotebookCellAsync(
        string notebookPath,
        TungstenNotebookCellSelector selector,
        string prefix = "",
        string suffix = "",
        int objectIndex = 0,
        bool allObjects = false,
        bool requireSuccess = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(notebookPath);
        ArgumentNullException.ThrowIfNull(selector);

        var arguments = new List<string> { "inline-box", "from-cell", "--file", notebookPath };
        selector.AppendArguments(arguments);
        arguments.Add("--prefix");
        arguments.Add(prefix);
        arguments.Add("--suffix");
        arguments.Add(suffix);
        arguments.Add("--object-index");
        arguments.Add(objectIndex.ToString(CultureInfo.InvariantCulture));
        if (allObjects)
        {
            arguments.Add("--all-objects");
        }

        if (requireSuccess)
        {
            arguments.Add("--require-success");
        }

        return InvokeJsonAsync<TungstenInlineBoxExtractionResponse>(arguments, cancellationToken);
    }

    /// <summary>
    /// Invokes an arbitrary Tungsten JSON command and deserializes the response to the requested type.
    /// </summary>
    public async Task<TResponse> InvokeJsonAsync<TResponse>(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var execution = await ExecuteAsync(arguments, cancellationToken).ConfigureAwait(false);
        EnsureSuccess(arguments, execution);

        try
        {
            var response = JsonSerializer.Deserialize<TResponse>(execution.StandardOutput, Options.JsonSerializerOptions);
            if (response is null)
            {
                throw new JsonException("Tungsten returned an empty JSON payload.");
            }

            return response;
        }
        catch (JsonException ex)
        {
            throw new TungstenProtocolException(
                $"Tungsten command produced invalid JSON for arguments: {string.Join(" ", arguments)}",
                execution.StandardOutput,
                execution.StandardError,
                ex);
        }
    }

    private static string ToCliForm(TungstenExpressionForm form) => form switch
    {
        TungstenExpressionForm.Input => "input",
        TungstenExpressionForm.FullForm => "fullform",
        TungstenExpressionForm.Standard => "standard",
        _ => throw new ArgumentOutOfRangeException(nameof(form)),
    };

    private async Task<TungstenProcessResult> ExecuteAsync(
        IReadOnlyList<string> tungstenArguments,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Options.ExecutablePath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

        if (!string.IsNullOrWhiteSpace(Options.WorkingDirectory))
        {
            startInfo.WorkingDirectory = Options.WorkingDirectory;
        }

        foreach (var launcherArgument in Options.LauncherArguments)
        {
            startInfo.ArgumentList.Add(launcherArgument);
        }

        foreach (var tungstenArgument in tungstenArguments)
        {
            startInfo.ArgumentList.Add(tungstenArgument);
        }

        ApplyEnvironment(startInfo);

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException($"Failed to start Tungsten process '{Options.ExecutablePath}'.");
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();

        using var timeoutCts = Options.DefaultTimeout is { } timeout
            ? new CancellationTokenSource(timeout)
            : null;
        using var linkedCts = timeoutCts is null
            ? CancellationTokenSource.CreateLinkedTokenSource(cancellationToken)
            : CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

        try
        {
            await process.WaitForExitAsync(linkedCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            TryKillProcess(process);
            throw new TimeoutException(
                $"Tungsten command exceeded the configured timeout of {Options.DefaultTimeout}.");
        }
        catch
        {
            TryKillProcess(process);
            throw;
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        return new TungstenProcessResult(process.ExitCode, stdout, stderr);
    }

    private void ApplyEnvironment(ProcessStartInfo startInfo)
    {
        foreach (var pair in Options.EnvironmentVariables)
        {
            startInfo.Environment[pair.Key] = pair.Value;
        }

        if (!string.IsNullOrWhiteSpace(Options.TungstenSourceRoot))
        {
            var ambient = startInfo.Environment.TryGetValue("PYTHONPATH", out var currentPythonPath)
                ? currentPythonPath
                : null;
            var merged = string.IsNullOrWhiteSpace(ambient)
                ? Options.TungstenSourceRoot
                : string.Join(Path.PathSeparator, Options.TungstenSourceRoot, ambient);
            startInfo.Environment["PYTHONPATH"] = merged;
        }
    }

    private void EnsureSuccess(IReadOnlyList<string> arguments, TungstenProcessResult execution)
    {
        if (execution.ExitCode == 0)
        {
            return;
        }

        throw new TungstenCommandException(
            Options.ExecutablePath,
            [.. Options.LauncherArguments, .. arguments],
            execution.ExitCode,
            execution.StandardOutput,
            execution.StandardError);
    }

    private static void TryKillProcess(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Best-effort cleanup only.
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Best-effort cleanup only.
        }
    }

    private sealed record TungstenProcessResult(int ExitCode, string StandardOutput, string StandardError);
}
