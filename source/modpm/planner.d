module modpm.planner;

import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.array : replace;
import std.exception : enforce;
import std.parallelism : TaskPool;
import std.algorithm.comparison : min;
import std.format : format;
import std.path : extension;
import std.string : indexOf;
import std.uni : toLower;

import modpm.manifest;
import modpm.modrinth;
import modpm.resolver;
import modpm.transaction;
import modpm.transaction_builder;

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

final class PlanRequest
{
    Request[] install;
    ProjectInfo[string] projects;
    string[] remove;
    bool installSuggests;
}

final class Plan
{
    Transaction transaction;
    string[] unavailable;
    string[] alreadyInstalled;
    ProjectInfo[string] projects;
    Metadata metadata;
}

interface PlanObserver
{
    void begin(string active, string done);

    void end();

    void abort();
}

final class Planner
{
    private enum maxRounds = 12;
    private enum maxParallelRequests = 8;

    private ModrinthClient api_;
    private ScopeConfig config_;
    private Manifest manifest_;
    private Manifest base_;
    private string managedDir_;
    private PlanObserver observer_;
    private bool installSuggests_;
    private ProjectInfo[string] projects_;

    this(ModrinthClient api, ScopeConfig config, Manifest manifest, string managedDir,
        PlanObserver observer)
    {
        observer_ = observer;
        api_ = api;
        config_ = config;
        manifest_ = manifest;
        managedDir_ = managedDir;
    }

    Plan plan(PlanRequest request)
    {
        scope (failure)
            stageAbort();
        installSuggests_ = request.installSuggests;
        foreach (id, project; request.projects)
            projects_[id] = project;
        string[] problems;

        base_ = manifest_.snapshot();
        foreach (projectId; request.remove)
            base_.installed.remove(projectId);

        auto requests = request.install;
        auto metadata = new Metadata();
        auto resolution = new Resolution();
        if (requests.length)
        {
            foreach (item; requests)
                if (needsLookup(item))
                    metadata.needProject(item.projectId);
            if (metadata.hasNeeds())
            {
                stageBegin("Loading package versions", "Loaded package versions");
                fetchNeeds(metadata);
                stageEnd();
            }

            stageBegin("Resolving dependencies", "Resolved dependencies");
            resolution = resolveUntilSettled(requests, metadata);
            stageEnd();
        }

        stageBegin("Preparing the transaction", "Prepared the transaction");
        auto plan = new Plan();
        plan.metadata = metadata;
        plan.unavailable = withNames(resolution.failures);

        foreach (projectId; resolution.alreadyInstalled)
        {
            auto entry = base_.installed[projectId];
            plan.alreadyInstalled ~= entry.title ~ " " ~ entry.versionNumber;
        }

        string[] ids;
        foreach (selection; resolution.selections)
            if (selection.version_ !is null)
                ids ~= selection.projectId;
        ensureProjects(ids);

        auto builder = buildTransaction(resolution, problems);
        foreach (projectId; request.remove)
            builder.add(Operation.removal(projectId, manifest_.installed[projectId]));
        plan.transaction = builder.build(problems);

        fetchPrevious(plan.transaction, metadata);
        stageEnd();
        plan.transaction.suggestions = suggestionsFor(plan.transaction, metadata);
        plan.projects = projects_;
        return plan;
    }

    private void stageBegin(string active, string done)
    {
        if (observer_ !is null)
            observer_.begin(active, done);
    }

    private void stageEnd()
    {
        if (observer_ !is null)
            observer_.end();
    }

    private void stageAbort()
    {
        if (observer_ !is null)
            observer_.abort();
    }

    private bool needsLookup(Request request)
    {
        auto installed = request.projectId in base_.installed;
        return installed is null
            || (request.versionNumber.length && request.versionNumber != installed.versionNumber);
    }

    private Resolution resolveUntilSettled(Request[] requests, Metadata metadata)
    {
        foreach (round; 0 .. maxRounds)
        {
            auto resolution = new Resolver(config_, base_, metadata, installSuggests_).resolve(requests);
            if (!metadata.hasNeeds())
                return resolution;
            fetchNeeds(metadata);
        }
        throw new Exception("the dependency resolution didn't settle");
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

    private TransactionBuilder buildTransaction(Resolution resolution, ref string[] problems)
    {
        auto namer = new FileNamer();
        auto builder = new TransactionBuilder(manifest_, managedDir_);

        bool[string] present;
        foreach (projectId; base_.installed.keys)
            present[projectId] = true;
        foreach (selection; resolution.selections)
            present[selection.projectId] = true;

        foreach (selection; resolution.selections)
        {
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
                auto project = projects_[selection.projectId];
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
                {
                    if (dependency.projectId.length == 0)
                        continue;
                    if (dependency.type == "required")
                        to.requires[dependency.projectId] = dependency.versionId;
                    else if (dependency.type == "optional" && dependency.projectId in present
                        && dependency.projectId !in to.requires
                        && !to.suggests.canFind(dependency.projectId))
                        to.suggests ~= dependency.projectId;
                }
                to.suggests.sort();
            }
            builder.add(new Operation(selection.projectId, from, to));
        }
        return builder;
    }

    private void fetchPrevious(Transaction transaction, Metadata metadata)
    {
        string[] ids;
        foreach (operation; transaction.operations)
        {
            if (operation.from is null || (operation.to !is null && !operation.placesFile))
                continue;
            if (!metadata.knowsVersion(operation.from.versionId))
                ids ~= operation.from.versionId;
        }
        if (ids.length == 0)
            return;
        try
            metadata.addVersions(ids, api_.fetchVersionsByIds(ids));
        catch (ModrinthException)
        {
        }
    }

    private Suggestion[] suggestionsFor(Transaction transaction, Metadata metadata)
    {
        try
            return collectSuggestions(transaction, metadata);
        catch (Exception)
        {
            stageAbort();
            return null;
        }
    }

    private Suggestion[] collectSuggestions(Transaction transaction, Metadata metadata)
    {
        auto state = transaction.stateAfter(manifest_);

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

        stageBegin("Checking optional dependencies", "Checked optional dependencies");
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
        stageEnd();
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
