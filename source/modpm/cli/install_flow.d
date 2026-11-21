module modpm.cli.install_flow;

import std.algorithm.comparison : max;
import std.algorithm.sorting : sort;
import std.array : join, replace, replicate;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize;
import std.format : format;
import std.path : buildPath;
import std.uni : toLower;
import std.utf : count;

import modpm.cli.byte_size;
import modpm.cli.console;
import modpm.cli.exit_code;
import modpm.cli.prompter;
import modpm.download;
import modpm.hash;
import modpm.loaders;
import modpm.lock;
import modpm.manifest;
import modpm.modrinth;
import modpm.planner;
import modpm.resolver;
import modpm.runner;
import modpm.transaction;

final class InstallOptions
{
    string[] packages;
    bool skipUnavailable;
    bool installSuggests;
    bool yes;
}

private final class Line
{
    string title;
    string projectId;
    string versionNumber;
    string channel;
    long size;
    Entry previous;
    string previousChannel;
    long previousSize;
}

private final class Columns
{
    enum sizeWidth = 9;

    size_t name = 7;
    size_t versionNumber = 7;
    size_t channel = 7;

    static string left(string text, size_t width)
    {
        return text ~ " ".replicate(width - text.count);
    }

    static string right(string text, size_t width)
    {
        return " ".replicate(width - text.count) ~ text;
    }

    void fit(size_t nameWidth, size_t versionWidth, size_t channelWidth)
    {
        name = max(name, nameWidth);
        versionNumber = max(versionNumber, versionWidth);
        channel = max(channel, channelWidth);
    }
}

final class InstallFlow
{
    private enum replacingPrefix = "  replacing ";

    private LoaderRegistry registry_;
    private ModrinthClient api_;
    private Downloader downloader_;
    private FileHasher hasher_;
    private Prompter prompter_;
    private Console console_;
    private TransactionObserver steps_;
    private PlanObserver stages_;

    this(LoaderRegistry registry, ModrinthClient api, Downloader downloader,
        FileHasher hasher, Prompter prompter, Console console, TransactionObserver steps,
        PlanObserver stages)
    {
        steps_ = steps;
        stages_ = stages;
        registry_ = registry;
        api_ = api;
        downloader_ = downloader;
        hasher_ = hasher;
        prompter_ = prompter;
        console_ = console;
    }

    int run(InstallOptions options, string startDir)
    {
        try
            return execute(options, startDir);
        catch (PlanProblems e)
        {
            foreach (problem; e.problems)
                console_.errorLine("error: " ~ problem);
            return ExitCode.failure;
        }
        catch (Exception e)
        {
            console_.errorLine("error: " ~ e.msg);
            return ExitCode.failure;
        }
    }

    private int execute(InstallOptions options, string startDir)
    {
        auto scopeDir = ScopeDirectory.findEnclosing(startDir);
        enforce(scopeDir !is null, "there is no modpm scope here. Run `modpm init` first.");

        auto lock = new ScopeLock(scopeDir.lockPath());
        scope (exit)
            lock.release();

        auto manifest = scopeDir.load();
        immutable kind = kindOf(manifest.config);
        auto runner = new TransactionRunner(scopeDir, manifest, api_, downloader_, hasher_, steps_);
        recover(scopeDir, manifest, runner, kind);

        Plan plan;
        {
            scope (failure)
                stages_.abort();
            plan = new Planner(api_, manifest.config, manifest,
                scopeDir.managedPath(manifest.config), stages_)
                .plan(options.packages, options.skipUnavailable, options.installSuggests);
        }

        foreach (message; plan.skipped)
            console_.line(console_.yellow("Skipped: " ~ message));
        foreach (installed; plan.alreadyInstalled)
            console_.line(format("%s %s is already installed.", registry_.singularName(kind), installed));
        immutable noticed = plan.skipped.length + plan.alreadyInstalled.length > 0;

        if (plan.transaction.operations.length == 0)
        {
            if (!noticed)
                console_.line("Nothing to do.");
            return ExitCode.ok;
        }
        if (noticed)
            console_.line();

        printTransaction(plan, scopeDir);
        if (!options.yes && !prompter_.confirm("Is this ok", true))
        {
            console_.line("Cancelled. Nothing was changed.");
            return ExitCode.declined;
        }

        console_.line();
        plan.transaction.save(scopeDir.planPath());
        runner.stage(plan.transaction, plan.metadata);
        runner.apply(plan.transaction);
        runner.commit(plan.transaction);
        console_.line();
        console_.line("Complete!");
        printSuggestions(plan.transaction, kind);
        runner.finish(plan.transaction);
        return ExitCode.ok;
    }

    private void recover(ScopeDirectory scopeDir, Manifest manifest,
        TransactionRunner runner, Kind kind)
    {
        if (!exists(scopeDir.planPath()))
            return;

        auto transaction = Transaction.load(scopeDir.planPath());
        if (transaction.id == manifest.head)
        {
            runner.record(transaction);
            printSuggestions(transaction, kind);
            runner.finish(transaction);
            return;
        }
        enforce(transaction.id == manifest.head + 1,
            "plan.json doesn't match this scope. Delete it to continue.");

        console_.line("Finishing an interrupted transaction...");
        runner.stage(transaction, new Metadata());
        runner.apply(transaction);
        runner.commit(transaction);
        printSuggestions(transaction, kind);
        runner.finish(transaction);
    }

    private Kind kindOf(ScopeConfig config)
    {
        auto loader = config.loaders.length ? registry_.find(config.loaders[0]) : null;
        return loader is null ? Kind.mod : loader.kind;
    }

    private void printTransaction(Plan plan, ScopeDirectory scopeDir)
    {
        auto metadata = plan.metadata;
        Line[] installing;
        Line[] suggested;
        Line[] dependencies;
        Line[] replacing;
        Line[] marking;
        long installBytes;
        long removeBytes;
        long downloadBytes;
        bool downloads;

        foreach (operation; plan.transaction.operations)
        {
            auto line = new Line();
            line.title = operation.to.title;
            line.projectId = operation.projectId;
            line.versionNumber = operation.to.versionNumber;

            auto current = versionOf(metadata, operation.to.versionId);
            line.channel = current is null ? "-" : current.versionType;
            line.size = current is null ? -1 : fileSize(current, operation.to.sha1);

            if (operation.from is null)
            {
                if (operation.projectId in plan.suggested)
                    suggested ~= line;
                else if (operation.to.reason == "dependency")
                    dependencies ~= line;
                else
                    installing ~= line;
            }
            else if (operation.placesFile)
            {
                auto old = versionOf(metadata, operation.from.versionId);
                line.previous = operation.from;
                line.previousChannel = old is null ? "-" : old.versionType;
                line.previousSize = old is null ? -1 : fileSize(old, operation.from.sha1);
                removeBytes += max(line.previousSize, 0);
                replacing ~= line;
            }
            else
                marking ~= line;

            if (operation.placesFile)
            {
                downloads = true;
                installBytes += max(line.size, 0);
                downloadBytes += max(line.size - partSize(scopeDir, operation), 0);
            }
        }

        foreach (lines; [installing, suggested, dependencies, replacing, marking])
            lines.sort!((a, b) => a.title.toLower < b.title.toLower);

        auto columns = new Columns();
        foreach (line; installing ~ suggested ~ dependencies ~ marking)
            columns.fit(line.title.count, line.versionNumber.count, line.channel.count);
        foreach (line; replacing)
        {
            columns.fit(line.title.count, line.versionNumber.count, line.channel.count);
            columns.fit(replacingPrefix.count + line.previous.title.count,
                line.previous.versionNumber.count, line.previousChannel.count);
        }

        immutable fixed = 1 + 2 + columns.versionNumber + 2 + columns.channel + 2 + Columns.sizeWidth;
        columns.name = max(columns.name, console_.width > fixed ? console_.width - fixed : 0);

        console_.line(console_.bold(Columns.left("Package", columns.name + 1))
                ~ "  " ~ console_.bold(Columns.left("Version", columns.versionNumber))
                ~ "  " ~ console_.bold(Columns.left("Channel", columns.channel))
                ~ "  " ~ console_.bold(Columns.right("Size", Columns.sizeWidth)));
        printSection("Installing:", installing, columns, false);
        printSection("Installing suggested packages:", suggested, columns, false);
        printSection("Installing dependencies:", dependencies, columns, false);
        printSection("Replacing:", replacing, columns, true);
        printSection("Marking as installed:", marking, columns, false);
        console_.line();

        printSummary(installing.length + suggested.length + dependencies.length, replacing.length,
            marking.length, plan.skipped.length);
        console_.line();

        if (downloads)
        {
            immutable extra = installBytes - removeBytes;
            console_.line(format("Total size of inbound packages is %s. Need to download %s.",
                    new ByteSize(installBytes).summary, new ByteSize(downloadBytes).summary));
            console_.line(format("After this operation, %s %s (install %s, remove %s)",
                    new ByteSize(extra < 0 ? -extra : extra).summary,
                    extra < 0 ? "will be freed" : "extra will be used",
                    new ByteSize(installBytes).summary, new ByteSize(removeBytes).summary));
            console_.line();
        }
    }

    private void printSection(string header, Line[] lines, Columns columns, bool replacing)
    {
        if (lines.length == 0)
            return;

        console_.line(header);
        foreach (line; lines)
        {
            immutable url = "https://modrinth.com/project/" ~ line.projectId ~ "/";
            console_.line(" " ~ console_.link(url, console_.green(line.title))
                    ~ " ".replicate(columns.name - line.title.count)
                    ~ "  " ~ Columns.left(line.versionNumber, columns.versionNumber)
                    ~ "  " ~ Columns.left(line.channel, columns.channel)
                    ~ "  " ~ Columns.right(sizeText(line.size), Columns.sizeWidth));
            if (replacing)
                console_.line(console_.dim(" "
                        ~ Columns.left(replacingPrefix ~ line.previous.title, columns.name)
                        ~ "  " ~ Columns.left(line.previous.versionNumber, columns.versionNumber)
                        ~ "  " ~ Columns.left(line.previousChannel, columns.channel)
                        ~ "  " ~ Columns.right(sizeText(line.previousSize), Columns.sizeWidth)));
        }
    }

    private void printSummary(size_t installing, size_t replacing, size_t marking, size_t skipping)
    {
        string[] labels;
        size_t[] counts;

        void add(string label, size_t number)
        {
            if (number > 0)
            {
                labels ~= label;
                counts ~= number;
            }
        }

        add("Installing:", installing);
        add("Replacing:", replacing);
        add("Marking:", marking);
        add("Skipping:", skipping);

        size_t labelWidth = 0;
        size_t countWidth = 0;
        foreach (i, label; labels)
        {
            labelWidth = max(labelWidth, label.length);
            countWidth = max(countWidth, counts[i].to!string.length);
        }

        console_.line(console_.bold("Transaction Summary:"));
        foreach (i, label; labels)
            console_.line(" " ~ Columns.left(label, labelWidth + 2)
                    ~ Columns.right(counts[i].to!string, countWidth)
                    ~ (counts[i] == 1 ? " package" : " packages"));
    }

    private void printSuggestions(Transaction transaction, Kind kind)
    {
        if (transaction.suggestions.length == 0)
            return;

        string[] specs;
        bool[string] seen;
        foreach (suggestion; transaction.suggestions)
        {
            console_.line();
            console_.line(format("%s %s suggests these optional %s:", suggestion.title,
                    suggestion.versionNumber, registry_.kindName(kind).toLower));
            foreach (item; suggestion.optional)
            {
                immutable spec = item.versionNumber.length ? item.slug ~ "@" ~ item.versionNumber
                    : item.slug;
                console_.line("  " ~ item.title
                        ~ (item.versionNumber.length ? " " ~ item.versionNumber : "")
                        ~ " " ~ console_.dim("(" ~ spec ~ ")"));
                if (item.slug !in seen)
                {
                    seen[item.slug] = true;
                    specs ~= shellQuote(spec);
                }
            }
        }
        console_.line();
        console_.line("Install all with: modpm install " ~ specs.join(" "));
    }

    private static string sizeText(long bytes)
    {
        return bytes < 0 ? "-" : new ByteSize(bytes).cell;
    }

    private static VersionInfo versionOf(Metadata metadata, string versionId)
    {
        return metadata.knowsVersion(versionId) ? metadata.version_(versionId) : null;
    }

    private static long fileSize(VersionInfo version_, string sha1)
    {
        foreach (file; version_.files)
            if (file.sha1 == sha1)
                return file.size;
        return version_.primaryFile is null ? -1 : version_.primaryFile.size;
    }

    private static long partSize(ScopeDirectory scopeDir, Operation operation)
    {
        immutable part = buildPath(scopeDir.downloadsPath(), operation.to.versionId ~ ".part");
        return exists(part) ? cast(long) getSize(part) : 0;
    }

    private static string shellQuote(string spec)
    {
        bool safe = spec.length > 0;
        foreach (c; spec)
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                    || c == '.' || c == '_' || c == '-' || c == '+' || c == '@' || c == ':'))
                safe = false;
        return safe ? spec : "'" ~ spec.replace("'", "'\\''") ~ "'";
    }
}
