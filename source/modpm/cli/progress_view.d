module modpm.cli.progress_view;

import core.time : MonoTime, msecs;
import std.algorithm.comparison : max, min;
import std.array : replicate;
import std.conv : to;
import std.format : format;
import std.utf : count;

import modpm.cli.byte_size;
import modpm.cli.console;
import modpm.download;

private struct Sample
{
    MonoTime time;
    long bytes;
    double rate = 0;
}

final class ProgressView : DownloadObserver
{
    private enum barWidth = 17;
    private enum progressWidth = 22;
    private enum rateWidth = 11;
    private enum sizeWidth = 9;
    private enum clearLine = "\r\x1b[2K";

    private Console console_;
    private DownloadJob[] jobs_;
    private Sample[DownloadJob] samples_;
    private size_t nextPrint_;
    private size_t live_;
    private size_t nameWidth_;
    private size_t countWidth_;
    private size_t lastStarted_;
    private size_t lastDone_;
    private MonoTime lastDraw_;

    this(Console console)
    {
        console_ = console;
    }

    void update(DownloadJob[] jobs)
    {
        if (jobs.length == 0)
            return;
        if (jobs_.length == 0)
            begin(jobs);

        immutable now = MonoTime.currTime;
        if (!console_.terminal)
        {
            printInOrder(now, false);
            return;
        }

        size_t started = 0;
        size_t done = 0;
        foreach (job; jobs)
        {
            if (job.state != JobState.queued)
                started++;
            if (finished(job))
                done++;
        }
        immutable changed = started != lastStarted_ || done != lastDone_;
        if (!changed && now - lastDraw_ < 100.msecs)
            return;

        lastStarted_ = started;
        lastDone_ = done;
        lastDraw_ = now;
        draw(now, false);
    }

    void finish()
    {
        if (jobs_.length == 0)
            return;

        immutable now = MonoTime.currTime;
        if (console_.terminal)
            draw(now, true);
        else
            printInOrder(now, true);
    }

    private void begin(DownloadJob[] jobs)
    {
        jobs_ = jobs;
        countWidth_ = jobs.length.to!string.length;
        immutable prefixWidth = 1 + countWidth_ + 1 + jobs.length.to!string.length + 2;
        immutable fixed = prefixWidth + 1 + progressWidth + 3 + rateWidth + 3 + sizeWidth;
        nameWidth_ = max(5, console_.width > fixed ? console_.width - fixed : 0);
    }

    private void draw(MonoTime now, bool last)
    {
        string frame = live_ ? format("\x1b[%dA", live_) : "";
        while (nextPrint_ < jobs_.length && (last || finished(jobs_[nextPrint_])))
        {
            frame ~= clearLine ~ line(jobs_[nextPrint_], now) ~ "\n";
            nextPrint_++;
        }

        size_t shown = 0;
        if (last)
            frame ~= "\x1b[J";
        else
        {
            auto visible = visibleJobs();
            foreach (job; visible)
                frame ~= clearLine ~ line(job, now) ~ "\n";
            shown = visible.length;
            frame ~= clearLine ~ separator() ~ "\n" ~ clearLine ~ totalLine(now) ~ "\n" ~ "\x1b[J";
        }
        console_.write(frame);
        live_ = last ? 0 : shown + 2;
    }

    private DownloadJob[] visibleJobs()
    {
        DownloadJob[] waiting;
        size_t active = 0;
        foreach (job; jobs_[nextPrint_ .. $])
        {
            if (job.state == JobState.active)
                active++;
            if (job.state != JobState.queued)
                waiting ~= job;
        }

        immutable height = console_.height;
        immutable room = height > 10 ? height - 6 : 4;
        if (waiting.length <= room)
            return waiting;

        immutable keepFinished = room > active ? room - active : 0;
        immutable finishedCount = waiting.length - active;
        size_t toDrop = finishedCount > keepFinished ? finishedCount - keepFinished : 0;
        DownloadJob[] kept;
        foreach (job; waiting)
        {
            if (job.state != JobState.active && toDrop > 0)
            {
                toDrop--;
                continue;
            }
            kept ~= job;
        }
        return kept;
    }

    private void printInOrder(MonoTime now, bool all)
    {
        while (nextPrint_ < jobs_.length && (all || finished(jobs_[nextPrint_])))
        {
            console_.line(line(jobs_[nextPrint_], now));
            nextPrint_++;
        }
    }

    private string line(DownloadJob job, MonoTime now)
    {
        return counter(job.index) ~ fit(job.label) ~ " " ~ progressCell(job) ~ " | "
            ~ rateCell(job, now) ~ " | " ~ new ByteSize(job.received).cell;
    }

    private string totalLine(MonoTime now)
    {
        long received = 0;
        long size = 0;
        size_t done = 0;
        foreach (job; jobs_)
        {
            received += job.received;
            size += job.size;
            if (job.state == JobState.done)
                done++;
        }

        return counter(done) ~ fit("Total") ~ " " ~ bar(received, size) ~ " "
            ~ right(percent(received, size), 4) ~ " | " ~ totalRateCell() ~ " | "
            ~ new ByteSize(received).cell;
    }

    private string separator()
    {
        immutable prefixWidth = 1 + countWidth_ + 1 + jobs_.length.to!string.length + 2;
        return "-".replicate(prefixWidth + nameWidth_ + 1 + progressWidth + 3 + rateWidth
                + 3 + sizeWidth);
    }

    private string counter(size_t number)
    {
        return "[" ~ right(number.to!string, countWidth_) ~ "/" ~ jobs_.length.to!string ~ "] ";
    }

    private string fit(string label)
    {
        immutable shown = label.count > nameWidth_ ? label[0 .. nameWidth_] : label;
        return shown ~ " ".replicate(nameWidth_ - shown.count);
    }

    private string progressCell(DownloadJob job)
    {
        if (job.state == JobState.done)
            return right("100%", progressWidth);
        if (job.state == JobState.failed)
            return " ".replicate(progressWidth - 6) ~ console_.red("failed");
        if (job.size <= 0)
            return right("...", progressWidth);
        return bar(job.received, job.size) ~ " " ~ right(percent(job.received, job.size), 4);
    }

    private string bar(long received, long size)
    {
        immutable fraction = size > 0 ? min(1.0, cast(double) received / size) : 0.0;
        immutable halves = cast(size_t)(fraction * barWidth * 2 + 0.5);
        immutable full = halves / 2;
        immutable half = halves % 2;
        return console_.green("━".replicate(full) ~ (half ? "╸" : ""))
            ~ console_.dim("─".replicate(barWidth - full - half));
    }

    private static string percent(long received, long size)
    {
        immutable fraction = size > 0 ? min(1.0, cast(double) received / size) : 0.0;
        return format("%d%%", cast(int)(fraction * 100));
    }

    private string rateCell(DownloadJob job, MonoTime now)
    {
        double rate;
        if (job.state == JobState.active)
            rate = smoothedRate(job, now);
        else if (job.startedAt == MonoTime.zero)
            return right("-", rateWidth);
        else
        {
            immutable seconds = (job.finishedAt - job.startedAt).total!"usecs" / 1_000_000.0;
            rate = seconds > 0 ? (job.received - job.startOffset) / seconds : 0;
        }
        return new ByteSize(cast(long) rate).cell ~ "/s";
    }

    private string totalRateCell()
    {
        double rate = 0;
        foreach (job; jobs_)
            if (job.state == JobState.active)
                rate += samples_.get(job, Sample.init).rate;
        return new ByteSize(cast(long) rate).cell ~ "/s";
    }

    private double smoothedRate(DownloadJob job, MonoTime now)
    {
        auto sample = samples_.get(job, Sample(job.startedAt, job.received, 0));
        immutable seconds = (now - sample.time).total!"usecs" / 1_000_000.0;
        if (seconds >= 0.25)
        {
            immutable instant = (job.received - sample.bytes) / seconds;
            sample.rate = sample.rate == 0 ? instant : 0.5 * sample.rate + 0.5 * instant;
            sample.time = now;
            sample.bytes = job.received;
        }
        samples_[job] = sample;
        return sample.rate;
    }

    private static bool finished(DownloadJob job)
    {
        return job.state == JobState.done || job.state == JobState.failed;
    }

    private static string right(string text, size_t width)
    {
        return " ".replicate(width - text.count) ~ text;
    }
}
