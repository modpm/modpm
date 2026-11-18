module modpm.download;

import core.stdc.config : c_long;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize, remove;
import std.format : format;
import std.stdio : File;
import std.string : toStringz;

import etc.c.curl;

import modpm.hash;

pragma(mangle, "curl_multi_wait")
private extern (C) int multiWait(void* multi, void* extraFds, uint extraCount,
    int timeoutMs, int* fileDescriptors) nothrow;

private enum Opt : int
{
    writeData = 10001,
    url = 10002,
    userAgent = 10018,
    lowSpeedLimit = 19,
    lowSpeedTime = 20,
    followLocation = 52,
    failOnError = 45,
    connectTimeout = 78,
    noSignal = 99,
    writeFunction = 20011,
    resumeFromLarge = 30116,
}

private enum responseCodeInfo = 2097154;

enum JobState
{
    queued,
    active,
    done,
    failed,
}

final class DownloadJob
{
    string versionId;
    string label;
    string url;
    string sha1;
    string partPath;
    long size;
    long received;
    long startOffset;
    size_t index;
    JobState state;
    MonoTime startedAt;
    MonoTime finishedAt;
}

interface DownloadObserver
{
    void update(DownloadJob[] jobs);

    void finish();
}

private final class Transfer
{
    DownloadJob job;
    void* handle;
    File file;
    int attempt;
    MonoTime notBefore;

    this(DownloadJob job)
    {
        this.job = job;
    }
}

private extern (C) size_t onWrite(char* data, size_t size, size_t count, void* userdata) nothrow
{
    auto transfer = cast(Transfer) userdata;
    immutable bytes = size * count;
    try
    {
        transfer.file.rawWrite(data[0 .. bytes]);
        transfer.job.received += bytes;
    }
    catch (Throwable)
        return 0;
    return bytes;
}

final class Downloader
{
    private enum maxParallel = 8;
    private enum maxAttempts = 4;

    private string userAgent_;
    private FileHasher hasher_;
    private DownloadObserver observer_;

    this(string userAgent, FileHasher hasher, DownloadObserver observer)
    {
        userAgent_ = userAgent;
        hasher_ = hasher;
        observer_ = observer;
        curl_global_init(cast(c_long) 3);
    }

    void download(DownloadJob[] jobs)
    {
        Transfer[] queue;
        foreach (i, job; jobs)
        {
            job.index = i + 1;
            if (alreadyComplete(job))
                job.state = JobState.done;
            else
                queue ~= new Transfer(job);
        }
        if (queue.length == 0)
        {
            observer_.update(jobs);
            observer_.finish();
            return;
        }

        auto multi = curl_multi_init();
        enforce(multi !is null, "cannot start libcurl");
        scope (exit)
            curl_multi_cleanup(multi);

        Transfer[size_t] active;
        string[] failures;

        while (queue.length || active.length)
        {
            startReady(multi, queue, active);

            int running;
            curl_multi_perform(multi, &running);
            collectFinished(multi, queue, active, failures);
            observer_.update(jobs);

            if (active.length)
            {
                int descriptors;
                multiWait(multi, null, 0, 100, &descriptors);
            }
            else if (queue.length)
                Thread.sleep(50.msecs);
        }

        observer_.finish();
        enforce(failures.length == 0, failures.join("\n"));
    }

    private bool alreadyComplete(DownloadJob job)
    {
        if (!exists(job.partPath))
            return false;

        immutable size = getSize(job.partPath);
        if (job.size > 0 && size > job.size)
        {
            remove(job.partPath);
            return false;
        }
        if (hasher_.sha1(job.partPath) == job.sha1)
        {
            job.received = size;
            return true;
        }
        if (job.size > 0 && size == job.size)
            remove(job.partPath);
        return false;
    }

    private void startReady(void* multi, ref Transfer[] queue, ref Transfer[size_t] active)
    {
        while (active.length < maxParallel)
        {
            ptrdiff_t index = -1;
            foreach (i, transfer; queue)
                if (transfer.notBefore <= MonoTime.currTime)
                {
                    index = i;
                    break;
                }
            if (index < 0)
                return;

            auto transfer = queue[index];
            queue = queue[0 .. index] ~ queue[index + 1 .. $];
            begin(multi, transfer, active);
        }
    }

    private void begin(void* multi, Transfer transfer, ref Transfer[size_t] active)
    {
        auto job = transfer.job;
        immutable offset = exists(job.partPath) ? getSize(job.partPath) : 0;
        transfer.file = File(job.partPath, offset > 0 ? "ab" : "wb");
        job.received = offset;
        if (job.state != JobState.active)
        {
            job.state = JobState.active;
            job.startedAt = MonoTime.currTime;
            job.startOffset = offset;
        }

        auto handle = curl_easy_init();
        enforce(handle !is null, "cannot start a libcurl transfer");
        curl_easy_setopt(handle, cast(CurlOption) Opt.url, job.url.toStringz);
        curl_easy_setopt(handle, cast(CurlOption) Opt.userAgent, userAgent_.toStringz);
        curl_easy_setopt(handle, cast(CurlOption) Opt.writeFunction, &onWrite);
        curl_easy_setopt(handle, cast(CurlOption) Opt.writeData, cast(void*) transfer);
        curl_easy_setopt(handle, cast(CurlOption) Opt.followLocation, cast(c_long) 1);
        curl_easy_setopt(handle, cast(CurlOption) Opt.failOnError, cast(c_long) 1);
        curl_easy_setopt(handle, cast(CurlOption) Opt.noSignal, cast(c_long) 1);
        curl_easy_setopt(handle, cast(CurlOption) Opt.connectTimeout, cast(c_long) 15);
        curl_easy_setopt(handle, cast(CurlOption) Opt.lowSpeedLimit, cast(c_long) 1024);
        curl_easy_setopt(handle, cast(CurlOption) Opt.lowSpeedTime, cast(c_long) 30);
        if (offset > 0)
            curl_easy_setopt(handle, cast(CurlOption) Opt.resumeFromLarge, cast(long) offset);

        transfer.handle = handle;
        curl_multi_add_handle(multi, handle);
        active[cast(size_t) handle] = transfer;
    }

    private void collectFinished(void* multi, ref Transfer[] queue,
        ref Transfer[size_t] active, ref string[] failures)
    {
        int remaining;
        while (true)
        {
            auto message = curl_multi_info_read(multi, &remaining);
            if (message is null)
                break;
            if (cast(int) message.msg != 1)
                continue;

            immutable key = cast(size_t) message.easy_handle;
            auto transfer = active[key];
            immutable code = cast(int) message.data.result;
            c_long httpStatus;
            curl_easy_getinfo(transfer.handle, cast(CurlInfo) responseCodeInfo, &httpStatus);

            active.remove(key);
            curl_multi_remove_handle(multi, transfer.handle);
            curl_easy_cleanup(transfer.handle);
            transfer.file.close();
            settle(transfer, code, cast(int) httpStatus, queue, failures);
        }
    }

    private void settle(Transfer transfer, int code, int httpStatus,
        ref Transfer[] queue, ref string[] failures)
    {
        auto job = transfer.job;
        string error;
        if (code == 0)
        {
            if (hasher_.sha1(job.partPath) == job.sha1)
            {
                job.state = JobState.done;
                job.finishedAt = MonoTime.currTime;
                return;
            }
            remove(job.partPath);
            error = "the downloaded file is corrupt";
        }
        else
        {
            error = describe(code, httpStatus);
            if (!transient(code) && exists(job.partPath))
                remove(job.partPath);
        }

        if (++transfer.attempt < maxAttempts)
        {
            transfer.notBefore = MonoTime.currTime + (500 << (transfer.attempt - 1)).msecs;
            queue ~= transfer;
        }
        else
        {
            job.state = JobState.failed;
            failures ~= format("%s: %s", job.label, error);
        }
    }

    private static bool transient(int code)
    {
        switch (code)
        {
        case 6:
        case 7:
        case 18:
        case 28:
        case 35:
        case 52:
        case 55:
        case 56:
            return true;
        default:
            return false;
        }
    }

    private static string describe(int code, int httpStatus)
    {
        switch (code)
        {
        case 6:
            return "couldn't resolve the host";
        case 7:
            return "couldn't connect";
        case 22:
            return format("the server answered HTTP %d", httpStatus);
        case 28:
            return "the connection timed out";
        case 33:
            return "the server doesn't support resuming";
        default:
            return format("download failed (libcurl error %d)", code);
        }
    }
}
