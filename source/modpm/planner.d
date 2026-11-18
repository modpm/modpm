module modpm.planner;

import std.algorithm.sorting : sort;
import std.array : join, replace;
import std.exception : enforce;
import std.file : exists;
import std.parallelism : TaskPool;
import std.algorithm.comparison : min;
import std.format : format;
import std.path : buildPath, extension;
import std.string : indexOf, lastIndexOf;
import std.uni : toLower;

import modpm.manifest;
import modpm.modrinth;
import modpm.resolver;
import modpm.transaction;

class PlanProblems : Exception
{
    string[] problems;

    this(string[] problems, string file = __FILE__, size_t line = __LINE__)
    {
        super(problems.join("\n"), file, line);
        this.problems = problems;
    }
}

final class FileNamer
{
    string nameFor(ProjectInfo project, VersionInfo version_)
    {
        enforce(version_.primaryFile !is null,
            format("%s %s has no downloadable file", project.displayName, version_.versionNumber));
        immutable ext = extension(version_.primaryFile.filename).toLower;
        enforce(validExtension(ext),
            format("%s %s has a file with an unusable extension", project.displayName,
                version_.versionNumber));
        return clean(project.slug.length ? project.slug : project.id) ~ "-"
            ~ clean(version_.versionNumber) ~ ".modpm" ~ ext;
    }

    private static string clean(string text)
    {
        char[] result;
        foreach (c; text)
        {
            immutable allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '+' || c == '-';
            result ~= allowed ? c : '_';
            if (result.length == 60)
                break;
        }
        if (result.length && result[0] == '.')
            result[0] = '_';
        return result.idup;
    }

    private static bool validExtension(string ext)
    {
        if (ext.length < 2 || ext.length > 11 || ext[0] != '.')
            return false;
        foreach (c; ext[1 .. $])
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')))
                return false;
        return true;
    }
}

private final class OptionalCandidate
{
    Operation host;
    string projectId;
    string pinnedVersionId;

    this(Operation host, string projectId, string pinnedVersionId)
    {
        this.host = host;
        this.projectId = projectId;
        this.pinnedVersionId = pinnedVersionId;
    }
}

final class Plan
{
    Transaction transaction;
    string[] skipped;
    string[] alreadyInstalled;
    ProjectInfo[string] projects;
    Metadata metadata;
}

final class Planner
{
    private enum maxRounds = 12;
    private enum maxParallelRequests = 8;

    private ModrinthClient api_;
    private ScopeConfig config_;
    private Manifest manifest_;
    private string managedDir_;
    private ProjectInfo[string] projects_;

    this(ModrinthClient api, ScopeConfig config, Manifest manifest, string managedDir)
    {
        api_ = api;
        config_ = config;
        manifest_ = manifest;
        managedDir_ = managedDir;
    }

    Plan plan(string[] specs, bool skipUnavailable)
    {
        string[] problems;
        auto requests = requestsFor(specs, problems);

        auto metadata = new Metadata();
        auto resolution = new Resolution();
        if (requests.length)
        {
            foreach (request; requests)
                metadata.needProject(request.projectId);
            fetchNeeds(metadata);
            resolution = resolveUntilSettled(requests, metadata);
        }

        auto plan = new Plan();
        plan.metadata = metadata;
        auto failures = withNames(resolution.failures);
        if (skipUnavailable)
            plan.skipped = failures;
        else
            problems ~= failures;

        foreach (projectId; resolution.alreadyInstalled)
        {
            auto entry = manifest_.installed[projectId];
            plan.alreadyInstalled ~= entry.title ~ " " ~ entry.versionNumber;
        }

        string[] ids;
        foreach (selection; resolution.selections)
            ids ~= selection.projectId;
        ensureProjects(ids);

        plan.transaction = buildTransaction(resolution, problems);
        checkFileNames(plan.transaction, problems);
        if (problems.length)
            throw new PlanProblems(problems);

        fetchPrevious(plan.transaction, metadata);
        plan.transaction.suggestions = suggestionsFor(plan.transaction, metadata);
        plan.projects = projects_;
        return plan;
    }

    private Resolution resolveUntilSettled(Request[] requests, Metadata metadata)
    {
        foreach (round; 0 .. maxRounds)
        {
            auto resolution = new Resolver(config_, manifest_, metadata).resolve(requests);
            if (!metadata.hasNeeds())
                return resolution;
            fetchNeeds(metadata);
        }
        throw new Exception("the dependency resolution didn't settle");
    }

    private Request[] requestsFor(string[] specs, ref string[] problems)
    {
        bool[string] wanted;
        foreach (spec; specs)
        {
            wanted[spec] = true;
            immutable at = spec.lastIndexOf('@');
            if (at > 0)
                wanted[spec[0 .. at]] = true;
        }

        ProjectInfo[string] byId;
        ProjectInfo[string] bySlug;
        foreach (id, project; api_.fetchProjects(wanted.keys))
        {
            projects_[id] = project;
            byId[id] = project;
            bySlug[project.slug.toLower] = project;
        }

        ProjectInfo lookup(string key)
        {
            if (auto project = key in byId)
                return *project;
            if (auto project = key.toLower in bySlug)
                return *project;
            return null;
        }

        Request[] requests;
        bool[string] seen;
        foreach (spec; specs)
        {
            ProjectInfo project;
            string versionNumber;
            immutable at = spec.lastIndexOf('@');
            if (at > 0)
            {
                project = lookup(spec[0 .. at]);
                versionNumber = spec[at + 1 .. $];
            }
            if (project is null)
            {
                project = lookup(spec);
                versionNumber = "";
            }
            if (project is null)
            {
                problems ~= format("no such project: %s", spec);
                continue;
            }
            if (project.projectType == "modpack")
            {
                problems ~= format("%s is a modpack, which modpm doesn't support", project.displayName);
                continue;
            }
            if (project.id in seen)
            {
                problems ~= format("%s is listed twice", project.displayName);
                continue;
            }
            seen[project.id] = true;
            requests ~= new Request(project.id, versionNumber);
        }
        return requests;
    }

    private void fetchNeeds(Metadata metadata)
    {
        auto projectIds = metadata.neededProjects.keys;
        projectIds.sort();

        auto lists = new VersionInfo[][](projectIds.length);
        if (projectIds.length)
        {
            auto pool = new TaskPool(min(maxParallelRequests, projectIds.length));
            scope (exit)
                pool.finish(true);

            foreach (i, projectId; pool.parallel(projectIds, 1))
            {
                try
                    lists[i] = api_.fetchVersions(projectId, config_.loaders, config_.gameVersion);
                catch (ModrinthException e)
                {
                    if (e.status != 404)
                        throw e;
                }
            }
        }
        foreach (i, projectId; projectIds)
            metadata.addCandidates(projectId, lists[i]);

        auto versionIds = metadata.neededVersions.keys;
        versionIds.sort();
        if (versionIds.length)
            metadata.addVersions(versionIds, api_.fetchVersionsByIds(versionIds));
        metadata.clearNeeds();
    }

    private Transaction buildTransaction(Resolution resolution, ref string[] problems)
    {
        auto namer = new FileNamer();
        auto transaction = new Transaction();
        transaction.id = manifest_.head + 1;

        foreach (selection; resolution.selections)
        {
            auto project = projects_[selection.projectId];
            Entry from;
            if (selection.installed !is null)
            {
                from = selection.installed.duplicate();
                from.frozen = false;
            }

            Entry to;
            if (selection.version_ is null)
            {
                to = from.duplicate();
                to.reason = "user";
            }
            else
            {
                auto chosen = selection.version_;
                to = new Entry();
                to.slug = project.slug;
                to.title = project.title;
                to.versionId = chosen.id;
                to.versionNumber = chosen.versionNumber;
                try
                    to.filename = namer.nameFor(project, chosen);
                catch (Exception e)
                {
                    problems ~= e.msg;
                    continue;
                }
                to.sha1 = chosen.primaryFile.sha1;
                to.reason = selection.wanted || (from !is null && from.reason == "user")
                    ? "user" : "dependency";
                foreach (dependency; chosen.dependencies)
                    if (dependency.type == "required" && dependency.projectId.length)
                        to.requires[dependency.projectId] = dependency.versionId;
            }
            transaction.operations ~= new Operation(selection.projectId, from, to);
        }
        return transaction;
    }

    private void checkFileNames(Transaction transaction, ref string[] problems)
    {
        bool[string] changed;
        bool[string] freed;
        foreach (operation; transaction.operations)
        {
            changed[operation.projectId] = true;
            if (operation.removesOldFile)
                freed[operation.from.filename.toLower] = true;
        }

        string[string] taken;
        foreach (projectId, entry; manifest_.installed)
            if (projectId !in changed)
                taken[entry.filename.toLower] = entry.title;

        foreach (operation; transaction.operations)
        {
            if (!operation.placesFile)
                continue;
            if (operation.from !is null && operation.from.filename == operation.to.filename)
                continue;

            immutable key = operation.to.filename.toLower;
            if (auto owner = key in taken)
            {
                problems ~= format("%s would use the file name %s, which %s already has",
                    operation.to.title, operation.to.filename, *owner);
                continue;
            }
            taken[key] = operation.to.title;

            if (key !in freed && exists(buildPath(managedDir_, operation.to.filename)))
                problems ~= format("%s already exists in the directory and isn't managed by modpm",
                    operation.to.filename);
        }
    }

    private void fetchPrevious(Transaction transaction, Metadata metadata)
    {
        string[] ids;
        foreach (operation; transaction.operations)
            if (operation.from !is null && !metadata.knowsVersion(operation.from.versionId))
                ids ~= operation.from.versionId;
        if (ids.length)
            metadata.addVersions(ids, api_.fetchVersionsByIds(ids));
    }

    private Suggestion[] suggestionsFor(Transaction transaction, Metadata metadata)
    {
        try
            return collectSuggestions(transaction, metadata);
        catch (Exception)
            return null;
    }

    private Suggestion[] collectSuggestions(Transaction transaction, Metadata metadata)
    {
        auto state = stateAfter(transaction);

        OptionalCandidate[] found;
        foreach (operation; transaction.operations)
        {
            if (!operation.placesFile || !metadata.knowsVersion(operation.to.versionId))
                continue;
            auto version_ = metadata.version_(operation.to.versionId);
            if (version_ is null)
                continue;

            bool[string] seen;
            foreach (dependency; version_.dependencies)
            {
                if (dependency.type != "optional" || dependency.projectId.length == 0)
                    continue;
                if (dependency.projectId in state.installed || dependency.projectId in seen)
                    continue;
                seen[dependency.projectId] = true;
                found ~= new OptionalCandidate(operation, dependency.projectId, dependency.versionId);
            }
        }
        if (found.length == 0)
            return null;

        foreach (candidate; found)
        {
            if (!metadata.knowsProject(candidate.projectId))
                metadata.needProject(candidate.projectId);
            if (candidate.pinnedVersionId.length && !metadata.knowsVersion(candidate.pinnedVersionId))
                metadata.needVersion(candidate.pinnedVersionId);
        }
        fetchNeeds(metadata);

        OptionalCandidate[] usable;
        string[] versionNumbers;
        foreach (candidate; found)
        {
            string versionNumber;
            if (candidate.pinnedVersionId.length)
            {
                auto pinned = metadata.version_(candidate.pinnedVersionId);
                if (pinned is null)
                    continue;
                versionNumber = pinned.versionNumber;
            }
            if (!suitable(new Request(candidate.projectId, versionNumber), state, metadata))
                continue;
            usable ~= candidate;
            versionNumbers ~= versionNumber;
        }

        string[] ids;
        foreach (candidate; usable)
            ids ~= candidate.projectId;
        ensureProjects(ids);

        Suggestion[string] byHost;
        Suggestion[] ordered;
        foreach (i, candidate; usable)
        {
            auto suggestion = byHost.get(candidate.host.projectId, null);
            if (suggestion is null)
            {
                suggestion = new Suggestion();
                suggestion.title = candidate.host.to.title;
                suggestion.versionNumber = candidate.host.to.versionNumber;
                byHost[candidate.host.projectId] = suggestion;
                ordered ~= suggestion;
            }

            auto project = projects_[candidate.projectId];
            auto item = new OptionalPackage();
            item.slug = project.slug;
            item.title = project.title;
            item.versionNumber = versionNumbers[i];
            suggestion.optional ~= item;
        }
        return ordered;
    }

    private bool suitable(Request request, Manifest state, Metadata metadata)
    {
        foreach (round; 0 .. maxRounds)
        {
            auto resolution = new Resolver(config_, state, metadata).resolve([request]);
            if (!metadata.hasNeeds())
                return resolution.failures.length == 0;
            fetchNeeds(metadata);
        }
        return false;
    }

    private Manifest stateAfter(Transaction transaction)
    {
        auto state = new Manifest(manifest_.config);
        state.head = manifest_.head;
        foreach (projectId, entry; manifest_.installed)
            state.installed[projectId] = entry;
        foreach (operation; transaction.operations)
        {
            if (operation.to is null)
                state.installed.remove(operation.projectId);
            else
                state.installed[operation.projectId] = operation.to;
        }
        return state;
    }

    private void ensureProjects(string[] ids)
    {
        bool[string] missing;
        foreach (id; ids)
            if (id !in projects_)
                missing[id] = true;
        if (missing.length == 0)
            return;
        foreach (id, project; api_.fetchProjects(missing.keys))
            projects_[id] = project;
    }

    private string[] withNames(string[] texts)
    {
        string[] ids;
        foreach (text; texts)
            ids ~= tokensIn(text);
        ensureProjects(ids);

        string[] result;
        foreach (text; texts)
        {
            foreach (id; tokensIn(text))
                if (auto project = id in projects_)
                    text = text.replace("{" ~ id ~ "}", project.displayName);
            result ~= text;
        }
        return result;
    }

    private static string[] tokensIn(string text)
    {
        string[] ids;
        size_t from = 0;
        while (true)
        {
            immutable open = text.indexOf('{', from);
            if (open < 0)
                break;
            immutable close = text.indexOf('}', open);
            if (close < 0)
                break;
            ids ~= text[open + 1 .. close];
            from = close + 1;
        }
        return ids;
    }
}
