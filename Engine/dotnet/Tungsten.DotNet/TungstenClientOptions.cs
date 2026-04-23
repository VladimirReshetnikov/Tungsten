using System.Text.Json;

namespace Tungsten.DotNet;

/// <summary>
/// Configures how the Tungsten .NET client launches the underlying Tungsten CLI.
/// </summary>
public sealed record TungstenClientOptions
{
    /// <summary>
    /// Gets the executable path used to launch Tungsten. Defaults to <c>python</c>.
    /// </summary>
    public string ExecutablePath { get; init; } = "python";

    /// <summary>
    /// Gets launcher arguments that appear before the Tungsten command arguments. The default is <c>-m tungsten</c>.
    /// </summary>
    public IReadOnlyList<string> LauncherArguments { get; init; } = ["-m", "tungsten"];

    /// <summary>
    /// Gets the working directory for launched commands.
    /// </summary>
    public string? WorkingDirectory { get; init; }

    /// <summary>
    /// Gets the source root containing the Python <c>tungsten</c> package. When set, the client prepends it to <c>PYTHONPATH</c>.
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
    /// Builds client options for this repository's checked-out Tungsten layout.
    /// </summary>
    public static TungstenClientOptions CreateForRepositoryRoot(string repositoryRoot, string executablePath = "python")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryRoot);
        var fullRoot = Path.GetFullPath(repositoryRoot);
        var tungstenRoot = Path.Combine(fullRoot, "src", "Tungsten");
        var sourceRoot = Path.Combine(tungstenRoot, "src");
        var packageRoot = Path.Combine(sourceRoot, "tungsten");

        if (!File.Exists(Path.Combine(tungstenRoot, "pyproject.toml")) || !Directory.Exists(packageRoot))
        {
            throw new DirectoryNotFoundException(
                $"Could not find a Tungsten repository layout under '{fullRoot}'. Expected '{tungstenRoot}'.");
        }

        return new TungstenClientOptions
        {
            ExecutablePath = executablePath,
            WorkingDirectory = fullRoot,
            TungstenSourceRoot = sourceRoot,
        };
    }

    /// <summary>
    /// Discovers a repository root by walking parent directories and then builds Tungsten client options for it.
    /// </summary>
    public static TungstenClientOptions CreateForDiscoveredRepository(string? startDirectory = null, string executablePath = "python")
    {
        var repositoryRoot = TryFindRepositoryRoot(startDirectory)
            ?? throw new DirectoryNotFoundException(
                $"Could not discover a repository root containing src{Path.DirectorySeparatorChar}Tungsten.");
        return CreateForRepositoryRoot(repositoryRoot, executablePath);
    }

    /// <summary>
    /// Tries to discover a repository root containing the Tungsten workspace.
    /// </summary>
    public static string? TryFindRepositoryRoot(string? startDirectory = null)
    {
        var currentPath = Path.GetFullPath(startDirectory ?? AppContext.BaseDirectory);
        var current = new DirectoryInfo(currentPath);
        while (current is not null)
        {
            var tungstenRoot = Path.Combine(current.FullName, "src", "Tungsten");
            if (
                File.Exists(Path.Combine(tungstenRoot, "pyproject.toml")) &&
                File.Exists(Path.Combine(tungstenRoot, "src", "tungsten", "cli.py")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        return null;
    }
}
