module modpm.cli.init_cmd;

import std.algorithm.comparison : max;
import std.algorithm.iteration : uniq;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join, replicate;
import std.conv : ConvException, to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, getcwd, isDir;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, dirName;
import std.uni : toLower;
import std.utf : count;

import cmd.command;
import cmd.option;
import cmd.parsed_args;

import modpm.cli.console;
import modpm.cli.exit_code;
import modpm.cli.prompter;
import modpm.detect;
import modpm.fsid;
import modpm.loaders;
import modpm.manifest;
import modpm.modrinth;
import modpm.side;

final class InitCommand : Command
{
    private LoaderRegistry registry_;
    private ModrinthClient api_;
    private Prompter prompter_;
    private Console console_;
    private FilesystemChecker filesystem_;
    private Detector detector_;

    this(LoaderRegistry registry, ModrinthClient api, Prompter prompter,
        Console console, FilesystemChecker filesystem, Detector detector)
    {
        super("init")
            .description("Create a modpm scope in the current directory")
            .add(Option.fromString("--loader [id]", "Compatible platforms/loaders")
                    .completer((string prefix) => registry.ids())
                    .env("MODPM_LOADER"))
            .add(Option.fromString("--side [side:client|server]", "Type of the environment")
                    .env("MODPM_SIDE"))
            .add(Option.fromString("--game-version [version]", "Game version, e.g. 1.21.1")
                    .env("MODPM_GAME_VERSION"))
            .add(Option.fromString("--channel [channel:release|beta|alpha]", "Release channel")
                    .env("MODPM_CHANNEL"))
            .add(Option.fromString("--dir [path:dir]", "Directory the files are managed in")
                    .env("MODPM_DIR"))
            .option("--adopt", "Detect and import the files already in the directory")
            .option("--no-adopt", "Don't detect the files already in the directory")
            .option("--no-prompt", "Never prompt: fail if a value is missing")
            .action(&execute);
        registry_ = registry;
        api_ = api;
        prompter_ = prompter;
        console_ = console;
        filesystem_ = filesystem;
        detector_ = detector;
    }

    private int execute(ParsedArgs args)
    {
        try
            return initialise(args, getcwd());
        catch (Exception e)
        {
            console_.errorLine("error: " ~ e.msg);
            return ExitCode.failure;
        }
    }

    private int initialise(ParsedArgs args, string baseDir)
    {
        auto scopeDir = new ScopeDirectory(baseDir);
        enforce(!scopeDir.isInitialised(),
            "modpm is already set up in this directory. Delete " ~ scopeDir.path() ~ " to start over.");
        enforce(!(args.hasFlag("adopt") && args.hasFlag("no-adopt")), "--adopt and --no-adopt can't be used together");
        auto missing = missingFlags(args, baseDir);
        if (args.hasFlag("no-prompt"))
            enforce(missing.length == 0, "--no-prompt needs these flags: " ~ missing.join(", "));

        if (!confirmNesting(args, baseDir))
            return ExitCode.declined;

        auto loaderIds = chooseLoaders(args);
        immutable kind = registry_.kindOf(loaderIds);
        immutable side = chooseSide(args, kind);
        immutable gameVersion = chooseGameVersion(args);
        immutable channel = chooseChannel(args);
        immutable directory = chooseDirectory(args, baseDir);

        auto config = new ScopeConfig(directory, gameVersion, loaderIds,
            ScopeConfig.channelsUpTo(channel), side);
        auto manifest = new Manifest(config);

        if (!adoptExistingFiles(args, kind, baseDir, manifest))
            return ExitCode.failure;

        if (missing.length > 0 && !prompter_.confirm("Is this ok", true))
        {
            console_.line("Cancelled. Nothing was written.");
            return ExitCode.declined;
        }

        scopeDir.create(manifest);
        console_.line(format("Initialised a modpm scope in %s (%d files adopted).",
                scopeDir.path(), manifest.installed.length));
        return ExitCode.ok;
    }

    private string[] missingFlags(ParsedArgs args, string baseDir)
    {
        string[] missing;
        Kind kind;
        bool kindKnown;

        if (givenLoaders(args).length == 0)
            missing ~= "--loader";
        else
        {
            kind = registry_.kindOf(givenLoaders(args));
            kindKnown = true;
            if (given(args, "side").length == 0 && registry_.sidesOf(kind).length > 1)
                missing ~= "--side";
        }

        if (given(args, "game-version").length == 0)
            missing ~= "--game-version";
        if (given(args, "channel").length == 0)
            missing ~= "--channel";
        if (given(args, "dir").length == 0)
            missing ~= "--dir";
        else if (kindKnown && !args.hasFlag("adopt") && !args.hasFlag("no-adopt")
            && detector_.hasFiles(absolutePath(given(args, "dir"), baseDir), registry_.extensionOf(kind)))
            missing ~= "--adopt or --no-adopt";

        return missing;
    }

    private bool confirmNesting(ParsedArgs args, string baseDir)
    {
        auto parent = ScopeDirectory.findEnclosing(dirName(absolutePath(baseDir)));
        if (parent is null)
            return true;

        console_.line("This directory is inside an existing scope: " ~ parent.path());
        if (args.hasFlag("no-prompt"))
            return true;
        return prompter_.confirm("Create a nested scope here", false);
    }

    private string[] chooseLoaders(ParsedArgs args)
    {
        if (givenLoaders(args).length)
        {
            registry_.kindOf(givenLoaders(args));
            auto ids = givenLoaders(args).dup;
            return ids.sort().uniq.array;
        }

        Kind[] kinds = registry_.kinds();
        string[] kindLabels;
        foreach (kind; kinds)
            kindLabels ~= registry_.kindName(kind);
        immutable kind = kinds[prompter_.select("Packages type", kindLabels)];

        auto options = registry_.ofKind(kind);
        if (options.length == 1)
            return [options[0].id];

        string[] names;
        foreach (option; options)
            names ~= option.name;
        string[] ids;
        foreach (index; prompter_.multiSelect("Platform", names))
            ids ~= options[index].id;
        ids.sort();
        return ids;
    }

    private Side chooseSide(ParsedArgs args, Kind kind)
    {
        auto allowed = registry_.sidesOf(kind);

        if (given(args, "side").length)
        {
            Side side = given(args, "side").to!Side;
            enforce(allowed.canFind(side), format("%s can only run on: %s",
                    registry_.kindName(kind), sideNames(allowed)));
            return side;
        }

        if (allowed.length == 1)
            return allowed[0];

        string[] labels;
        foreach (side; allowed)
            labels ~= sideLabel(side);
        return allowed[prompter_.select("Environment", labels)];
    }

    private string chooseGameVersion(ParsedArgs args)
    {
        string[] known;
        foreach (version_; api_.fetchGameVersions())
            known ~= version_.name;
        enforce(known.length > 0, "Modrinth returned no game versions");

        if (given(args, "game-version").length)
        {
            enforce(known.canFind(given(args, "game-version")), "unknown game version: " ~ given(args, "game-version"));
            return given(args, "game-version");
        }

        return prompter_.text("Game version",
            (string typed) => completeFrom(known, typed),
            (string answer) => known.canFind(answer) ? ""
                : format("'%s' is not a known game version", answer));
    }

    private string chooseChannel(ParsedArgs args)
    {
        if (given(args, "channel").length)
            return given(args, "channel");

        string[] labels = [
            "Stable only",
            "Stable and beta",
            "Stable, beta, and alpha",
        ];
        return ScopeConfig.channelOrder[prompter_.select("Release channel", labels)];
    }

    private string chooseDirectory(ParsedArgs args, string baseDir)
    {
        if (given(args, "dir").length)
        {
            immutable problem = directoryProblem(given(args, "dir"), baseDir);
            enforce(problem.length == 0, problem);
            return normalizeDirectory(given(args, "dir"));
        }

        return normalizeDirectory(prompter_.text("Packages directory",
                (string typed) => completeDirectory(typed, baseDir),
                (string answer) => directoryProblem(answer, baseDir)));
    }

    private string directoryProblem(string answer, string baseDir)
    {
        if (answer.length == 0)
            return "Please enter a directory.";

        immutable absolute = absolutePath(answer, baseDir);
        if (exists(absolute) && !isDir(absolute))
            return format("%s is a file, not a directory.", absolute);
        if (!filesystem_.onSameFilesystem(absolute, baseDir))
            return format("%s is on a different filesystem than %s, so files can't be "
                    ~ "moved into it atomically.", absolute, baseDir);
        return "";
    }

    private bool adoptExistingFiles(ParsedArgs args, Kind kind, string baseDir, Manifest manifest)
    {
        immutable directory = absolutePath(manifest.config.directory, baseDir);
        immutable suffix = registry_.extensionOf(kind);
        if (!detector_.hasFiles(directory, suffix))
            return true;

        bool adopt = args.hasFlag("adopt");
        if (!args.hasFlag("adopt") && !args.hasFlag("no-adopt"))
            adopt = prompter_.confirm(format("Scan files and identify %s to import", registry_.kindName(kind).toLower), true);
        if (!adopt)
            return true;

        auto result = detector_.detect(directory, manifest.config, suffix);
        printDetection(result, kind);

        if (!result.adoptable)
        {
            console_.errorLine("These files can't be adopted:");
            foreach (problem; result.problems)
                console_.errorLine("  " ~ problem);
            console_.errorLine("Run init with --no-adopt to skip detection.");
            return false;
        }

        foreach (file; result.detected)
            manifest.add(file.versionInfo.projectId, file.toEntry());
        return true;
    }

    private void printDetection(DetectionResult result, Kind kind)
    {
        if (result.detected.length)
        {
            console_.line(console_.bold("Detected:"));
            size_t width = 0;
            foreach (file; result.detected)
                width = max(width, file.displayName.count + (file.flagged ? 1 : 0));

            foreach (file; result.detected)
            {
                immutable cell = file.displayName ~ (file.flagged ? "*" : "");
                immutable colored = file.flagged ? console_.yellow(cell) : console_.green(cell);
                immutable url = "https://modrinth.com/project/" ~ file.project.id ~ "/";
                console_.line("  " ~ console_.link(url, colored) ~ " ".replicate(width - cell.count)
                        ~ " " ~ file.versionInfo.versionNumber);
            }
        }

        if (result.hasFlagged)
            console_.line(console_.yellow("* These " ~ registry_.kindName(kind).toLower
                    ~ " don't match the configured " ~ joinOr(result.mismatchKinds()) ~ "."));

        auto notDetected = result.undetected ~ result.ignored;
        notDetected.sort();
        if (notDetected.length)
        {
            if (result.detected.length)
                console_.line();
            console_.line(console_.bold("Not detected:"));
            foreach (name; notDetected)
                console_.line("  " ~ console_.red(name));
        }

        if (kind == Kind.plugin && result.undetected.length)
            console_.line(console_.yellow(console_.bold("Warning:")
                    ~ " SpigotMC modifies jars on download, so plugins from there can't be "
                    ~ "identified. To manage them with modpm, delete them and run `modpm install`."));
    }

    private static string given(ParsedArgs args, string name)
    {
        return args.hasOption(name) ? args.option(name) : "";
    }

    private static string[] givenLoaders(ParsedArgs args)
    {
        return args.hasOption("loader") ? args.optionList("loader").dup : null;
    }

    private static string joinOr(string[] items)
    {
        if (items.length <= 1)
            return items.join();
        if (items.length == 2)
            return items[0] ~ " or " ~ items[1];
        return items[0 .. $ - 1].join(", ") ~ ", or " ~ items[$ - 1];
    }

    private static string completeFrom(string[] candidates, string typed)
    {
        foreach (candidate; candidates)
            if (candidate.startsWith(typed))
                return candidate;
        return "";
    }

    private static string completeDirectory(string typed, string baseDir)
    {
        if (typed.length == 0)
            return "";

        sizediff_t split = -1;
        foreach (i, c; typed)
            if (isSeparator(c))
                split = i;
        immutable parentPart = typed[0 .. split + 1];
        immutable namePart = typed[split + 1 .. $];
        immutable parentDir = absolutePath(parentPart.length ? parentPart : ".", baseDir);

        try
        {
            if (!exists(parentDir) || !isDir(parentDir))
                return "";

            string[] names;
            foreach (entry; dirEntries(parentDir, SpanMode.shallow))
            {
                immutable name = baseName(entry.name);
                if (entry.isDir && name.startsWith(namePart)
                    && (!name.startsWith(".") || namePart.startsWith(".")))
                    names ~= name;
            }
            if (names.length == 0)
                return "";
            names.sort();
            return parentPart ~ names[0] ~ "/";
        }
        catch (Exception)
            return "";
    }

    private static bool isSeparator(char c)
    {
        version (Windows)
            return c == '/' || c == '\\';
        else
            return c == '/';
    }

    private static string normalizeDirectory(string answer)
    {
        auto path = buildNormalizedPath(answer);
        version (Windows)
        {
            import std.string : replace;

            path = path.replace("\\", "/");
        }
        return path;
    }

    private static string sideLabel(Side side)
    {
        final switch (side)
        {
        case Side.client:
            return "Client";
        case Side.server:
            return "Server";
        }
    }

    private static string sideNames(const(Side)[] sides)
    {
        string[] names;
        foreach (side; sides)
            names ~= side.to!string;
        return names.join(" or ");
    }
}
