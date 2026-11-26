module modpm.cli.transaction_report;

import std.algorithm.comparison : max;
import std.file : exists, getSize;
import std.format : format;
import std.path : buildPath;

import modpm.cli.byte_size;
import modpm.cli.console;
import modpm.cli.transaction_table;
import modpm.manifest;
import modpm.modrinth;
import modpm.planner;
import modpm.transaction;

final class TransactionReport
{
    private Console console_;
    private Plan plan_;
    private ScopeDirectory scopeDir_;
    private string managedDir_;

    this(Console console, Plan plan, ScopeDirectory scopeDir, string managedDir)
    {
        console_ = console;
        plan_ = plan;
        scopeDir_ = scopeDir;
        managedDir_ = managedDir;
    }

    void print()
    {
        TableRow[] installing;
        TableRow[] dependencies;
        TableRow[] replacing;
        TableRow[] marking;
        TableRow[] removing;
        TableRow[] unused;
        long installBytes;
        long removeBytes;
        long downloadBytes;
        bool downloads;

        foreach (operation; plan_.transaction.operations)
        {
            if (operation.to is null)
            {
                auto gone = outgoingRow(operation);
                removeBytes += max(gone.size, 0);
                if (operation.unused)
                    unused ~= gone;
                else
                    removing ~= gone;
                continue;
            }

            auto row = rowFor(operation.projectId, operation.to);
            if (operation.from is null)
            {
                if (operation.to.reason == "dependency")
                    dependencies ~= row;
                else
                    installing ~= row;
            }
            else if (operation.placesFile)
            {
                auto old = outgoingRow(operation);
                row.replaces = true;
                row.previousTitle = old.title;
                row.previousVersion = old.versionNumber;
                row.previousChannel = old.channel;
                row.previousSize = old.size;
                removeBytes += max(old.size, 0);
                replacing ~= row;
            }
            else
                marking ~= row;

            if (operation.placesFile)
            {
                downloads = true;
                installBytes += max(row.size, 0);
                immutable part = buildPath(scopeDir_.downloadsPath(), operation.to.versionId ~ ".part");
                downloadBytes += max(row.size - (exists(part) ? cast(long) getSize(part) : 0), 0);
            }
        }

        auto table = new TransactionTable(console_);
        table.add("Installing:", installing);
        table.add("Installing dependencies:", dependencies);
        table.add("Replacing:", replacing);
        table.add("Marking as installed:", marking);
        table.add("Removing:", removing, true);
        table.add("Removing unused dependencies:", unused, true);
        table.print();

        auto summary = new TransactionSummary(console_);
        summary.add("Installing:", installing.length + dependencies.length);
        summary.add("Replacing:", replacing.length);
        summary.add("Marking:", marking.length);
        summary.add("Removing:", removing.length + unused.length);
        summary.add("Skipping:", plan_.unavailable.length);
        summary.print();
        console_.line();

        if (downloads)
            console_.line(format("Total size of inbound packages is %s. Need to download %s.",
                    new ByteSize(installBytes).summary, new ByteSize(downloadBytes).summary));
        if (installBytes > 0 || removeBytes > 0)
        {
            immutable extra = installBytes - removeBytes;
            console_.line(format("After this operation, %s %s (install %s, remove %s)",
                    new ByteSize(extra < 0 ? -extra : extra).summary,
                    extra < 0 ? "will be freed" : "extra will be used",
                    new ByteSize(installBytes).summary, new ByteSize(removeBytes).summary));
        }
        if (downloads || installBytes > 0 || removeBytes > 0)
            console_.line();
    }

    private TableRow rowFor(string projectId, Entry entry)
    {
        auto row = new TableRow();
        row.title = entry.title;
        row.projectId = projectId;
        row.versionNumber = entry.versionNumber;
        if (plan_.metadata.knowsVersion(entry.versionId))
        {
            auto version_ = plan_.metadata.version_(entry.versionId);
            row.channel = version_.versionType;
            row.size = version_.primaryFile is null ? -1 : version_.primaryFile.size;
            foreach (file; version_.files)
            {
                if (file.sha1 == entry.sha1)
                {
                    row.size = file.size;
                    break;
                }
            }
        }
        return row;
    }

    private TableRow outgoingRow(Operation operation)
    {
        auto row = rowFor(operation.projectId, operation.from);
        immutable path = buildPath(managedDir_, operation.from.filename);
        if (exists(path))
            row.size = cast(long) getSize(path);
        return row;
    }
}
