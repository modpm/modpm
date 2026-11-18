module modpm.resolver;

import std.algorithm.searching : any, canFind;
import std.algorithm.sorting : sort;
import std.array : join;
import std.format : format;

import modpm.manifest;
import modpm.modrinth;
import modpm.side;

final class Request
{
    string projectId;
    string versionNumber;

    this(string projectId, string versionNumber = "")
    {
        this.projectId = projectId;
        this.versionNumber = versionNumber;
    }
}

final class Metadata
{
    bool[string] neededProjects;
    bool[string] neededVersions;

    private VersionInfo[][string] candidates_;
    private VersionInfo[string] versions_;

    bool knowsProject(string projectId) const
    {
        return (projectId in candidates_) !is null;
    }

    bool knowsVersion(string versionId) const
    {
        return (versionId in versions_) !is null;
    }

    VersionInfo[] candidates(string projectId)
    {
        return candidates_[projectId];
    }

    VersionInfo version_(string versionId)
    {
        return versions_[versionId];
    }

    void needProject(string projectId)
    {
        neededProjects[projectId] = true;
    }

    void needVersion(string versionId)
    {
        neededVersions[versionId] = true;
    }

    bool hasNeeds() const
    {
        return neededProjects.length > 0 || neededVersions.length > 0;
    }

    void clearNeeds()
    {
        neededProjects = null;
        neededVersions = null;
    }

    void addCandidates(string projectId, VersionInfo[] list)
    {
        candidates_[projectId] = list;
        foreach (v; list)
            versions_[v.id] = v;
    }

    void addVersions(string[] requested, VersionInfo[string] fetched)
    {
        foreach (id; requested)
            versions_[id] = null;
        foreach (id, v; fetched)
            versions_[id] = v;
    }
}

final class Selection
{
    string projectId;
    VersionInfo version_;
    Entry installed;
    bool wanted;

    this(string projectId, VersionInfo version_, Entry installed, bool wanted)
    {
        this.projectId = projectId;
        this.version_ = version_;
        this.installed = installed;
        this.wanted = wanted;
    }
}

final class Resolution
{
    Selection[] selections;
    string[] failures;
    string[] alreadyInstalled;
}

private final class Choice
{
    VersionInfo version_;
    Entry installed;
    bool wanted;
    string requiredBy;
    string requiredByVersion;
    bool pinned;

    this(VersionInfo version_, Entry installed, bool wanted, string requiredBy = "",
        string requiredByVersion = "", bool pinned = false)
    {
        this.version_ = version_;
        this.installed = installed;
        this.wanted = wanted;
        this.requiredBy = requiredBy;
        this.requiredByVersion = requiredByVersion;
        this.pinned = pinned;
    }
}

private final class Need
{
    string projectId;
    string pinnedVersionId;
    string requiredBy;
    string requiredByVersion;
    bool root;
    string versionNumber;

    this(string projectId, string pinnedVersionId, string requiredBy, string requiredByVersion)
    {
        this.projectId = projectId;
        this.pinnedVersionId = pinnedVersionId;
        this.requiredBy = requiredBy;
        this.requiredByVersion = requiredByVersion;
    }

    static Need rootOf(Request request)
    {
        auto need = new Need(request.projectId, "", "", "");
        need.root = true;
        need.versionNumber = request.versionNumber;
        return need;
    }
}

final class Resolver
{
    private enum maxTries = 100000;

    private ScopeConfig config_;
    private Manifest manifest_;
    private Metadata metadata_;
    private EnvironmentPolicy policy_;
    private Choice[string] assigned_;
    private size_t tries_;
    private bool gaveUp_;

    this(ScopeConfig config, Manifest manifest, Metadata metadata)
    {
        config_ = config;
        manifest_ = manifest;
        metadata_ = metadata;
        policy_ = new EnvironmentPolicy(config.side);
    }

    Resolution resolve(Request[] requests)
    {
        auto resolution = new Resolution();
        Choice[string] base;
        Request[] solvable;

        foreach (request; requests)
        {
            auto installed = installedOf(request.projectId);
            if (installed !is null
                && (request.versionNumber.length == 0 || request.versionNumber == installed.versionNumber))
            {
                if (installed.reason == "user")
                    resolution.alreadyInstalled ~= request.projectId;
                else
                    base[request.projectId] = new Choice(null, installed, true);
                continue;
            }
            if (installed !is null && installed.frozen)
            {
                addUnique(resolution.failures,
                    format("%s is frozen at %s", name_(request.projectId), installed.versionNumber));
                continue;
            }
            solvable ~= request;
        }

        Request[] accepted;
        auto state = base.dup;
        foreach (request; solvable)
        {
            auto attempt = accepted ~ request;
            assigned_ = base.dup;
            string failure;
            if (solveRoots(attempt, failure))
            {
                accepted = attempt;
                state = assigned_.dup;
                continue;
            }

            assigned_ = state.dup;
            if (gaveUp_)
                addUnique(resolution.failures, format(
                    "Couldn't find versions of %s that work with the other packages (too many "
                    ~ "combinations to try). Try installing it on its own.", name_(request.projectId)));
            else
                foreach (message; diagnoseRoot(request, failure))
                    addUnique(resolution.failures, message);
        }

        assigned_ = state;
        auto projectIds = assigned_.keys;
        projectIds.sort();
        foreach (projectId; projectIds)
        {
            auto choice = assigned_[projectId];
            if (choice.version_ is null && !choice.wanted)
                continue;
            resolution.selections ~= new Selection(projectId, choice.version_,
                choice.installed, choice.wanted);
        }
        return resolution;
    }

    private bool solveRoots(Request[] roots, ref string failure)
    {
        tries_ = 0;
        gaveUp_ = false;
        Need[] pending;
        foreach (root; roots)
            pending ~= Need.rootOf(root);
        bool[string] conflict;
        return solve(pending, failure, conflict);
    }

    private bool solve(Need[] pending, ref string failure, ref bool[string] conflict)
    {
        if (pending.length == 0)
            return true;
        if (++tries_ > maxTries)
        {
            gaveUp_ = true;
            return false;
        }

        auto need = pending[0];
        auto rest = pending[1 .. $];
        if (need.root)
            return solveRoot(need, rest, failure, conflict);

        if (need.pinnedVersionId.length == 0)
        {
            foreach (other; rest)
            {
                if (!other.root && other.projectId == need.projectId && other.pinnedVersionId.length)
                {
                    need = new Need(need.projectId, other.pinnedVersionId,
                        other.requiredBy, other.requiredByVersion);
                    break;
                }
            }
        }
        immutable pinned = need.pinnedVersionId.length > 0;

        if (auto chosen = need.projectId in assigned_)
        {
            if (pinned && versionIdOf(*chosen) != need.pinnedVersionId)
            {
                failure = pinMismatch(need, *chosen);
                conflict = involve(need.projectId, need.requiredBy);
                return false;
            }
            return solve(rest, failure, conflict);
        }

        auto installed = installedOf(need.projectId);
        if (installed !is null && (!pinned || need.pinnedVersionId == installed.versionId))
        {
            assigned_[need.projectId] = new Choice(null, installed, false,
                need.requiredBy, need.requiredByVersion, pinned);
            if (solve(rest, failure, conflict))
                return true;
            assigned_.remove(need.projectId);
            if (need.projectId in conflict)
            {
                conflict.remove(need.projectId);
                if (need.requiredBy.length)
                    conflict[need.requiredBy] = true;
            }
            return false;
        }
        if (installed !is null && installed.frozen)
        {
            failure = frozenMessage(need, installed);
            conflict = involve(need.requiredBy);
            return false;
        }

        auto candidates = dependencyCandidates(need, failure);
        if (candidates.length == 0)
        {
            conflict = involve(need.requiredBy);
            return false;
        }

        bool[string] accumulated;
        foreach (candidate; candidates)
        {
            bool[string] involved;
            immutable message = conflictOf(candidate, involved);
            if (message.length)
            {
                failure = message;
                merge(accumulated, involved, need.projectId);
                continue;
            }

            assigned_[need.projectId] = new Choice(candidate, installed, false,
                need.requiredBy, need.requiredByVersion, pinned);
            bool[string] inner;
            if (solve(rest ~ requiredNeeds(candidate), failure, inner))
                return true;
            assigned_.remove(need.projectId);
            if (gaveUp_)
                return false;
            if (need.projectId !in inner)
            {
                conflict = inner;
                return false;
            }
            merge(accumulated, inner, need.projectId);
        }

        if (need.requiredBy.length)
            accumulated[need.requiredBy] = true;
        conflict = accumulated;
        return false;
    }

    private bool solveRoot(Need need, Need[] rest, ref string failure, ref bool[string] conflict)
    {
        auto installed = installedOf(need.projectId);
        bool[string] accumulated;
        foreach (candidate; rootCandidates(need.projectId, need.versionNumber, failure))
        {
            bool[string] involved;
            immutable message = conflictOf(candidate, involved);
            if (message.length)
            {
                failure = message;
                merge(accumulated, involved, need.projectId);
                continue;
            }

            assigned_[need.projectId] = new Choice(candidate, installed, true);
            bool[string] inner;
            if (solve(rest ~ requiredNeeds(candidate), failure, inner))
                return true;
            assigned_.remove(need.projectId);
            if (gaveUp_)
                return false;
            if (need.projectId !in inner)
            {
                conflict = inner;
                return false;
            }
            merge(accumulated, inner, need.projectId);
        }

        conflict = accumulated;
        return false;
    }

    private string[] diagnoseRoot(Request request, string solveFailure)
    {
        auto installed = installedOf(request.projectId);
        string failure;
        VersionInfo viable;
        foreach (candidate; rootCandidates(request.projectId, request.versionNumber, failure))
        {
            immutable conflict = conflictOf(candidate);
            if (conflict.length)
            {
                failure = conflict;
                continue;
            }
            viable = candidate;
            break;
        }

        if (viable is null)
            return [failure];
        auto details = diagnose(viable, installed);
        if (details.length)
            return details;
        return [solveFailure.length ? solveFailure : failure];
    }

    private string[] diagnose(VersionInfo root, Entry rootInstalled)
    {
        string[] messages;
        auto saved = assigned_.dup;
        scope (exit)
            assigned_ = saved;
        assigned_[root.projectId] = new Choice(root, rootInstalled, true);

        VersionInfo[] queue = [root];
        for (size_t i = 0; i < queue.length; i++)
        {
            foreach (need; requiredNeeds(queue[i]))
            {
                immutable pinned = need.pinnedVersionId.length > 0;
                if (auto chosen = need.projectId in assigned_)
                {
                    if (pinned && versionIdOf(*chosen) != need.pinnedVersionId)
                    {
                        auto switched = (*chosen).version_ !is null && !(*chosen).pinned
                            && !(*chosen).wanted ? pinnedCandidate(need) : null;
                        if (switched !is null && conflictOf(switched).length == 0)
                        {
                            assigned_[need.projectId] = new Choice(switched, (*chosen).installed,
                                false, need.requiredBy, need.requiredByVersion, true);
                            queue ~= switched;
                        }
                        else
                            addUnique(messages, pinMismatch(need, *chosen));
                    }
                    continue;
                }

                auto installed = installedOf(need.projectId);
                if (installed !is null && (!pinned || need.pinnedVersionId == installed.versionId))
                {
                    assigned_[need.projectId] = new Choice(null, installed, false,
                        need.requiredBy, need.requiredByVersion, pinned);
                    continue;
                }
                if (installed !is null && installed.frozen)
                {
                    addUnique(messages, frozenMessage(need, installed));
                    continue;
                }

                string failure;
                VersionInfo picked;
                foreach (candidate; dependencyCandidates(need, failure))
                {
                    immutable conflict = conflictOf(candidate);
                    if (conflict.length)
                    {
                        failure = conflict;
                        continue;
                    }
                    picked = candidate;
                    break;
                }
                if (picked is null)
                {
                    addUnique(messages, failure);
                    continue;
                }

                assigned_[need.projectId] = new Choice(picked, installed, false,
                    need.requiredBy, need.requiredByVersion, pinned);
                queue ~= picked;
            }
        }
        return messages;
    }

    private VersionInfo pinnedCandidate(Need need)
    {
        if (!metadata_.knowsVersion(need.pinnedVersionId))
        {
            metadata_.needVersion(need.pinnedVersionId);
            return null;
        }
        auto pinned = metadata_.version_(need.pinnedVersionId);
        return pinned !is null && scopeCompatible(pinned) ? pinned : null;
    }

    private VersionInfo[] rootCandidates(string projectId, string versionNumber, ref string failure)
    {
        VersionInfo[] result;
        foreach (v; candidatesOf(projectId))
        {
            if (!policy_.accepts(v.environment))
                continue;
            if (versionNumber.length ? v.versionNumber == versionNumber : channelAllowed(v))
                result ~= v;
        }

        if (result.length == 0)
            failure = versionNumber.length
                ? format("%s has no version %s for %s", name_(projectId), versionNumber, target())
                : format("%s has no version compatible with %s", name_(projectId), target());
        return result;
    }

    private VersionInfo[] dependencyCandidates(Need need, ref string failure)
    {
        VersionInfo[] result;
        if (need.pinnedVersionId.length)
        {
            if (!metadata_.knowsVersion(need.pinnedVersionId))
            {
                metadata_.needVersion(need.pinnedVersionId);
                return [placeholder(need.projectId, need.pinnedVersionId)];
            }
            auto pinned = metadata_.version_(need.pinnedVersionId);
            if (pinned !is null && scopeCompatible(pinned))
                result ~= pinned;
        }
        else
        {
            foreach (v; candidatesOf(need.projectId))
                if (channelAllowed(v) && policy_.accepts(v.environment))
                    result ~= v;
        }

        if (result.length == 0)
            failure = need.pinnedVersionId.length
                ? format("%s requires %s, which isn't available for %s", needer(need),
                    describePin(need), target()) : format("%s requires %s, which has no version compatible with %s",
                    needer(need), name_(need.projectId), target());
        return result;
    }

    private VersionInfo[] candidatesOf(string projectId)
    {
        if (metadata_.knowsProject(projectId))
            return metadata_.candidates(projectId);
        metadata_.needProject(projectId);
        return [placeholder(projectId, "?")];
    }

    private VersionInfo placeholder(string projectId, string versionId)
    {
        auto v = new VersionInfo();
        v.id = versionId;
        v.projectId = projectId;
        v.versionNumber = "?";
        v.versionType = config_.channels[0];
        return v;
    }

    private string conflictOf(VersionInfo candidate)
    {
        bool[string] ignored;
        return conflictOf(candidate, ignored);
    }

    private string conflictOf(VersionInfo candidate, ref bool[string] involved)
    {
        foreach (dependency; candidate.dependencies)
        {
            if (dependency.type != "incompatible" || dependency.projectId.length == 0)
                continue;
            immutable other = currentVersionId(dependency.projectId);
            if (other.length && (dependency.versionId.length == 0 || dependency.versionId == other))
            {
                if (dependency.projectId in assigned_)
                    involved[dependency.projectId] = true;
                return format("%s %s conflicts with %s %s", name_(candidate.projectId),
                    candidate.versionNumber, name_(dependency.projectId),
                    currentVersionNumber(dependency.projectId));
            }
        }

        foreach (projectId, choice; assigned_)
        {
            if (choice.version_ is null)
                continue;
            foreach (dependency; choice.version_.dependencies)
            {
                if (dependency.type == "incompatible" && dependency.projectId == candidate.projectId
                    && (dependency.versionId.length == 0 || dependency.versionId == candidate.id))
                {
                    involved[projectId] = true;
                    return format("%s %s conflicts with %s %s", name_(projectId),
                        choice.version_.versionNumber, name_(candidate.projectId),
                        candidate.versionNumber);
                }
            }
        }

        foreach (projectId, entry; manifest_.installed)
        {
            if (projectId in assigned_)
                continue;
            auto pin = candidate.projectId in entry.requires;
            if (pin !is null && (*pin).length && *pin != candidate.id)
                return format("%s %s needs %s, but %s would be selected", name_(projectId),
                    entry.versionNumber, named(candidate.projectId, versionNumberOf(*pin)),
                    named(candidate.projectId, candidate.versionNumber));
        }
        return "";
    }

    private Need[] requiredNeeds(VersionInfo v)
    {
        Need[] result;
        foreach (dependency; v.dependencies)
            if (dependency.type == "required" && dependency.projectId.length)
                result ~= new Need(dependency.projectId, dependency.versionId,
                    v.projectId, v.versionNumber);
        return result;
    }

    private string pinMismatch(Need need, Choice chosen)
    {
        return format("%s needs %s, but %s is selected%s", needer(need), describePin(need),
            named(need.projectId, numberOf(chosen)), noteOf(chosen));
    }

    private string frozenMessage(Need need, Entry installed)
    {
        return format("%s needs %s, but %s is frozen at %s", needer(need), describePin(need),
            name_(need.projectId), installed.versionNumber);
    }

    private static string needer(Need need)
    {
        return need.requiredByVersion.length
            ? name_(need.requiredBy) ~ " " ~ need.requiredByVersion : name_(need.requiredBy);
    }

    private string describePin(Need need)
    {
        return named(need.projectId, versionNumberOf(need.pinnedVersionId));
    }

    private string versionNumberOf(string versionId)
    {
        if (metadata_.knowsVersion(versionId))
        {
            auto v = metadata_.version_(versionId);
            return v is null ? "" : v.versionNumber;
        }
        metadata_.needVersion(versionId);
        return "";
    }

    private static string named(string projectId, string versionNumber)
    {
        return versionNumber.length ? name_(projectId) ~ " " ~ versionNumber
            : name_(projectId) ~ " (a specific version)";
    }

    private static string numberOf(Choice choice)
    {
        return choice.version_ !is null ? choice.version_.versionNumber
            : choice.installed.versionNumber;
    }

    private static string noteOf(Choice choice)
    {
        if (choice.wanted && choice.requiredBy.length == 0)
            return " (you requested it)";
        if (choice.version_ is null)
            return " (already installed)";
        if (choice.requiredBy.length == 0)
            return "";
        immutable by = name_(choice.requiredBy) ~ " " ~ choice.requiredByVersion;
        return choice.pinned ? format(" (pinned by %s)", by)
            : format(" (selected for %s, which accepts any version)", by);
    }

    private string target()
    {
        return format("%s %s", config_.loaders.join("/"), config_.gameVersion);
    }

    private bool channelAllowed(VersionInfo v)
    {
        return config_.channels.canFind(v.versionType);
    }

    private bool scopeCompatible(VersionInfo v)
    {
        return config_.loaders.any!(loader => v.loaders.canFind(loader))
            && v.gameVersions.canFind(config_.gameVersion) && policy_.accepts(v.environment);
    }

    private Entry installedOf(string projectId)
    {
        if (auto entry = projectId in manifest_.installed)
            return *entry;
        return null;
    }

    private string currentVersionId(string projectId)
    {
        if (auto chosen = projectId in assigned_)
            return versionIdOf(*chosen);
        auto installed = installedOf(projectId);
        return installed is null ? "" : installed.versionId;
    }

    private string currentVersionNumber(string projectId)
    {
        if (auto chosen = projectId in assigned_)
            return numberOf(*chosen);
        auto installed = installedOf(projectId);
        return installed is null ? "" : installed.versionNumber;
    }

    private static string versionIdOf(Choice choice)
    {
        return choice.version_ !is null ? choice.version_.id : choice.installed.versionId;
    }

    private static bool[string] involve(string[] projectIds...)
    {
        bool[string] result;
        foreach (projectId; projectIds)
            if (projectId.length)
                result[projectId] = true;
        return result;
    }

    private static void merge(ref bool[string] into, bool[string] from, string except)
    {
        foreach (projectId, _; from)
            if (projectId != except)
                into[projectId] = true;
    }

    private static void addUnique(ref string[] list, string text)
    {
        if (!list.canFind(text))
            list ~= text;
    }

    private static string name_(string projectId)
    {
        return "{" ~ projectId ~ "}";
    }
}
