module modpm.cli.recovery;

import std.exception : enforce;
import std.file : exists;

import modpm.cli.console;
import modpm.cli.suggestion_notice;
import modpm.loaders;
import modpm.manifest;
import modpm.resolver;
import modpm.runner;
import modpm.transaction;

final class Recovery
{
    private Console console_;
    private SuggestionNotice notice_;

    this(Console console, SuggestionNotice notice)
    {
        console_ = console;
        notice_ = notice;
    }

    void run(ScopeDirectory scopeDir, Manifest manifest, TransactionRunner runner, Kind kind)
    {
        if (!exists(scopeDir.planPath()))
            return;

        auto transaction = Transaction.load(scopeDir.planPath());
        if (transaction.id == manifest.head)
        {
            runner.record(transaction);
            notice_.print(transaction, kind);
            runner.finish(transaction);
            return;
        }
        enforce(transaction.id == manifest.head + 1,
            "plan.json doesn't match this scope. Delete it to continue.");

        console_.line("Finishing an interrupted transaction...");
        runner.stage(transaction, new Metadata());
        runner.apply(transaction);
        runner.commit(transaction);
        notice_.print(transaction, kind);
        runner.finish(transaction);
    }
}
