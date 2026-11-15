module modpm.fsid;

import std.file : exists;
import std.path : absolutePath, dirName;

version (Windows)
{
    import core.sys.windows.windows;
    import std.utf : toUTF16z;
}
else version (Posix)
{
    import core.sys.posix.sys.stat : stat, stat_t;
    import std.string : toStringz;
}

final class FilesystemChecker
{
    bool onSameFilesystem(string a, string b) const
    {
        return idOf(nearestExisting(a)) == idOf(nearestExisting(b));
    }

    private static string nearestExisting(string path)
    {
        auto p = absolutePath(path);
        while (!exists(p))
        {
            auto parent = dirName(p);
            if (parent == p)
                break;
            p = parent;
        }
        return p;
    }

    private static ulong idOf(string existingPath)
    {
        version (Posix)
        {
            stat_t st;
            if (stat(existingPath.toStringz, &st) != 0)
                throw new Exception("cannot stat " ~ existingPath);
            return cast(ulong) st.st_dev;
        }
        else version (Windows)
        {
            HANDLE handle = CreateFileW(existingPath.toUTF16z, 0,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
                OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
            if (handle == INVALID_HANDLE_VALUE)
                throw new Exception("cannot open " ~ existingPath);
            scope (exit)
                CloseHandle(handle);

            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle, &info))
                throw new Exception("cannot query " ~ existingPath);
            return info.dwVolumeSerialNumber;
        }
        else
            static assert(0, "unsupported platform");
    }
}
