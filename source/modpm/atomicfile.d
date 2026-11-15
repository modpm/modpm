module modpm.atomicfile;

import std.file : exists, remove, rename;
import std.stdio : File;

final class AtomicFile
{
    private string path_;

    this(string path)
    {
        path_ = path;
    }

    void write(const(char)[] content)
    {
        immutable tmp = path_ ~ ".tmp";
        scope (failure)
        {
            if (exists(tmp))
                remove(tmp);
        }

        auto file = File(tmp, "wb");
        file.rawWrite(content);
        file.flush();
        file.sync();
        file.close();
        rename(tmp, path_);
    }
}
