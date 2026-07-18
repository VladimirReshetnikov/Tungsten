using System.Diagnostics;

static string? FindTungstenNativeExecutable()
{
    var configured = Environment.GetEnvironmentVariable("TUNGSTEN_EXECUTABLE");
    if (!string.IsNullOrWhiteSpace(configured))
    {
        return configured;
    }

    var executableName = OperatingSystem.IsWindows() ? "tungsten-cpp.exe" : "tungsten-cpp";
    var relativeCandidates = new[]
    {
        executableName,
        Path.Combine("Release", executableName),
        Path.Combine("Debug", executableName),
        Path.Combine("RelWithDebInfo", executableName),
        Path.Combine("MinSizeRel", executableName),
    };
    var directory = new DirectoryInfo(AppContext.BaseDirectory);
    while (directory is not null)
    {
        foreach (var relativeCandidate in relativeCandidates)
        {
            var candidate = Path.Combine(
                directory.FullName,
                "build",
                "cpp",
                relativeCandidate);
            if (File.Exists(candidate))
            {
                return candidate;
            }
            var siblingCandidate = Path.Combine(
                directory.FullName,
                "Engine",
                "build",
                "cpp",
                relativeCandidate);
            if (File.Exists(siblingCandidate))
            {
                return siblingCandidate;
            }
        }

        directory = directory.Parent;
    }

    return "tungsten-cpp";
}

var startInfo = new ProcessStartInfo
{
    FileName = FindTungstenNativeExecutable(),
    UseShellExecute = false,
};
foreach (var argument in args)
{
    startInfo.ArgumentList.Add(argument);
}

try
{
    using var process = Process.Start(startInfo);
    if (process is null)
    {
        Console.Error.WriteLine("tungsten.exe could not start the native Tungsten engine.");
        return 2;
    }

    process.WaitForExit();
    return process.ExitCode;
}
catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
{
    Console.Error.WriteLine("tungsten.exe could not start the native Tungsten engine. Build tungsten-cpp with CMake or set TUNGSTEN_EXECUTABLE.");
    Console.Error.WriteLine(ex.Message);
    return 2;
}
