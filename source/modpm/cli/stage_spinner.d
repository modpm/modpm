module modpm.cli.stage_spinner;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs;
import std.format : format;

import modpm.cli.console;
import modpm.planner;

final class StageSpinner : PlanObserver
{
    private enum frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    private enum hideCursor = "\x1b[?25l";
    private enum showCursor = "\x1b[?25h";
    private enum clearLine = "\r\x1b[2K";

    private Console console_;
    private Thread thread_;
    private shared bool running_;
    private string active_;
    private string done_;
    private MonoTime started_;

    this(Console console)
    {
        console_ = console;
    }

    void begin(string active, string done)
    {
        halt();
        active_ = active;
        done_ = done;
        started_ = MonoTime.currTime;
        if (!console_.terminal)
            return;

        atomicStore(running_, true);
        console_.write(hideCursor);
        thread_ = new Thread(&spin);
        thread_.start();
    }

    void end()
    {
        immutable elapsed = MonoTime.currTime - started_;
        halt();
        immutable time = "(" ~ duration(elapsed) ~ ")";
        console_.line(done_ ~ ". " ~ (console_.terminal ? console_.dim(time) : time));
    }

    void abort()
    {
        halt();
    }

    private void halt()
    {
        if (thread_ is null)
            return;

        atomicStore(running_, false);
        thread_.join();
        thread_ = null;
        console_.write(clearLine ~ showCursor);
    }

    private void spin()
    {
        size_t frame = 0;
        while (atomicLoad(running_))
        {
            console_.write(clearLine ~ console_.dim(frames[frame % frames.length]) ~ " "
                    ~ active_ ~ "...");
            frame++;
            Thread.sleep(80.msecs);
        }
    }

    private static string duration(Duration elapsed)
    {
        immutable ms = elapsed.total!"msecs";
        if (ms < 100)
            return "<0.1s";
        if (ms < 1000)
            return format("%.1fs", ms / 1000.0);
        immutable seconds = ms / 1000;
        if (seconds < 60)
            return format("%ds", seconds);
        return format("%dm %ds", seconds / 60, seconds % 60);
    }
}
