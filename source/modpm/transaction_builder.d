module modpm.transaction_builder;

import std.algorithm.sorting : sort;
import std.array : join;
import std.file : exists;
import std.format : format;
import std.path : buildPath;
import std.uni : toLower;

import modpm.manifest;
import modpm.orphans;
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

final class TransactionBuilder
{
    private Manifest manifest_;
    private string managedDir_;
    private Transaction transaction_;

    this(Manifest manifest, string managedDir)
    {
        manifest_ = manifest;
        managedDir_ = managedDir;
        transaction_ = new Transaction();
        transaction_.id = manifest.head + 1;
    }

    void add(Operation operation)
    {
        transaction_.operations ~= operation;
    }

    Transaction build(string[] problems = null)
    {
        checkEachProjectOnce(problems);
        if (problems.length)
            throw new PlanProblems(problems);

        removeUnusedDependencies();
        checkRemovalsNotRequired(problems);
        checkFileNames(problems);
        if (problems.length)
            throw new PlanProblems(problems);
        return transaction_;
    }

    private void checkEachProjectOnce(ref string[] problems)
    {
        bool[string] seen;
        foreach (operation; transaction_.operations)
        {
            if (operation.projectId in seen)
                problems ~= format("%s is selected for both removal and installation",
                    (operation.to !is null ? operation.to : operation.from).title);
            seen[operation.projectId] = true;
        }
    }

    private void removeUnusedDependencies()
    {
        auto state = transaction_.stateAfter(manifest_);
        Entry[] gone;
        bool[string] touched;
        foreach (operation; transaction_.operations)
        {
            touched[operation.projectId] = true;
            if (operation.from !is null && (operation.to is null || operation.placesFile))
                gone ~= operation.from;
        }

        foreach (projectId; new OrphanFinder().find(state, gone, touched))
            add(Operation.removal(projectId, manifest_.installed[projectId], true));
    }

    private void checkRemovalsNotRequired(ref string[] problems)
    {
        auto state = transaction_.stateAfter(manifest_);
        foreach (operation; transaction_.operations)
        {
            if (operation.to !is null)
                continue;

            string[] dependents;
            foreach (otherId, other; state.installed)
                if (operation.projectId in other.requires)
                    dependents ~= other.title;
            if (dependents.length == 0)
                continue;

            dependents.sort();
            problems ~= format("%s is required by %s", operation.from.title,
                join(dependents, ", "));
        }
    }

    private void checkFileNames(ref string[] problems)
    {
        bool[string] changed;
        bool[string] freed;
        foreach (operation; transaction_.operations)
        {
            changed[operation.projectId] = true;
            if (operation.removesOldFile)
                freed[operation.from.filename.toLower] = true;
        }

        string[string] taken;
        foreach (projectId, entry; manifest_.installed)
            if (projectId !in changed)
                taken[entry.filename.toLower] = entry.title;

        foreach (operation; transaction_.operations)
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
}
