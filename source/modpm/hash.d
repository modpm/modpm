module modpm.hash;

import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA1;
import std.stdio : File;

final class FileHasher
{
    string sha1(string path)
    {
        SHA1 digest;
        digest.start();
        foreach (chunk; File(path, "rb").byChunk(64 * 1024))
            digest.put(chunk);
        return toHexString!(LetterCase.lower)(digest.finish()).idup;
    }
}
