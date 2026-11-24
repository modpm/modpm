module modpm.runner;

import std.algorithm.searching : canFind;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.exception : enforce;
import std.file : FileException, SpanMode, dirEntries, exists, getSize, mkdirRecurse, readText,
    remove, rename;
import std.format : format;
import std.json : JSONOptions;
import std.path : buildPath;
import std.stdio : File;
import std.string : lineSplitter, strip;

import modpm.download;
import modpm.hash;
import modpm.jsonio;
import modpm.manifest;
import modpm.modrinth;
import modpm.resolver;
import modpm.transaction;

interface TransactionObserver
{
    void begin(string[] steps);

    void completed(long bytes);
}

final class TransactionRunner
{
    private ScopeDirectory scopeDir_;
    private Manifest manifest_;
    private ModrinthClient api_;
    private Downloader downloader_;
    private FileHasher hasher_;
    private TransactionObserver observer_;

    this(ScopeDirectory scopeDir, Manifest manifest, ModrinthClient api,
        Downloader downloader, FileHasher hasher, TransactionObserver observer)
    {
        observer_ = observer;
        scopeDir_ = scopeDir;
        manifest_ = manifest;
        api_ = api;
        downloader_ = downloader;
        hasher_ = hasher;
    }

    void stage(Transaction transaction, Metadata metadata)
    {
        mkdirRecurse(scopeDir_.downloadsPath());

        string[] unknown;
        foreach (operation; pending(transaction))
            if (operation.placesFile && !metadata.knowsVersion(operation.to.versionId))
                unknown ~= operation.to.versionId;
        if (unknown.length)
            metadata.addVersions(unknown, api_.fetchVersionsByIds(unknown));

        DownloadJob[] jobs;
        foreach (operation; pending(transaction))
        {
            if (!operation.placesFile)
                continue;

            auto version_ = metadata.version_(operation.to.versionId);
            enforce(version_ !is null, format("%s %s is no longer available on Modrinth",
                    operation.to.title, operation.to.versionNumber));

            VersionFile file;
            foreach (candidate; version_.files)
                if (candidate.sha1 == operation.to.sha1)
                    file = candidate;
            enforce(file !is null, format("%s %s changed on Modrinth since it was planned",
                    operation.to.title, operation.to.versionNumber));

            auto job = new DownloadJob();
            job.versionId = operation.to.versionId;
            job.label = operation.to.filename;
            job.url = file.url;
            job.sha1 = file.sha1;
            job.size = file.size;
            job.partPath = partPath(operation);
            jobs ~= job;
        }
        downloader_.download(jobs);
    }

    void apply(Transaction transaction)
    {
        immutable managed = scopeDir_.managedPath(manifest_.config);
        mkdirRecurse(managed);

        Operation[] work;
        long verified = 0;
        foreach (operation; pending(transaction))
        {
            if (!operation.placesFile)
            {
                work ~= operation;
                continue;
            }

            immutable part = partPath(operation);
            if (exists(part) && hasher_.sha1(part) == operation.to.sha1)
            {
                verified += getSize(part);
                work ~= operation;
                continue;
            }

            immutable target = buildPath(managed, operation.to.filename);
            if (exists(target) && hasher_.sha1(target) == operation.to.sha1)
            {
                markApplied(transaction, operation);
                continue;
            }
            throw new Exception(format("%s %s hasn't been downloaded", operation.to.title,
                    operation.to.versionNumber));
        }

        bool verifies = false;
        foreach (operation; work)
            if (operation.placesFile)
                verifies = true;

        string[] steps;
        if (verifies)
            steps ~= "Verify package files";
        foreach (operation; work)
            steps ~= describe(operation);
        steps ~= "Update manifest";
        if (observer_ !is null)
        {
            observer_.begin(steps);
            if (verifies)
                observer_.completed(verified);
        }

        foreach (operation; work)
        {
            long bytes = -1;
            if (operation.placesFile)
                bytes = cast(long) getSize(partPath(operation));
            else if (operation.removesOldFile)
            {
                immutable old = buildPath(managed, operation.from.filename);
                if (exists(old))
                    bytes = cast(long) getSize(old);
            }

            if (operation.placesFile)
                rename(partPath(operation), buildPath(managed, operation.to.filename));
            if (operation.removesOldFile)
                removeIfPresent(buildPath(managed, operation.from.filename));
            markApplied(transaction, operation);
            if (observer_ !is null)
                observer_.completed(bytes);
        }
    }

    void commit(Transaction transaction)
    {
        foreach (operation; transaction.operations)
        {
            if (operation.to is null)
            {
                manifest_.installed.remove(operation.projectId);
                continue;
            }

            auto entry = operation.to.duplicate();
            if (auto existing = operation.projectId in manifest_.installed)
                entry.frozen = (*existing).frozen;
            manifest_.installed[operation.projectId] = entry;
        }
        manifest_.head = transaction.id;
        scopeDir_.save(manifest_);
        record(transaction);
        if (observer_ !is null)
            observer_.completed(-1);
    }

    void record(Transaction transaction)
    {
        appendHistory(transaction);
    }

    void finish(Transaction transaction)
    {
        if (exists(scopeDir_.planPath()))
            remove(scopeDir_.planPath());
        clearDownloads();
    }

    private static string describe(Operation operation)
    {
        if (operation.to is null)
            return format("Removing %s %s", operation.from.title, operation.from.versionNumber);
        if (operation.from is null)
            return format("Installing %s %s", operation.to.title, operation.to.versionNumber);
        if (operation.placesFile)
            return format("Replacing %s %s with %s", operation.to.title,
                operation.from.versionNumber, operation.to.versionNumber);
        return format("Marking %s as installed", operation.to.title);
    }

    private Operation[] pending(Transaction transaction)
    {
        Operation[] result;
        foreach (operation; transaction.operations)
            if (!transaction.applied.canFind(operation.projectId))
                result ~= operation;
        return result;
    }

    private string partPath(Operation operation)
    {
        return buildPath(scopeDir_.downloadsPath(), operation.to.versionId ~ ".part");
    }

    private void markApplied(Transaction transaction, Operation operation)
    {
        transaction.applied ~= operation.projectId;
        transaction.save(scopeDir_.planPath());
    }

    private static void removeIfPresent(string path)
    {
        try
            remove(path);
        catch (FileException e)
        {
            if (exists(path))
                throw e;
        }
    }

    private void appendHistory(Transaction transaction)
    {
        immutable path = scopeDir_.historyPath();
        if (exists(path))
        {
            string last;
            foreach (line; readText(path).lineSplitter)
                if (line.strip.length)
                    last = line;
            if (last.length && JsonView.parse(last).integer("id") == transaction.id)
                return;
        }

        auto file = File(path, "ab");
        file.writeln(transaction.toHistoryJson(Clock.currTime(UTC()).toISOExtString())
                .toString(JSONOptions.doNotEscapeSlashes));
        file.flush();
        file.sync();
        file.close();
    }

    private void clearDownloads()
    {
        immutable directory = scopeDir_.downloadsPath();
        if (!exists(directory))
            return;
        foreach (entry; dirEntries(directory, SpanMode.shallow))
            if (entry.isFile)
                remove(entry.name);
    }
}
