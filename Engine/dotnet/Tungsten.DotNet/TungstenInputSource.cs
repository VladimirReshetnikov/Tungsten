namespace Tungsten.DotNet;

/// <summary>
/// Describes a Tungsten command input source, either inline code or a file path.
/// </summary>
public sealed record TungstenInputSource
{
    private TungstenInputSource(string? code, string? filePath)
    {
        if (string.IsNullOrWhiteSpace(code) == string.IsNullOrWhiteSpace(filePath))
        {
            throw new ArgumentException("Exactly one of code or filePath must be provided.");
        }

        Code = code;
        FilePath = filePath;
    }

    /// <summary>
    /// Gets the inline source text, if present.
    /// </summary>
    public string? Code { get; }

    /// <summary>
    /// Gets the file path source, if present.
    /// </summary>
    public string? FilePath { get; }

    /// <summary>
    /// Creates an inline-code input source.
    /// </summary>
    public static TungstenInputSource FromCode(string code)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(code);
        return new TungstenInputSource(code, filePath: null);
    }

    /// <summary>
    /// Creates a file-backed input source.
    /// </summary>
    public static TungstenInputSource FromFile(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        return new TungstenInputSource(code: null, filePath);
    }

    internal void AppendArguments(ICollection<string> arguments)
    {
        if (Code is not null)
        {
            arguments.Add("--code");
            arguments.Add(Code);
            return;
        }

        arguments.Add("--file");
        arguments.Add(FilePath!);
    }
}
