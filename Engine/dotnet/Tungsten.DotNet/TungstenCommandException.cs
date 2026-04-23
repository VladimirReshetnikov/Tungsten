using System.Collections.ObjectModel;

namespace Tungsten.DotNet;

/// <summary>
/// Raised when a Tungsten CLI command exits unsuccessfully.
/// </summary>
public sealed class TungstenCommandException : TungstenException
{
    /// <summary>
    /// Initializes a new instance of the <see cref="TungstenCommandException"/> class.
    /// </summary>
    public TungstenCommandException(
        string executablePath,
        IReadOnlyList<string> arguments,
        int exitCode,
        string standardOutput,
        string standardError)
        : base($"Tungsten command exited with code {exitCode}: {executablePath} {string.Join(" ", arguments)}")
    {
        ExecutablePath = executablePath;
        Arguments = new ReadOnlyCollection<string>(arguments.ToArray());
        ExitCode = exitCode;
        StandardOutput = standardOutput;
        StandardError = standardError;
    }

    /// <summary>
    /// Gets the executable that was launched.
    /// </summary>
    public string ExecutablePath { get; }

    /// <summary>
    /// Gets the Tungsten command arguments that were passed to the executable.
    /// </summary>
    public IReadOnlyList<string> Arguments { get; }

    /// <summary>
    /// Gets the process exit code.
    /// </summary>
    public int ExitCode { get; }

    /// <summary>
    /// Gets the captured standard output.
    /// </summary>
    public string StandardOutput { get; }

    /// <summary>
    /// Gets the captured standard error.
    /// </summary>
    public string StandardError { get; }
}
