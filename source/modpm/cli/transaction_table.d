module modpm.cli.transaction_table;

import std.algorithm.comparison : max;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.conv : to;
import std.uni : toLower;
import std.utf : count;

import modpm.cli.byte_size;
import modpm.cli.console;

enum noChannel = "-";

final class TableRow
{
    string title;
    string projectId;
    string versionNumber;
    string channel = noChannel;
    long size = -1;

    bool replaces;
    string previousTitle;
    string previousVersion;
    string previousChannel = noChannel;
    long previousSize = -1;
}

private final class Section
{
    string header;
    TableRow[] rows;
    bool removal;
}

final class TransactionTable
{
    private enum sizeWidth = 9;
    private enum replacingPrefix = "  replacing ";

    private Console console_;
    private bool showChannel_;
    private Section[] sections_;
    private size_t versionWidth_;
    private size_t channelWidth_;

    this(Console console)
    {
        console_ = console;
    }

    void add(string header, TableRow[] rows, bool removal = false)
    {
        if (rows.length == 0)
            return;

        rows.sort!((a, b) => a.title.toLower < b.title.toLower);
        auto section = new Section();
        section.header = header;
        section.rows = rows;
        section.removal = removal;
        sections_ ~= section;
    }

    void print()
    {
        showChannel_ = false;
        foreach (section; sections_)
            foreach (row; section.rows)
                if (row.channel != noChannel || (row.replaces && row.previousChannel != noChannel))
                    showChannel_ = true;

        size_t nameWidth = 7;
        versionWidth_ = 7;
        channelWidth_ = showChannel_ ? 7 : 0;
        foreach (section; sections_)
        {
            foreach (row; section.rows)
            {
                nameWidth = max(nameWidth, row.title.count);
                versionWidth_ = max(versionWidth_, row.versionNumber.count);
                channelWidth_ = max(channelWidth_, showChannel_ ? row.channel.count : 0);
                if (row.replaces)
                {
                    nameWidth = max(nameWidth, replacingPrefix.count + row.previousTitle.count);
                    versionWidth_ = max(versionWidth_, row.previousVersion.count);
                    channelWidth_ = max(channelWidth_, showChannel_ ? row.previousChannel.count : 0);
                }
            }
        }

        immutable fixed = 1 + 2 + versionWidth_ + (showChannel_ ? 2 + channelWidth_ : 0)
            + 2 + sizeWidth;
        nameWidth = max(nameWidth, console_.width > fixed ? console_.width - fixed : 0);

        console_.line(console_.bold(left("Package", nameWidth + 1)) ~ "  "
                ~ console_.bold(left("Version", versionWidth_))
                ~ (showChannel_ ? "  " ~ console_.bold(left("Channel", channelWidth_)) : "")
                ~ "  " ~ console_.bold(right("Size", sizeWidth)));

        foreach (section; sections_)
        {
            console_.line(section.header);
            foreach (row; section.rows)
            {
                immutable url = "https://modrinth.com/project/" ~ row.projectId ~ "/";
                immutable name = section.removal ? console_.red(row.title)
                    : console_.link(url, console_.green(row.title));
                console_.line(" " ~ name ~ " ".replicate(nameWidth - row.title.count)
                        ~ rest(row.versionNumber, row.channel, row.size));
                if (row.replaces)
                    console_.line(console_.dim(" " ~ left(replacingPrefix ~ row.previousTitle, nameWidth)
                            ~ rest(row.previousVersion, row.previousChannel, row.previousSize)));
            }
        }
        console_.line();
    }

    private string rest(string versionNumber, string channel, long size)
    {
        return "  " ~ left(versionNumber, versionWidth_)
            ~ (showChannel_ ? "  " ~ left(channel, channelWidth_) : "")
            ~ "  " ~ right(size < 0 ? "-" : new ByteSize(size).cell, sizeWidth);
    }

    private static string left(string text, size_t width)
    {
        return text ~ " ".replicate(width - text.count);
    }

    private static string right(string text, size_t width)
    {
        return " ".replicate(width - text.count) ~ text;
    }
}

final class TransactionSummary
{
    private Console console_;
    private string[] labels_;
    private size_t[] counts_;

    this(Console console)
    {
        console_ = console;
    }

    void add(string label, size_t number)
    {
        if (number == 0)
            return;
        labels_ ~= label;
        counts_ ~= number;
    }

    void print()
    {
        size_t labelWidth = 0;
        size_t countWidth = 0;
        foreach (i, label; labels_)
        {
            labelWidth = max(labelWidth, label.length);
            countWidth = max(countWidth, counts_[i].to!string.length);
        }

        console_.line(console_.bold("Transaction Summary:"));
        foreach (i, label; labels_)
        {
            immutable number = counts_[i].to!string;
            console_.line(" " ~ label ~ " ".replicate(labelWidth + 2 - label.length)
                    ~ " ".replicate(countWidth - number.length) ~ number
                    ~ (counts_[i] == 1 ? " package" : " packages"));
        }
    }
}
