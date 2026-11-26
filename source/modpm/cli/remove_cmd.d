module modpm.cli.remove_cmd;

import std.file : getcwd;
import std.format : format;
import std.uni : toLower;

import cmd.command;
import cmd.parsed_args;

import modpm.cli.transaction_executor;
import modpm.planner;
import modpm.transaction_builder;

final class RemoveCommand : Command
{
    private TransactionExecutor executor_;

    this(TransactionExecutor executor)
    {
        super("remove")
            .description("Remove packages and the dependencies nothing else uses")
            .argument("<packages...>", "Packages to remove, by slug")
            .option("-y, --yes", "Don't ask for confirmation")
            .action(&execute);
        executor_ = executor;
    }

    private int execute(ParsedArgs args)
    {
        Plan prepare(ScopeSession session)
        {
            auto manifest = session.manifest;
            auto request = new PlanRequest();
            string[] problems;
            bool[string] seen;
            foreach (spec; args.argumentList("packages"))
            {
                string found;
                if (spec in manifest.installed)
                    found = spec;
                else
                {
                    foreach (projectId, entry; manifest.installed)
                    {
                        if (entry.slug.toLower == spec.toLower)
                        {
                            found = projectId;
                            break;
                        }
                    }
                }

                if (found.length == 0)
                {
                    problems ~= format("%s is not installed", spec);
                    continue;
                }
                if (found in seen)
                    continue;
                seen[found] = true;
                request.remove ~= found;
            }
            if (problems.length)
                throw new PlanProblems(problems);
            return executor_.plan(session, request);
        }

        return executor_.run(getcwd(), args.hasFlag("yes"), &prepare);
    }
}
