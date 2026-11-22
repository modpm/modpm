module modpm.cli.search_cmd;

import std.array : join;
import std.file : getcwd;

import cmd.command;
import cmd.parsed_args;

import modpm.cli.search_flow;

final class SearchCommand : Command
{
    private SearchFlow flow_;

    this(SearchFlow flow)
    {
        super("search")
            .description("Search Modrinth for packages compatible with this scope")
            .argument("<terms...>", "Search terms")
            .option("--limit [count]", "Maximum number of results per page", "50")
            .option("--page [number]", "Page of results to show", "1")
            .option("--sort [criterion]", "Sort results by: relevance, downloads, follows, newest, updated")
            .option("--category [name]", "Only show results in the given category, e.g. optimization; repeatable and comma-separated")
            .option("--no-pager", "Print all results without paging")
            .action(&execute);
        flow_ = flow;
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
        return flow_.run(options, getcwd());
    }
}
