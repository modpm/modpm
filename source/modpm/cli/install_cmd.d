module modpm.cli.install_cmd;

import std.file : getcwd;

import cmd.command;
import cmd.parsed_args;

import modpm.cli.install_flow;

final class InstallCommand : Command
{
    private InstallFlow flow_;

    this(InstallFlow flow)
    {
        super("install")
            .description("Install packages and their dependencies")
            .argument("<packages...>", "Packages to install, as slug or slug@version")
            .option("--skip-unavailable", "Skip packages that can't be installed instead of failing")
            .option("--install-suggests", "Also install suggested packages that are available and compatible")
            .option("-y, --yes", "Don't ask for confirmation")
            .action(&execute);
        flow_ = flow;
    }

    private int execute(ParsedArgs args)
    {
        auto options = new InstallOptions();
        foreach (spec; args.argumentList("packages"))
            options.packages ~= spec;
        options.skipUnavailable = args.hasFlag("skip-unavailable");
        options.installSuggests = args.hasFlag("install-suggests");
        options.yes = args.hasFlag("yes");
        return flow_.run(options, getcwd());
    }
}
