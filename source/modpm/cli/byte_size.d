module modpm.cli.byte_size;

import std.algorithm.searching : endsWith;
import std.format : format;

final class ByteSize
{
    private enum units = ["B", "KiB", "MiB", "GiB", "TiB"];

    private double value_;
    private size_t unit_;

    this(long bytes)
    {
        value_ = bytes < 0 ? 0 : bytes;
        while (value_ >= 999.95 && unit_ + 1 < units.length)
        {
            value_ /= 1024;
            unit_++;
        }
    }

    string cell() const
    {
        return format("%5.1f %3s", value_, units[unit_]);
    }

    string summary() const
    {
        if (unit_ == 0)
            return format("%.0f B", value_);

        string text = value_ >= 10 ? format("%.0f", value_) : format("%.1f", value_);
        if (text.endsWith(".0"))
            text = text[0 .. $ - 2];
        return text ~ " " ~ units[unit_];
    }
}
