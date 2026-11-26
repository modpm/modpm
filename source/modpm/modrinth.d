module modpm.modrinth;

import core.stdc.config : c_long;
import std.conv : to;
import std.json : JSONException, JSONValue;
import std.string : fromStringz, toStringz;
import std.uri : encodeComponent;

import etc.c.curl;

import modpm.jsonio;

private enum Opt : int
{
    writeData = 10001,
    url = 10002,
    userAgent = 10018,
    httpHeader = 10023,
    postFieldSize = 60,
    copyPostFields = 10165,
    lowSpeedLimit = 19,
    lowSpeedTime = 20,
    followLocation = 52,
    connectTimeout = 78,
    noSignal = 99,
    writeFunction = 20011,
}

private enum responseCodeInfo = 2097154;

private extern (C) size_t onBody(char* data, size_t size, size_t count, void* userdata) nothrow
{
    auto buffer = cast(ubyte[]*) userdata;
    immutable bytes = size * count;
    try
        *buffer ~= cast(ubyte[]) data[0 .. bytes];
    catch (Throwable)
        return 0;
    return bytes;
}

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

final class SearchHit
{
    string projectId;
    string projectType;
    string slug;
    string title;
    string description;
    string author;
    string organization;
    string[] categories;
    long downloads;
    long follows;

    @property string ownerName() const
    {
        return organization.length ? organization : author;
    }

    @property string installSpec() const
    {
        return slug.length ? slug : projectId;
    }

    static SearchHit fromJson(JsonView json)
    {
        auto hit = new SearchHit();
        hit.projectId = json.str("project_id");
        hit.projectType = json.str("project_type");
        hit.slug = json.str("slug");
        hit.title = json.str("title");
        hit.description = json.str("description");
        hit.author = json.str("author");
        hit.organization = json.str("organization");
        hit.categories = json.strings("categories");
        hit.downloads = json.integer("downloads");
        hit.follows = json.integer("follows");
        return hit;
    }
}

final class SearchResults
{
    long totalHits;
    SearchHit[] hits;
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
        curl_global_init(cast(c_long) 3);
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

    SearchResults searchProjects(string query, string[][] facets, long limit, long offset, string index)
    {
        auto response = request(apiBase_ ~ "/search?query=" ~ encodeComponent(query)
                ~ "&limit=" ~ limit.to!string
                ~ "&offset=" ~ offset.to!string
                ~ "&index=" ~ encodeComponent(index)
                ~ "&facets=" ~ encodeComponent(encodeFacets(facets)));
        if (!response.isObject)
            throw new ModrinthException("unexpected response shape from Modrinth");

        auto results = new SearchResults();
        results.totalHits = response.integer("total_hits");
        foreach (entry; response.list("hits"))
            results.hits ~= SearchHit.fromJson(entry);
        return results;
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
        auto handle = curl_easy_init();
        if (handle is null)
            throw new ModrinthException("network error: cannot start libcurl");
        scope (exit)
            curl_easy_cleanup(handle);

        curl_slist* headers;
        scope (exit)
            if (headers !is null)
                curl_slist_free_all(headers);

        curl_easy_setopt(handle, cast(CurlOption) Opt.url, url.toStringz);
        curl_easy_setopt(handle, cast(CurlOption) Opt.userAgent, userAgent_.toStringz);
        curl_easy_setopt(handle, cast(CurlOption) Opt.writeFunction, &onBody);
        curl_easy_setopt(handle, cast(CurlOption) Opt.writeData, cast(void*)&buffer);
        curl_easy_setopt(handle, cast(CurlOption) Opt.followLocation, cast(c_long) 1);
        curl_easy_setopt(handle, cast(CurlOption) Opt.noSignal, cast(c_long) 1);
        curl_easy_setopt(handle, cast(CurlOption) Opt.connectTimeout, cast(c_long) 15);
        curl_easy_setopt(handle, cast(CurlOption) Opt.lowSpeedLimit, cast(c_long) 1);
        curl_easy_setopt(handle, cast(CurlOption) Opt.lowSpeedTime, cast(c_long) 30);
        if (postBody !is null)
        {
            headers = curl_slist_append(headers, "Content-Type: application/json");
            curl_easy_setopt(handle, cast(CurlOption) Opt.httpHeader, headers);
            curl_easy_setopt(handle, cast(CurlOption) Opt.postFieldSize, cast(c_long) postBody.length);
            curl_easy_setopt(handle, cast(CurlOption) Opt.copyPostFields, postBody.toStringz);
        }

        immutable result = cast(int) curl_easy_perform(handle);
        if (result != 0)
            throw new ModrinthException("network error: "
                    ~ fromStringz(curl_easy_strerror(result)).idup);

        c_long code;
        curl_easy_getinfo(handle, cast(CurlInfo) responseCodeInfo, &code);
        if (code / 100 != 2)
            throw new ModrinthException(describeStatus(cast(int) code), cast(int) code);

        try
            return JsonView.parse(cast(string) buffer);
        catch (JSONException e)
            throw new ModrinthException("unreadable response from Modrinth: " ~ e.msg);
    }

    private static string encodeFacets(string[][] facets)
    {
        JSONValue[] groups;
        foreach (group; facets)
            groups ~= JsonObject.stringArray(group);
        return JSONValue(groups).toString();
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
