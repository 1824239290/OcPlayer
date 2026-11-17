namespace OcPlayer.Windows.Services;

/// One path contract for the launcher, installed application and isolated tests.
internal static class AppPaths
{
    public static string DefaultDataDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcPlayer", "Windows");
    public static string DataDirectory => ResolveDataDirectory(Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY"));

    internal static string ResolveDataDirectory(string? value)
    {
        var path = string.IsNullOrWhiteSpace(value) ? DefaultDataDirectory : value.Trim();
        if (!Path.IsPathFullyQualified(path)) throw new InvalidOperationException("数据目录必须是完整的绝对路径。");
        path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        if (path.Equals(Path.TrimEndingDirectorySeparator(Path.GetPathRoot(path)!), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("不能将磁盘根目录用作应用数据目录。");
        if (IsWithin(path, AppContext.BaseDirectory))
            throw new InvalidOperationException("数据目录不能位于应用安装目录内，请选择独立的用户目录。");
        return path;
    }

    internal static bool IsWithin(string path, string root)
    {
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        path = Path.GetFullPath(path);
        return path.Equals(root, StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    internal static void RejectReparsePoints(string path, string root)
    {
        if (!IsWithin(path, root)) throw new IOException("文件路径超出数据目录。");
        for (var entry = Path.GetFullPath(path); IsWithin(entry, root); entry = Path.GetDirectoryName(entry)!)
        {
            if ((File.Exists(entry) || Directory.Exists(entry)) && (File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("数据操作不支持符号链接或目录联接。");
            if (entry.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)), StringComparison.OrdinalIgnoreCase)) break;
        }
    }
}
