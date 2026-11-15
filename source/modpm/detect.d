module modpm.detect;

import std.algorithm.searching : any, canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : join;
import std.file : SpanMode, dirEntries, exists, isDir;
import std.format : format;
import std.path : baseName, buildPath, extension;
import std.uni : toLower;

import modpm.hash;
import modpm.manifest;
import modpm.modrinth;
import modpm.side;

final class DetectedFile
{
    string filename;
    string sha1;
    VersionInfo versionInfo;
    ProjectInfo project;
    string[] mismatches;

    @property bool flagged() const
    {
        return mismatches.length > 0;
    }

    @property string displayName() const
    {
        return project.displayName;
    }

    Entry toEntry() const
    {
        auto entry = new Entry();
        entry.slug = project.slug;
        entry.title = project.title;
        entry.versionId = versionInfo.id;
        entry.versionNumber = versionInfo.versionNumber;
        entry.filename = filename;
        entry.sha1 = sha1;
        entry.reason = "user";
        foreach (dependency; versionInfo.dependencies)
            if (dependency.type == "required" && dependency.projectId.length)
                entry.requires[dependency.projectId] = dependency.versionId;
        return entry;
    }
}

final class DetectionResult
{
    DetectedFile[] detected;
    string[] ignored;
    string[] undetected;
    string[] problems;

    @property bool hasFlagged() const
    {
        foreach (file; detected)
            if (file.flagged)
                return true;
        return false;
    }

    string[] mismatchKinds() const
    {
        string[] kinds;
        foreach (candidate; ["loader", "game version", "environment"])
            foreach (file; detected)
                if (file.mismatches.canFind(candidate))
                {
                    kinds ~= candidate;
                    break;
                }
        return kinds;
    }

    @property bool adoptable() const
    {
        return problems.length == 0;
    }
}

final class Detector
{
    private ModrinthClient api_;
    private FileHasher hasher_;

    this(ModrinthClient api, FileHasher hasher)
    {
        api_ = api;
        hasher_ = hasher;
    }

    bool hasFiles(string directory, string suffix)
    {
        return listFiles(directory, suffix).length > 0;
    }

    DetectionResult detect(string directory, ScopeConfig config, string suffix)
    {
        auto result = new DetectionResult();
        auto filenames = listFiles(directory, suffix);
        if (filenames.length == 0)
            return result;

        string[] hashes;
        string[string] hashOf;
        foreach (name; filenames)
        {
            auto hash = hasher_.sha1(buildPath(directory, name));
            hashOf[name] = hash;
            hashes ~= hash;
        }

        auto versions = api_.versionsFromHashes(hashes);

        bool[string] wanted;
        foreach (name; filenames)
        {
            auto found = hashOf[name] in versions;
            if (found is null || !found.isPrimary(hashOf[name]))
                continue;
            wanted[found.projectId] = true;
            foreach (dependency; found.dependencies)
                if (dependency.type == "required" && dependency.projectId.length)
                    wanted[dependency.projectId] = true;
        }
        auto projectIds = wanted.keys;
        projectIds.sort();
        auto projects = api_.fetchProjects(projectIds);

        auto policy = new EnvironmentPolicy(config.side);
        string[][string] filesByProject;
        string[string] installedVersion;

        foreach (name; filenames)
        {
            auto found = hashOf[name] in versions;
            if (found is null)
            {
                result.undetected ~= name;
                continue;
            }
            if (!found.isPrimary(hashOf[name]))
            {
                result.ignored ~= name;
                continue;
            }

            auto file = new DetectedFile();
            file.filename = name;
            file.sha1 = hashOf[name];
            file.versionInfo = *found;
            file.project = lookupProject(projects, found.projectId);
            file.mismatches = mismatchesOf(file.versionInfo, config, policy);
            result.detected ~= file;

            filesByProject[found.projectId] ~= name;
            installedVersion[found.projectId] = found.id;
        }

        findProblems(result, projects, filesByProject, installedVersion);
        return result;
    }

    private static string[] listFiles(string directory, string suffix)
    {
        string[] names;
        if (!exists(directory) || !isDir(directory))
            return names;
        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            immutable name = baseName(entry.name);
            if (name.startsWith("."))
                continue;
            if (entry.isFile && extension(name).toLower == suffix)
                names ~= name;
        }
        names.sort();
        return names;
    }

    private static string[] mismatchesOf(VersionInfo version_, ScopeConfig config,
        EnvironmentPolicy policy)
    {
        string[] result;
        if (!config.loaders.any!(loader => version_.loaders.canFind(loader)))
            result ~= "loader";
        if (!version_.gameVersions.canFind(config.gameVersion))
            result ~= "game version";
        if (!policy.accepts(version_.environment))
            result ~= "environment";
        return result;
    }

    private static void findProblems(DetectionResult result, ProjectInfo[string] projects,
        string[][string] filesByProject, string[string] installedVersion)
    {
        bool[string] reported;
        foreach (file; result.detected)
        {
            immutable projectId = file.versionInfo.projectId;
            if (filesByProject[projectId].length > 1 && projectId !in reported)
            {
                reported[projectId] = true;
                result.problems ~= format("%s is matched by more than one file: %s",
                    file.displayName, filesByProject[projectId].join(", "));
            }
        }

        foreach (file; result.detected)
        {
            foreach (dependency; file.versionInfo.dependencies)
            {
                if (dependency.type != "required" || dependency.projectId.length == 0)
                    continue;

                auto installed = dependency.projectId in installedVersion;
                if (installed is null)
                    result.problems ~= format("%s requires %s, which is not in the folder",
                        file.displayName, lookupProject(projects, dependency.projectId).title);
                else if (dependency.versionId.length && *installed != dependency.versionId)
                    result.problems ~= format(
                        "%s requires a specific version of %s that is not the one in the folder",
                        file.displayName, lookupProject(projects, dependency.projectId).title);
            }
        }
    }

    private static ProjectInfo lookupProject(ProjectInfo[string] projects, string id)
    {
        if (auto project = id in projects)
            return *project;
        return new ProjectInfo(id, id, id);
    }
}
