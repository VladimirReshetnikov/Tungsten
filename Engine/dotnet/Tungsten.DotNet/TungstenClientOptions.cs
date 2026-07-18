using System.Text.Json;

namespace Tungsten.DotNet;

/// <summary>
/// Configures how the Tungsten .NET client launches the underlying Tungsten CLI.
/// </summary>
public sealed record TungstenClientOptions
{
    /// <summary>
    /// Gets the executable path used to launch native Tungsten. Defaults to <c>tungsten-cpp</c> on <c>PATH</c>.
    /// </summary>
    public string ExecutablePath { get; init; } = "tungsten-cpp";

    /// <summary>
    /// Gets optional launcher arguments that appear before the Tungsten command arguments.
    /// </summary>
    public IReadOnlyList<string> LauncherArguments { get; init; } = [];

    /// <summary>
    /// Gets the working directory for launched commands.
    /// </summary>
    public string? WorkingDirectory { get; init; }

    /// <summary>
    /// Gets an optional legacy source root to prepend to <c>PYTHONPATH</c> for custom launchers.
    /// Native Tungsten does not require Python or this setting.
    /// </summary>
    public string? TungstenSourceRoot { get; init; }

    /// <summary>
    /// Gets additional environment variables to set for Tungsten commands.
    /// </summary>
    public IReadOnlyDictionary<string, string?> EnvironmentVariables { get; init; }
        = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Gets the default timeout for launched commands.
    /// </summary>
    public TimeSpan? DefaultTimeout { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Gets JSON serializer options used for Tungsten payloads.
    /// </summary>
    public JsonSerializerOptions JsonSerializerOptions { get; init; } = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    /// <summary>
    /// Builds client options for this repository's checked-out C++ Tungsten engine layout.
    /// </summary>
    public static TungstenClientOptions CreateForRepositoryRoot(string repositoryRoot, string? executablePath = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryRoot);
        var fullRoot = Path.GetFullPath(repositoryRoot);
        var tungstenRoot = Path.Combine(fullRoot, "Engine");
        if (!File.Exists(Path.Combine(tungstenRoot, "CMakeLists.txt")) ||
            !File.Exists(Path.Combine(tungstenRoot, "cpp", "src", "main.cpp")))
        {
            throw new DirectoryNotFoundException(
                $"Could not find a Tungsten C++ engine under '{tungstenRoot}'. " +
                "Expected CMakeLists.txt and cpp/src/main.cpp.");
        }

        return new TungstenClientOptions
        {
            ExecutablePath = executablePath ?? ResolveRepositoryExecutable(tungstenRoot),
            WorkingDirectory = tungstenRoot,
        };
    }

    /// <summary>
    /// Discovers a repository root containing the C++ Tungsten engine and then builds client options for it.
    /// </summary>
    public static TungstenClientOptions CreateForDiscoveredRepository(string? startDirectory = null, string? executablePath = null)
    {
        var repositoryRoot = TryFindRepositoryRoot(startDirectory)
            ?? throw new DirectoryNotFoundException(
                "Could not discover a repository root containing " +
                "Engine/CMakeLists.txt and Engine/cpp/src/main.cpp.");
        return CreateForRepositoryRoot(repositoryRoot, executablePath);
    }

    /// <summary>
    /// Tries to discover a repository root containing the C++ Tungsten engine workspace.
    /// </summary>
    public static string? TryFindRepositoryRoot(string? startDirectory = null)
    {
        var currentPath = Path.GetFullPath(startDirectory ?? AppContext.BaseDirectory);
        var current = new DirectoryInfo(currentPath);
        while (current is not null)
        {
            var tungstenRoot = Path.Combine(current.FullName, "Engine");
            if (
                File.Exists(Path.Combine(tungstenRoot, "CMakeLists.txt")) &&
                File.Exists(Path.Combine(tungstenRoot, "cpp", "src", "main.cpp")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        return null;
    }

    private static string ResolveRepositoryExecutable(string tungstenRoot)
    {
        var configured = Environment.GetEnvironmentVariable("TUNGSTEN_EXECUTABLE");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured;
        }

        var executableName = OperatingSystem.IsWindows() ? "tungsten-cpp.exe" : "tungsten-cpp";
        var buildRoot = Path.Combine(tungstenRoot, "build", "cpp");
        foreach (var relativeCandidate in new[]
        {
            executableName,
            Path.Combine("Release", executableName),
            Path.Combine("Debug", executableName),
            Path.Combine("RelWithDebInfo", executableName),
            Path.Combine("MinSizeRel", executableName),
        })
        {
            var candidate = Path.Combine(buildRoot, relativeCandidate);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return "tungsten-cpp";
    }
}
