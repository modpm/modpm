module modpm.cli.search_cmd;

import std.array : appender, join;
import std.conv : ConvException, to;
import std.exception : enforce;
import std.file : getcwd;
import std.format : format;
import std.string : endsWith, split, strip;
import std.uni : toLower;

import cmd.command;
import cmd.parsed_args;

import modpm.cli.console;
import modpm.cli.exit_code;
import modpm.cli.pager;
import modpm.loaders;
import modpm.manifest;
import modpm.modrinth;
import modpm.side;

final class SearchOptions
{
    string query;
    string limitText;
    string pageText;
    string sortText;
    string[] categories;
    bool noPager;
}

final class SearchCommand : Command
{
    private enum environments = [
        "client_and_server", "client_only", "client_only_server_optional",
        "singleplayer_only", "server_only", "server_only_client_optional",
        "dedicated_server_only", "client_or_server", "client_or_server_prefers_both",
        "unknown",
    ];

    private ModrinthClient api_;
    private Console console_;
    private LoaderRegistry registry_;

    this(ModrinthClient api, Console console, LoaderRegistry registry)
    {
        super("search")
            .description("Search Modrinth for packages compatible with this scope")
            .argument("<terms...>", "Search terms")
            .option("--limit [count:int]", "Maximum number of results per page", "50")
            .option("--page [number:int]", "Page number to show", "1")
            .option("--sort [criterion:relevance|downloads|follows|newest|updated]", "Sort order", "relevance")
            .option("--category [name]", "Categories filter")
            .option("--no-pager", "Print all results without paging")
            .action(&execute);
        api_ = api;
        console_ = console;
        registry_ = registry;
    }

    private int execute(ParsedArgs args)
    {
        auto options = new SearchOptions();
        options.query = args.argumentList("terms").join(" ");
        if (args.hasOption("limit"))
            options.limitText = args.option("limit");
        if (args.hasOption("page"))
            options.pageText = args.option("page");
        if (args.hasOption("sort"))
            options.sortText = args.option("sort");
        if (args.hasOption("category"))
            options.categories = args.optionList("category").dup;
        options.noPager = args.hasFlag("no-pager");

        try
            return search(options, getcwd());
        catch (Exception e)
        {
            console_.errorLine("error: " ~ e.msg);
            return ExitCode.failure;
        }
    }

    private int search(SearchOptions options, string startDir)
    {
        auto scopeDir = ScopeDirectory.findEnclosing(startDir);
        immutable haveScope = scopeDir !is null;

        ScopeConfig config;
        Kind kind;
        string[][] facets;
        if (haveScope)
        {
            config = scopeDir.load().config;
            kind = registry_.kindOf(config.loaders);
            facets = compatibilityFacets(config, kind);
        }

        immutable limit = parseLimit(options.limitText);
        immutable pageNumber = parsePage(options.pageText);
        immutable offset = (pageNumber - 1) * limit;
        auto categories = parseCategories(options.categories);

        if (categories.length)
        {
            string[] categoryGroup;
            foreach (category; categories)
                categoryGroup ~= "categories:" ~ category;
            facets ~= categoryGroup;
        }

        auto results = api_.searchProjects(options.query, facets, limit, offset, options.sortText);

        if (results.hits.length == 0)
        {
            if (pageNumber > 1 && results.totalHits > 0)
                console_.line(format("No results on page %s.", pageNumber));
            else if (haveScope)
                console_.line(format("No compatible %s found for \"%s\".",
                        registry_.kindName(kind).toLower, options.query));
            else
                console_.line(format("No packages found for \"%s\".", options.query));
            return ExitCode.ok;
        }

        auto output = appender!string;
        void emit(string line = "")
        {
            output.put(line);
            output.put('\n');
        }

        printHeader(results, options, config, kind, haveScope, limit, pageNumber, &emit);
        foreach (i, hit; results.hits)
        {
            if (i > 0)
                emit("");
            printHit(hit, &emit);
        }

        immutable shown = offset + cast(long) results.hits.length;
        if (results.totalHits > shown)
        {
            immutable remaining = results.totalHits - shown;
            immutable nextPage = pageNumber + 1;
            immutable pageHint = limit == defaultLimit
                ? format("--page %s", nextPage)
                : format("--limit %s --page %s", limit, nextPage);
            emit("");
            emit(console_.dim(format("…and %s more. Use ", formatCount(remaining)))
                                ~ pageHint
                                ~ console_.dim(" to see the next page."));
        }

        page(output.data, options.noPager, console_.terminal, console_.height);
        return ExitCode.ok;
    }

    private enum defaultLimit = 50;

    private static long parseLimit(string text)
    {
        long value;
        try
            value = text.to!long;
        catch (ConvException)
            throw new Exception("invalid --limit value: " ~ text);
        enforce(value >= 1 && value <= 100, "--limit must be between 1 and 100");
        return value;
    }

    private static long parsePage(string text)
    {
        long value;
        try
            value = text.to!long;
        catch (ConvException)
            throw new Exception("invalid --page value: " ~ text);
        enforce(value >= 1, "--page must be at least 1");
        return value;
    }

    private static string[] parseCategories(string[] values)
    {
        string[] categories;
        foreach (value; values)
            foreach (part; value.split(","))
            {
                immutable category = part.strip.toLower;
                if (category.length)
                    categories ~= category;
            }
        return categories;
    }

    private string[][] compatibilityFacets(ScopeConfig config, Kind kind)
    {
        string[][] facets;

        string[] versionGroup;
        versionGroup ~= "versions:" ~ config.gameVersion;
        facets ~= versionGroup;

        string[] loaderGroup;
        foreach (loader; config.loaders)
            loaderGroup ~= "categories:" ~ loader;
        facets ~= loaderGroup;

        string[] typeGroup;
        typeGroup ~= "project_type:" ~ registry_.projectTypeOf(kind);
        facets ~= typeGroup;

        string[] environmentGroup;
        foreach (environment; compatibleEnvironments(config.side))
            environmentGroup ~= "environment:" ~ environment;
        facets ~= environmentGroup;

        return facets;
    }

    private static string[] compatibleEnvironments(Side side)
    {
        string[] result;
        foreach (environment; environments)
        {
            immutable clientOnly = environment == "client_only"
                || environment == "singleplayer_only";
            if (side == Side.client && environment == "dedicated_server_only")
                continue;
            if (side == Side.server && clientOnly)
                continue;
            result ~= environment;
        }
        return result;
    }

    private void printHeader(SearchResults results, SearchOptions options,
        ScopeConfig config, Kind kind, bool haveScope, long limit, long pageNumber,
        void delegate(string) emit)
    {
        immutable count = results.totalHits == results.hits.length
            ? formatCount(results.totalHits)
            : format("%s of %s", formatCount(results.hits.length), formatCount(results.totalHits));
        immutable maxPage = (results.totalHits + limit - 1) / limit;
        if (haveScope)
        {
            string loaderNames;
            foreach (i, loader; config.loaders)
            {
                auto known = registry_.find(loader);
                immutable name = known is null ? loader : known.name;
                loaderNames ~= i == 0 ? name : ", " ~ name;
            }
            emit(console_.bold(format("%s %s for \"%s\"",
                    count, registry_.kindName(kind).toLower, options.query))
                    ~ " " ~ console_.dim(format("(page %s of %s)", pageNumber, maxPage)));
            emit(console_.dim(format("compatible with %s on %s (%s side)",
                    loaderNames, config.gameVersion, config.side.to!string)));
        }
        else
        {
            emit(console_.bold(format("%s packages for \"%s\"", count, options.query))
                    ~ " " ~ console_.dim(format("(page %s of %s)", pageNumber, maxPage)));
        }
        emit("");
    }

    private void printHit(SearchHit hit, void delegate(string) emit)
    {
        immutable url = "https://modrinth.com/project/" ~ hit.projectId ~ "/";

        string line = console_.link(url, console_.green(console_.bold(hit.title)));
        if (hit.slug.length)
            line ~= " (" ~ hit.slug ~ ")";
        line ~= console_.dim(" by " ~ hit.ownerName);
        emit(line);

        string statsLine = console_.dim("⤓ ") ~ formatCount(hit.downloads) ~ console_.dim(" ❤ ") ~ formatCount(hit.follows);
        foreach (category; hit.categories)
            statsLine ~= console_.grey(" · ") ~ console_.dim(category);
        emit(statsLine);

        if (hit.description.length)
            foreach (wrapped; wrapText(hit.description, 80))
                emit(wrapped);
    }

    private static string[] wrapText(string text, size_t width)
    {
        if (width < 20)
            width = 80;

        string[] lines;
        string current;
        foreach (word; text.split(" "))
        {
            if (!current.length)
                current = word;
            else if (current.length + 1 + word.length <= width)
                current ~= " " ~ word;
            else
            {
                lines ~= current;
                current = word;
            }
        }
        if (current.length)
            lines ~= current;
        return lines;
    }

    private static string formatCount(long count)
    {
        if (count >= 1_000_000)
            return trimDecimal(count / 1_000_000.0) ~ "M";
        if (count >= 1_000)
            return trimDecimal(count / 1_000.0) ~ "k";
        return count.to!string;
    }

    private static string trimDecimal(double value)
    {
        string text = format(value >= 10 ? "%.0f" : "%.1f", value);
        if (text.endsWith(".0"))
            text = text[0 .. $ - 2];
        return text;
    }
}
