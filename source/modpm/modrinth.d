module modpm.modrinth;

import core.time : dur;
import std.conv : to;
import std.json : JSONException;
import std.net.curl : CurlException, HTTP, HTTPStatusException;
import std.uri : encodeComponent;

import modpm.jsonio;

class ModrinthException : Exception
{
    int status;

    this(string msg, int status = 0, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        this.status = status;
    }
}

final class GameVersion
{
    string name;
    string type;

    this(string name, string type)
    {
        this.name = name;
        this.type = type;
    }

    static GameVersion fromJson(JsonView json)
    {
        return new GameVersion(json.str("version"), json.str("version_type"));
    }
}

final class Dependency
{
    string projectId;
    string versionId;
    string fileName;
    string type;

    static Dependency fromJson(JsonView json)
    {
        auto d = new Dependency();
        d.projectId = json.str("project_id");
        d.versionId = json.str("version_id");
        d.fileName = json.str("file_name");
        d.type = json.str("dependency_type");
        return d;
    }
}

final class VersionFile
{
    string filename;
    string url;
    string sha1;
    long size;
    bool primary;
}

final class VersionInfo
{
    string id;
    string projectId;
    string versionNumber;
    string versionType;
    string environment;
    VersionFile[] files;
    VersionFile primaryFile;
    string[] loaders;
    string[] gameVersions;
    Dependency[] dependencies;

    static VersionInfo fromJson(JsonView json)
    {
        auto v = new VersionInfo();
        v.id = json.str("id");
        v.projectId = json.str("project_id");
        v.versionNumber = json.str("version_number");
        v.versionType = json.str("version_type");
        v.environment = json.str("environment");
        v.loaders = json.strings("loaders");
        v.gameVersions = json.strings("game_versions");
        foreach (dependency; json.list("dependencies"))
            v.dependencies ~= Dependency.fromJson(dependency);

        foreach (file; json.list("files"))
        {
            auto f = new VersionFile();
            f.filename = file.str("filename");
            f.url = file.str("url");
            f.sha1 = file.child("hashes").str("sha1");
            f.size = file.integer("size");
            f.primary = file.isTrue("primary");
            v.files ~= f;
            if (v.primaryFile is null || (f.primary && !v.primaryFile.primary))
                v.primaryFile = f;
        }
        return v;
    }

    @property string primarySha1() const
    {
        return primaryFile is null ? "" : primaryFile.sha1;
    }

    bool isPrimary(string sha1) const
    {
        return primarySha1.length == 0 || primarySha1 == sha1;
    }
}

final class ProjectInfo
{
    string id;
    string slug;
    string title;
    string projectType;

    this(string id, string slug, string title)
    {
        this.id = id;
        this.slug = slug;
        this.title = title;
    }

    @property string displayName() const
    {
        if (title.length)
            return title;
        if (slug.length)
            return slug;
        return id;
    }

    static ProjectInfo fromJson(JsonView json)
    {
        auto project = new ProjectInfo(json.str("id"), json.str("slug"), json.str("title"));
        project.projectType = json.str("project_type");
        return project;
    }
}

final class ModrinthClient
{
    enum maxIdsPerRequest = 740;

    private string userAgent_;
    private string apiBase_;

    this(string userAgent, string apiBase = "https://api.modrinth.com/v2")
    {
        userAgent_ = userAgent;
        apiBase_ = apiBase;
    }

    GameVersion[] fetchGameVersions()
    {
        auto response = request(apiBase_ ~ "/tag/game_version");
        requireArray(response);

        GameVersion[] result;
        foreach (entry; response.items())
            result ~= GameVersion.fromJson(entry);
        return result;
    }

    VersionInfo[string] versionsFromHashes(string[] sha1s)
    {
        VersionInfo[string] result;
        if (sha1s.length == 0)
            return result;

        auto requestBody = new JsonObject()
            .putString("algorithm", "sha1")
            .putStrings("hashes", sha1s)
            .build();

        auto response = request(apiBase_ ~ "/version_files", requestBody.toString());
        if (!response.isObject)
            throw new ModrinthException("unexpected response shape from Modrinth");
        foreach (hash, version_; response.fields())
            result[hash] = VersionInfo.fromJson(version_);
        return result;
    }

    ProjectInfo[string] fetchProjects(string[] ids)
    {
        ProjectInfo[string] result;
        for (size_t start = 0; start < ids.length; start += maxIdsPerRequest)
        {
            size_t end = start + maxIdsPerRequest;
            if (end > ids.length)
                end = ids.length;

            immutable idList = JsonObject.stringArray(ids[start .. end]).toString();
            auto response = request(apiBase_ ~ "/projects?ids=" ~ encodeComponent(idList));
            requireArray(response);
            foreach (entry; response.items())
            {
                auto project = ProjectInfo.fromJson(entry);
                result[project.id] = project;
            }
        }
        return result;
    }

    VersionInfo[] fetchVersions(string projectId, string[] loaders, string gameVersion)
    {
        immutable query = "?loaders=" ~ encodeComponent(JsonObject.stringArray(loaders).toString())
            ~ "&game_versions=" ~ encodeComponent(JsonObject.stringArray([gameVersion]).toString())
            ~ "&include_changelog=false";
        auto response = request(apiBase_ ~ "/project/" ~ encodeComponent(projectId) ~ "/version" ~ query);
        requireArray(response);

        VersionInfo[] result;
        foreach (entry; response.items())
            result ~= VersionInfo.fromJson(entry);
        return result;
    }

    VersionInfo[string] fetchVersionsByIds(string[] ids)
    {
        VersionInfo[string] result;
        for (size_t start = 0; start < ids.length; start += maxIdsPerRequest)
        {
            size_t end = start + maxIdsPerRequest;
            if (end > ids.length)
                end = ids.length;

            immutable idList = JsonObject.stringArray(ids[start .. end]).toString();
            auto response = request(apiBase_ ~ "/versions?ids=" ~ encodeComponent(idList));
            requireArray(response);
            foreach (entry; response.items())
            {
                auto version_ = VersionInfo.fromJson(entry);
                result[version_.id] = version_;
            }
        }
        return result;
    }

    private JsonView request(string url, string postBody = null)
    {
        ubyte[] buffer;
        try
        {
            auto http = HTTP(url);
            http.setUserAgent(userAgent_);
            http.connectTimeout = dur!"seconds"(15);
            http.dataTimeout = dur!"seconds"(30);
            http.onReceive = (ubyte[] data) { buffer ~= data; return data.length; };
            if (postBody !is null)
                http.setPostData(postBody, "application/json");
            http.perform();

            immutable code = http.statusLine.code;
            if (code / 100 != 2)
                throw new ModrinthException(describeStatus(code), code);
        }
        catch (HTTPStatusException e)
            throw new ModrinthException(describeStatus(e.status), e.status);
        catch (CurlException e)
            throw new ModrinthException("network error: " ~ e.msg);

        try
            return JsonView.parse(cast(string) buffer);
        catch (JSONException e)
            throw new ModrinthException("unreadable response from Modrinth: " ~ e.msg);
    }

    private static void requireArray(JsonView response)
    {
        if (!response.isArray)
            throw new ModrinthException("unexpected response shape from Modrinth");
    }

    private static string describeStatus(int code)
    {
        if (code == 429)
            return "Modrinth rate limit hit, try again in a minute";
        return "Modrinth returned HTTP " ~ code.to!string;
    }
}
