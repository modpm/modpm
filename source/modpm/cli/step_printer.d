module modpm.cli.step_printer;

import std.algorithm.comparison : max;
import std.array : replicate;
import std.conv : to;
import std.utf : count;

import modpm.cli.byte_size;
import modpm.cli.console;
import modpm.runner;

final class StepPrinter : TransactionObserver
{
    private Console console_;
    private string[] steps_;
    private size_t done_;
    private size_t width_;

    this(Console console)
    {
        console_ = console;
    }

    void begin(string[] steps)
    {
        steps_ = steps;
        done_ = 0;
        width_ = 0;
        foreach (step; steps)
            width_ = max(width_, step.count);
        immutable fixed = 2 * steps.length.to!string.length + 4 + 9 + 9;
        width_ = max(width_, console_.width > fixed ? console_.width - fixed : 0);

        console_.line();
        console_.line("Running transaction");
    }

    void completed(long bytes)
    {
        if (done_ >= steps_.length)
            return;

        immutable total = steps_.length.to!string;
        immutable number = (done_ + 1).to!string;
        immutable step = steps_[done_];
        immutable size = bytes < 0 ? "-" : new ByteSize(bytes).cell;
        console_.line("[" ~ " ".replicate(total.length - number.length) ~ number ~ "/" ~ total ~ "] "
                ~ step ~ " ".replicate(width_ - step.count) ~ "  100% | "
                ~ " ".replicate(9 - size.count) ~ size);
        done_++;
    }
}
