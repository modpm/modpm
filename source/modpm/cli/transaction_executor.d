module modpm.cli.transaction_executor;

import std.exception : enforce;
import std.format : format;

import modpm.cli.console;
import modpm.cli.exit_code;
import modpm.cli.prompter;
import modpm.cli.recovery;
import modpm.cli.suggestion_notice;
import modpm.cli.transaction_report;
import modpm.download;
import modpm.hash;
import modpm.loaders;
import modpm.lock;
import modpm.manifest;
import modpm.modrinth;
import modpm.planner;
import modpm.runner;
import modpm.transaction;
import modpm.transaction_builder;

final class ScopeSession
{
    ScopeDirectory scopeDir;
    Manifest manifest;
    Kind kind;
    TransactionRunner runner;

    @property string managedDir()
    {
        return scopeDir.managedPath(manifest.config);
    }
}

final class TransactionExecutor
{
    private LoaderRegistry registry_;
    private ModrinthClient api_;
    private Prompter prompter_;
    private Console console_;
    private SuggestionNotice notice_;
    private Downloader downloader_;
    private FileHasher hasher_;
    private TransactionObserver steps_;
    private Recovery recovery_;

    this(LoaderRegistry registry, ModrinthClient api, Downloader downloader,
        FileHasher hasher, Prompter prompter, Console console, TransactionObserver steps)
    {
        registry_ = registry;
        api_ = api;
        downloader_ = downloader;
        hasher_ = hasher;
        prompter_ = prompter;
        console_ = console;
        steps_ = steps;
        notice_ = new SuggestionNotice(console, registry);
        recovery_ = new Recovery(console, notice_);
    }

    Plan plan(ScopeSession session, PlanRequest request, PlanObserver stages = null)
    {
        return new Planner(api_, session.manifest.config, session.manifest,
            session.managedDir, stages).plan(request);
    }

    int run(string startDir, bool yes, Plan delegate(ScopeSession) prepare)
    {
        try
            return execute(startDir, yes, prepare);
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

    private int execute(string startDir, bool yes, Plan delegate(ScopeSession) prepare)
    {
        auto scopeDir = ScopeDirectory.findEnclosing(startDir);
        enforce(scopeDir !is null, "there is no modpm scope here. Run `modpm init` first.");

        auto lock = new ScopeLock(scopeDir.lockPath());
        scope (exit)
            lock.release();

        auto session = new ScopeSession();
        session.scopeDir = scopeDir;
        session.manifest = scopeDir.load();
        session.kind = registry_.scopeKind(session.manifest.config.loaders);
        session.runner = new TransactionRunner(scopeDir, session.manifest, api_,
            downloader_, hasher_, steps_);
        recovery_.run(scopeDir, session.manifest, session.runner, session.kind);

        auto plan = prepare(session);
        auto transaction = plan.transaction;
        foreach (message; plan.unavailable)
            console_.line(console_.yellow("Skipped: " ~ message));
        foreach (installed; plan.alreadyInstalled)
            console_.line(format("%s %s is already installed.",
                    registry_.singularName(session.kind), installed));
        immutable noticed = plan.unavailable.length + plan.alreadyInstalled.length > 0;
        if (transaction.operations.length == 0)
        {
            if (!noticed)
                console_.line("Nothing to do.");
            return ExitCode.ok;
        }

        if (noticed)
            console_.line();
        new TransactionReport(console_, plan, scopeDir, session.managedDir).print();
        if (!yes && !prompter_.confirm("Is this ok", true))
        {
            console_.line("Cancelled. Nothing was changed.");
            return ExitCode.declined;
        }

        console_.line();
        transaction.save(scopeDir.planPath());
        session.runner.stage(transaction, plan.metadata);
        session.runner.apply(transaction);
        session.runner.commit(transaction);
        console_.line();
        console_.line("Complete!");
        notice_.print(transaction, session.kind);
        session.runner.finish(transaction);
        return ExitCode.ok;
    }
}
