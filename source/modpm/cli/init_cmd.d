module modpm.cli.init_cmd;

import std.file : getcwd;

import cmd.command;
import cmd.parsed_args;

import modpm.cli.init_wizard;

final class InitCommand : Command
{
    private InitWizard wizard_;

    this(InitWizard wizard)
    {
        super("init")
            .description("Create a modpm scope in the current directory")
            .option("--loader [id]", "Loader to accept (repeat for several)")
            .option("--side [side]", "Where the files run: client or server")
            .option("--game-version [version]", "Game version, e.g. 1.21.1")
            .option("--channel [channel]", "Release channel: release, beta or alpha")
            .option("--dir [path]", "Directory the files are managed in")
            .option("--adopt", "Detect and import the files already in the directory")
            .option("--no-adopt", "Don't detect the files already in the directory")
            .option("--no-prompt", "Never prompt: fail if a value is missing")
            .action(&execute);
        wizard_ = wizard;
    }

    private int execute(ParsedArgs args)
    {
        auto flags = new InitFlags();
        if (args.hasOption("loader"))
            foreach (id; args.optionList("loader"))
                flags.loaders ~= id;
        if (args.hasOption("side"))
            flags.side = args.option("side");
        if (args.hasOption("game-version"))
            flags.gameVersion = args.option("game-version");
        if (args.hasOption("channel"))
            flags.channel = args.option("channel");
        if (args.hasOption("dir"))
            flags.directory = args.option("dir");
        flags.adopt = args.hasFlag("adopt");
        flags.noAdopt = args.hasFlag("no-adopt");
        flags.noPrompt = args.hasFlag("no-prompt");

        return wizard_.run(flags, getcwd());
    }
}
