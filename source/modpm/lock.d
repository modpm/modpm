module modpm.lock;

import std.stdio : File;

version (Windows)
{
    import core.sys.windows.windows;
}
else version (Posix)
{
    private extern (C) int flock(int fd, int operation) nothrow @nogc;

    private enum lockExclusive = 2;
    private enum lockNonBlocking = 4;
}

final class ScopeLock
{
    private File file_;

    this(string path)
    {
        file_ = File(path, "ab");
        version (Posix)
        {
            if (flock(file_.fileno, lockExclusive | lockNonBlocking) != 0)
                throw new Exception("another modpm command is running in this scope");
        }
        else version (Windows)
        {
            OVERLAPPED overlapped;
            if (!LockFileEx(file_.windowsHandle,
                    LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped))
                throw new Exception("another modpm command is running in this scope");
        }
    }

    void release()
    {
        file_.close();
    }
}
