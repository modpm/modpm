module modpm.cli.install_cmd;

import std.file : getcwd;
import std.format : format;
import std.string : lastIndexOf;
import std.uni : toLower;

import cmd.command;
import cmd.parsed_args;

import modpm.cli.transaction_executor;
import modpm.modrinth;
import modpm.planner;
import modpm.resolver;
import modpm.transaction_builder;

final class InstallCommand : Command
{
    private TransactionExecutor executor_;
    private ModrinthClient api_;
    private PlanObserver stages_;

    this(TransactionExecutor executor, ModrinthClient api, PlanObserver stages)
    {
        super("install")
            .description("Install packages and their dependencies")
            .argument("<packages...>", "Packages to install, as slug or slug@version")
            .option("--skip-unavailable", "Skip packages that can't be installed instead of failing")
            .option("--install-suggests", "Also install suggested packages that are available and compatible")
            .option("-y, --yes", "Don't ask for confirmation")
            .action(&execute);
        executor_ = executor;
        api_ = api;
        stages_ = stages;
    }

    private int execute(ParsedArgs args)
    {
        string[] packages;
        foreach (spec; args.argumentList("packages"))
            packages ~= spec;

        Plan prepare(ScopeSession session)
        {
            auto request = new PlanRequest();
            request.installSuggests = args.hasFlag("install-suggests");
            {
                scope (failure)
                    stages_.abort();
                stages_.begin("Looking up packages", "Looked up packages");

                bool[string] wanted;
                foreach (spec; packages)
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
                    request.projects[id] = project;
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

                string[] problems;
                bool[string] seen;
                foreach (spec; packages)
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
                        problems ~= format("%s is a modpack, which modpm doesn't support",
                            project.displayName);
                        continue;
                    }
                    if (project.id in seen)
                    {
                        problems ~= format("%s is listed twice", project.displayName);
                        continue;
                    }
                    seen[project.id] = true;
                    request.install ~= new Request(project.id, versionNumber);
                }
                if (problems.length)
                    throw new PlanProblems(problems);
                stages_.end();
            }

            auto plan = executor_.plan(session, request, stages_);
            if (!args.hasFlag("skip-unavailable") && plan.unavailable.length)
                throw new PlanProblems(plan.unavailable);
            return plan;
        }

        return executor_.run(getcwd(), args.hasFlag("yes"), &prepare);
    }
}
