module modpm.cli.suggestion_notice;

import std.array : join, replace;
import std.format : format;
import std.uni : toLower;

import modpm.cli.console;
import modpm.loaders;
import modpm.transaction;

final class SuggestionNotice
{
    private Console console_;
    private LoaderRegistry registry_;

    this(Console console, LoaderRegistry registry)
    {
        console_ = console;
        registry_ = registry;
    }

    void print(Transaction transaction, Kind kind)
    {
        if (transaction.suggestions.length == 0)
            return;

        string[] specs;
        bool[string] seen;
        foreach (suggestion; transaction.suggestions)
        {
            console_.line();
            console_.line(format("%s %s suggests these optional %s:", suggestion.title,
                    suggestion.versionNumber, registry_.kindName(kind).toLower));
            foreach (item; suggestion.optional)
            {
                immutable spec = item.versionNumber.length ? item.slug ~ "@" ~ item.versionNumber
                    : item.slug;
                console_.line("  " ~ item.title
                        ~ (item.versionNumber.length ? " " ~ item.versionNumber : "")
                        ~ " " ~ console_.dim("(" ~ spec ~ ")"));
                if (item.slug !in seen)
                {
                    seen[item.slug] = true;
                    specs ~= shellQuote(spec);
                }
            }
        }
        console_.line();
        console_.line("Install all with: modpm install " ~ specs.join(" "));
    }

    private static string shellQuote(string spec)
    {
        bool safe = spec.length > 0;
        foreach (c; spec)
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                    || c == '.' || c == '_' || c == '-' || c == '+' || c == '@' || c == ':'))
                safe = false;
        return safe ? spec : "'" ~ spec.replace("'", "'\\''") ~ "'";
    }
}
