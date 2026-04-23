# Tungsten .NET API

- Status: Informational and operational (typed C#/.NET API guide and usage examples)
- Audience: C#/.NET application authors, automation developers, maintainers, and reviewers
- Scope: `src/Tungsten/dotnet` typed wrapper over Tungsten's JSON-first CLI
- Created (UTC): 2026-04-23T19:01:41Z
- Updated (UTC): 2026-04-23T21:12:16Z
- Repository HEAD: e5c1e2b48eea1534033dbf6bcd549b2059db91e7
- Related code:
  - `src/Tungsten/dotnet/Tungsten.DotNet/`
  - `src/Tungsten/dotnet/Tungsten.DotNet.Tests/`
  - `src/Tungsten/src/tungsten/cli.py`
- Related docs:
  - [Project README](../README.md)
  - [Documentation Index](./README.md)
  - [Usage Reference](./usage-reference.md)
  - [Architecture](./architecture.md)

## Summary

`Tungsten.DotNet` is a typed .NET wrapper over Tungsten's JSON-first Python CLI. It does not try to
reimplement Tungsten in C#, embed Python, or talk to the Wolfram runtime directly. Instead, it
gives C# callers a familiar, strongly typed process-wrapper API for the parts of Tungsten that are
already stable and useful:

- environment discovery;
- kernel-backed evaluation;
- notebook creation, inspection, and patching;
- kernel-free expression parsing and evaluation;
- local documentation indexing and search;
- FrontEnd control;
- Notebook Assistant automation;
- inline-box string composition and extraction.

The underlying execution model remains simple and explicit:

1. `TungstenClient` launches `python -m tungsten ...`.
2. Tungsten returns JSON.
3. The client deserializes that JSON into typed response models.

That design keeps the .NET layer thin, predictable, and aligned with Tungsten's existing CLI and
PowerShell surfaces.

## What the .NET layer is for

Use the .NET client when you want to call Tungsten from:

- console applications;
- test fixtures;
- services and background workers;
- GUI tools that want structured Wolfram automation without shell-script plumbing;
- larger .NET systems that already prefer `Task`, typed options objects, `CancellationToken`, and
  exception-based failure handling.

Do not think of it as a general-purpose Wolfram SDK. The source of truth is still Tungsten itself,
and Tungsten in turn delegates evaluation fidelity to the real local Wolfram installation.

## Package layout

The current .NET surface lives in two projects:

- `src/Tungsten/dotnet/Tungsten.DotNet/`
  - production client library;
- `src/Tungsten/dotnet/Tungsten.DotNet.Tests/`
  - argument-shape, deserialization, and repo-local integration coverage.

The main public types are:

- `TungstenClient`
  - the primary entry point;
- `TungstenClientOptions`
  - launch configuration, working directory, timeout, environment variables, and repo-local
    discovery helpers;
- `TungstenInputSource`
  - inline code versus file-backed input;
- `TungstenNotebookCellSelector`
  - notebook cell targeting by flat index, structural path, `ExpressionUUID`, `CellID`, or cell
    tag;
- `TungstenNotebookAssistantAskOptions`
  - option bag for `assistant ask-cell`;
- `TungstenNotebookAssistantCaptureOptions`
  - option bag for `assistant capture-inline`;
- typed response records in `TungstenResponses.cs`;
- `TungstenCommandException` and `TungstenProtocolException`
  - process-level and JSON-level failure modes.

## Runtime expectations

The .NET client assumes:

- a usable `python` executable on `PATH`, unless `TungstenClientOptions.ExecutablePath` points
  somewhere else;
- either:
  - a repo-local Tungsten checkout under `src/Tungsten`, or
  - a separately installable/importable Python `tungsten` package that your chosen launcher can
    resolve;
- the same Tungsten prerequisites as the Python CLI for the specific feature you use.

Kernel-free calls such as notebook inspection or expression parsing do not require a running
Wolfram kernel. Kernel-backed and FrontEnd-backed calls still depend on the machine-local Wolfram
installation.

## Referencing the library

The simplest repo-local setup is a project reference:

```xml
<ItemGroup>
  <ProjectReference Include="<repository-root>\src\Tungsten\dotnet\Tungsten.DotNet\Tungsten.DotNet.csproj" />
</ItemGroup>
```

If you keep your own solution elsewhere, a direct absolute reference is fine for local usage. If
you later package the library or move it into another solution layout, the API surface stays the
same.

## Constructing a client

### Recommended repo-local setup

If your app is running against this repository checkout, use the repo helpers:

```csharp
using Tungsten.DotNet;

var client = TungstenClient.CreateForRepositoryRoot(@"<repository-root>");
```

That configures:

- `python` as the launcher;
- `-m tungsten` as the command prefix;
- `<repository-root>` as the working directory;
- `<repository-root>\src\Tungsten\src` prepended to `PYTHONPATH`.

### Discovery-based setup

If your executable may start from somewhere inside the repo tree:

```csharp
using Tungsten.DotNet;

var client = TungstenClient.CreateForDiscoveredRepository(AppContext.BaseDirectory);
```

This walks parent directories until it finds a repo root that contains `src/Tungsten`.

### Fully manual setup

If you need a non-default Python launcher, a different working directory, or extra environment
variables:

```csharp
using Tungsten.DotNet;

var client = new TungstenClient(
    new TungstenClientOptions
    {
        ExecutablePath = @"C:\Users\vresh\.pyenv\pyenv-win\versions\3.13.13\python.exe",
        LauncherArguments = ["-m", "tungsten"],
        WorkingDirectory = @"<repository-root>",
        TungstenSourceRoot = @"<repository-root>\src\Tungsten\src",
        DefaultTimeout = TimeSpan.FromMinutes(10),
        EnvironmentVariables = new Dictionary<string, string?>
        {
            ["TUNGSTEN_WOLFRAM_HOME"] = @"C:\Program Files\Wolfram Research\Wolfram\14.3",
        },
    });
```

## Usage examples

### Environment discovery

```csharp
using Tungsten.DotNet;

var client = TungstenClient.CreateForRepositoryRoot(@"<repository-root>");
var environment = await client.GetEnvironmentAsync(probe: true);

Console.WriteLine(environment.InstallDir);
Console.WriteLine(environment.KernelCli);
Console.WriteLine(environment.DefaultIndexPath);
```

Use `probe: true` when you want Tungsten to run live kernel and FrontEnd probes instead of only
returning discovered paths.

### Kernel-backed evaluation

Inline code:

```csharp
using Tungsten.DotNet;

var result = await client.EvaluateKernelAsync(
    TungstenInputSource.FromCode("Print[Prime[10]]; Prime[20]"));

Console.WriteLine(result.Success);
Console.WriteLine(result.Result);
```

FrontEnd-backed evaluation:

```csharp
var result = await client.EvaluateKernelAsync(
    TungstenInputSource.FromCode("NotebookLocate[\"paclet:ref/NotebookGet\"]"),
    requireFrontEnd: true);
```

File-backed evaluation:

```csharp
var result = await client.EvaluateKernelAsync(
    TungstenInputSource.FromFile(@"C:\work\demo.wl"),
    workingDirectory: @"C:\work");
```

### Notebook creation and inspection

```csharp
using Tungsten.DotNet;

var notebookPath = Path.Combine(Path.GetTempPath(), "tungsten-dotnet-demo.nb");

await client.CreateNotebookAsync(
    notebookPath,
    title: "DotNet Demo",
    cells:
    [
        new TungstenNotebookCellSpec("Text", "Created from C#"),
        new TungstenNotebookCellSpec("Input", "2+2"),
    ]);

var notebook = await client.InspectNotebookAsync(notebookPath);
Console.WriteLine(notebook.Title);
Console.WriteLine(notebook.CellCount);
```

### Notebook patching

You can either point Tungsten at an existing JSON patch file or hand it a .NET object that
serializes to the same shape.

Patch from an in-memory object:

```csharp
var patched = await client.PatchNotebookAsync(
    notebookPath,
    new
    {
        operations = new object[]
        {
            new
            {
                op = "append_cell",
                style = "Input",
                text = "Expand[(x + y)^3]",
            },
            new
            {
                op = "set_option",
                name = "WindowTitle",
                value_expr = "\"DotNet Demo (Patched)\"",
            },
        },
    });
```

Patch from a file:

```csharp
var patched = await client.PatchNotebookFromFileAsync(
    notebookPath,
    @"C:\work\tungsten-patch.json");
```

### Kernel-free expression parsing and evaluation

```csharp
using Tungsten.DotNet;

var parsed = await client.ParseExpressionAsync(
    TungstenInputSource.FromCode("1 + 2 x^3"),
    form: TungstenExpressionForm.Input);

Console.WriteLine(parsed.FullForm);

var evaluated = await client.EvaluateExpressionAsync(
    TungstenInputSource.FromCode("ReplacePart[f[a, b, c], 2 -> x]"));

Console.WriteLine(evaluated.Result?.FullForm); // f[a, x, c]
```

StandardForm parsing is available too:

```csharp
var parsed = await client.ParseExpressionAsync(
    TungstenInputSource.FromCode(@"FractionBox[""x"", ""y""]"),
    form: TungstenExpressionForm.Standard);
```

### Documentation index, search, and read

```csharp
var index = await client.BuildDocumentationIndexAsync();
Console.WriteLine(index.IndexPath);

var hits = await client.SearchDocumentationAsync("NotebookGet", limit: 5);
foreach (var hit in hits.Hits)
{
    Console.WriteLine($"{hit.Title} -> {hit.Path}");
}

var page = await client.ReadDocumentationAsync("NotebookGet");
Console.WriteLine(page.Title);
Console.WriteLine(page.Text);
```

### FrontEnd control

Probe FrontEnd availability:

```csharp
var probe = await client.ProbeFrontEndAsync(requireSuccess: true);
Console.WriteLine(probe.Success);
```

Open a notebook:

```csharp
await client.OpenNotebookInFrontEndAsync(
    @"C:\work\analysis.nb",
    requireSuccess: true);
```

Open documentation:

```csharp
await client.OpenDocumentationInFrontEndAsync(
    "NotebookGet",
    requireSuccess: true);
```

Execute a FrontEnd token:

```csharp
await client.ExecuteFrontEndTokenAsync(
    "SelectionOpenAllGroups",
    notebookPath: @"C:\work\analysis.nb",
    requireSuccess: true);
```

Run arbitrary FrontEnd code:

```csharp
await client.RunFrontEndCodeAsync(
    "FrontEndTokenExecute[\"EvaluatorQuit\"]",
    wrapUsingFrontEnd: true,
    requireSuccess: true);
```

### Notebook Assistant

Ask Notebook Assistant about a selected cell and insert the first Wolfram Language code block below
that cell:

```csharp
using Tungsten.DotNet;

var response = await client.AskNotebookAssistantAsync(
    new TungstenNotebookAssistantAskOptions
    {
        NotebookPath = @"C:\work\analysis.nb",
        CellSelector = TungstenNotebookCellSelector.ByExpressionUuid("9f5b4f2c-6c53-41c0-9589-1b65d25c98c8"),
        Question = "Reply only with Wolfram Language code that improves this cell.",
        InsertWolframCodeBelow = true,
        Save = true,
        CloseAssistantNotebook = true,
        RequireSuccess = true,
    });

Console.WriteLine(response.AssistantSuccess);
Console.WriteLine(response.Assistant?.ResponseText);
```

Prepare the inline assistant popup for a human-in-the-loop flow:

```csharp
await client.PrepareInlineNotebookAssistantAsync(
    @"C:\work\analysis.nb",
    TungstenNotebookCellSelector.ByIndex(7),
    requireSuccess: true);
```

Capture the current inline assistant response and insert every Wolfram code block:

```csharp
var capture = await client.CaptureInlineNotebookAssistantAsync(
    new TungstenNotebookAssistantCaptureOptions
    {
        NotebookPath = @"C:\work\analysis.nb",
        CellSelector = TungstenNotebookCellSelector.ByIndex(7),
        InsertAllWolframCodeBelow = true,
        Save = true,
        RequireSuccess = true,
    });
```

### Inline-box string composition and extraction

Compose an inline-box string literal:

```csharp
var composed = await client.ComposeInlineBoxAsync(
    ["GraphicsBox[{CircleBox[]}]"],
    prefix: "icon: ");

Console.WriteLine(composed.StringValue);
Console.WriteLine(composed.StringLiteral);
```

Extract box-bearing objects from a notebook cell:

```csharp
var extracted = await client.ExtractInlineBoxesFromNotebookCellAsync(
    @"C:\work\inline-box-demo.nb",
    TungstenNotebookCellSelector.ByExpressionUuid("uuid-inline-box"),
    prefix: "icon: ",
    requireSuccess: true);

Console.WriteLine(extracted.StringLiteral);
```

### Generic escape hatch for newer or less common commands

`InvokeJsonAsync<TResponse>()` is intentionally public. Use it when Tungsten grows a new JSON
command before the typed wrapper adds a dedicated method, or when your app wants to deserialize a
very custom payload.

```csharp
using System.Text.Json;
using Tungsten.DotNet;

var payload = await client.InvokeJsonAsync<JsonElement>(
    [
        "docs",
        "search",
        "NotebookGet",
        "--limit",
        "3",
    ]);
```

This escape hatch is a compatibility valve, not the recommended default for common workflows.

## Error handling

The .NET layer follows a straightforward split:

- `TungstenCommandException`
  - Tungsten launched, but the process returned a non-zero exit code;
- `TungstenProtocolException`
  - Tungsten returned exit code `0`, but the output was not valid JSON for the requested response
    type.

Example:

```csharp
try
{
    var result = await client.EvaluateExpressionAsync(
        TungstenInputSource.FromCode("ReplacePart[f[a, b, c], 2 -> x]"));
}
catch (TungstenCommandException ex)
{
    Console.Error.WriteLine(ex.StandardError);
}
catch (TungstenProtocolException ex)
{
    Console.Error.WriteLine(ex.StandardOutput);
}
```

## Cancellation and timeouts

Every async API accepts a `CancellationToken`, and `TungstenClientOptions.DefaultTimeout` controls
the per-command timeout. On timeout, the client kills the launched process tree and throws
`TimeoutException`.

```csharp
using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
var environment = await client.GetEnvironmentAsync(probe: true, cts.Token);
```

## Relationship to the CLI and PowerShell surfaces

The .NET client is not a separate implementation of Tungsten semantics. It is a projection over the
same CLI that powers:

- direct Python invocation through `python -m tungsten ...`;
- the repo's PowerShell module in `pwsh/Tungsten.psm1`.

That has two important consequences:

- when a Tungsten CLI feature grows, the .NET layer can adopt it without inventing a new execution
  model;
- when diagnosing a problem, you can often compare the failing .NET call to the equivalent CLI
  command from [usage-reference.md](./usage-reference.md).

## Validation

The current .NET wrapper was validated with:

```powershell
dotnet test .\src\Tungsten\dotnet\Tungsten.DotNet.slnx
```
