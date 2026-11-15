module modpm.side;

enum Side
{
    client,
    server,
}

final class EnvironmentPolicy
{
    private const Side side_;

    this(Side side) pure nothrow @safe
    {
        side_ = side;
    }

    bool accepts(string environment) const pure nothrow @safe
    {
        switch (environment)
        {
        case "client_only":
        case "singleplayer_only":
            return side_ == Side.client;
        case "dedicated_server_only":
            return side_ == Side.server;
        default:
            return true;
        }
    }
}
