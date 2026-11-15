module modpm.manifest;

import std.conv : to;
import std.file : exists, mkdirRecurse, rename, rmdirRecurse;
import std.json : JSONValue;
import std.path : absolutePath, buildPath, dirName;

import modpm.atomicfile;
import modpm.jsonio;
import modpm.side;

final class ScopeConfig : JsonSerializable
{
    static immutable string[] channelOrder = ["release", "beta", "alpha"];

    string directory;
    string gameVersion;
    string[] loaders;
    string[] channels;
    Side side;

    this(string directory, string gameVersion, string[] loaders,
        string[] channels, Side side)
    {
        this.directory = directory;
        this.gameVersion = gameVersion;
        this.loaders = loaders;
        this.channels = channels;
        this.side = side;
    }

    static string[] channelsUpTo(string level)
    {
        foreach (i, channel; channelOrder)
            if (channel == level)
                return channelOrder[0 .. i + 1].dup;
        throw new Exception("unknown channel: " ~ level);
    }

    JSONValue toJson() const
    {
        return new JsonObject()
            .putStrings("channels", channels)
            .putString("directory", directory)
            .putString("game_version", gameVersion)
            .putStrings("loaders", loaders)
            .putString("side", side.to!string)
            .build();
    }
}

final class Entry : JsonSerializable
{
    string slug;
    string title;
    string versionId;
    string versionNumber;
    string filename;
    string sha1;
    string reason;
    string[string] requires;
    bool frozen;

    JSONValue toJson() const
    {
        auto requiresJson = new JsonObject();
        foreach (projectId, pinned; requires)
        {
            if (pinned.length)
                requiresJson.putString(projectId, pinned);
            else
                requiresJson.putNull(projectId);
        }

        auto json = new JsonObject()
            .putString("slug", slug)
            .putString("title", title)
            .putString("version_id", versionId)
            .putString("version_number", versionNumber)
            .putString("filename", filename)
            .putString("sha1", sha1)
            .putString("reason", reason)
            .putJson("requires", requiresJson.build());
        if (frozen)
            json.putFlag("frozen", true);
        return json.build();
    }
}

final class Manifest : JsonSerializable
{
    enum schema = 1;

    long head;
    ScopeConfig config;
    Entry[string] installed;

    this(ScopeConfig config)
    {
        this.config = config;
    }

    void add(string projectId, Entry entry)
    {
        installed[projectId] = entry;
    }

    JSONValue toJson() const
    {
        auto installedJson = new JsonObject();
        foreach (projectId, entry; installed)
            installedJson.putJson(projectId, entry.toJson());

        return new JsonObject()
            .putNumber("schema", schema)
            .putNumber("head", head)
            .putJson("scope", config.toJson())
            .putJson("installed", installedJson.build())
            .build();
    }
}

final class ScopeDirectory
{
    enum stateDirName = ".modpm";

    private string baseDir_;

    this(string baseDir)
    {
        baseDir_ = baseDir;
    }

    static ScopeDirectory findEnclosing(string startDir)
    {
        auto dir = absolutePath(startDir);
        while (true)
        {
            auto candidate = new ScopeDirectory(dir);
            if (exists(candidate.manifestPath()))
                return candidate;
            immutable parent = dirName(dir);
            if (parent == dir)
                return null;
            dir = parent;
        }
    }

    string path() const
    {
        return buildPath(baseDir_, stateDirName);
    }

    string manifestPath() const
    {
        return buildPath(path(), "manifest.json");
    }

    bool isInitialised() const
    {
        return exists(path());
    }

    void create(Manifest manifest)
    {
        immutable stagingPath = path() ~ ".tmp";

        if (isInitialised())
            throw new Exception(path() ~ " already exists");
        if (exists(stagingPath))
            rmdirRecurse(stagingPath);

        scope (failure)
        {
            if (exists(stagingPath))
                rmdirRecurse(stagingPath);
        }

        mkdirRecurse(buildPath(stagingPath, "downloads"));
        mkdirRecurse(absolutePath(manifest.config.directory, baseDir_));
        new JsonDocument(manifest.toJson()).save(buildPath(stagingPath, "manifest.json"));
        new AtomicFile(buildPath(stagingPath, ".gitignore"))
            .write("downloads/\nplan.json\nlock\n");
        rename(stagingPath, path());
    }
}
