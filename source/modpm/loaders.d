module modpm.loaders;

import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.traits : EnumMembers;
import std.uni : toLower;

import modpm.side;

enum Kind
{
    mod,
    plugin,
    datapack,
    resourcepack,
    shader,
}

final class Loader
{
    immutable string id;
    immutable string name;
    immutable Kind kind;

    this(string id, string name, Kind kind) pure nothrow @safe
    {
        this.id = id;
        this.name = name;
        this.kind = kind;
    }
}

final class LoaderRegistry
{
    private Loader[] loaders_;

    this()
    {
        this(defaultLoaders());
    }

    this(Loader[] loaders)
    {
        loaders_ = loaders;
    }

    private static Loader[] defaultLoaders()
    {
        return [
            new Loader("babric", "Babric", Kind.mod),
            new Loader("bta-babric", "BTA (Babric)", Kind.mod),
            new Loader("bukkit", "Bukkit", Kind.plugin),
            new Loader("bungeecord", "BungeeCord", Kind.plugin),
            new Loader("canvas", "Canvas", Kind.shader),
            new Loader("datapack", "Data Pack", Kind.datapack),
            new Loader("fabric", "Fabric", Kind.mod),
            new Loader("folia", "Folia", Kind.plugin),
            new Loader("forge", "Forge", Kind.mod),
            new Loader("geyser", "Geyser", Kind.plugin),
            new Loader("iris", "Iris", Kind.shader),
            new Loader("java-agent", "Java Agent", Kind.mod),
            new Loader("legacy-fabric", "Legacy Fabric", Kind.mod),
            new Loader("liteloader", "LiteLoader", Kind.mod),
            new Loader("minecraft", "Minecraft", Kind.resourcepack),
            new Loader("modloader", "ModLoader", Kind.mod),
            new Loader("neoforge", "NeoForge", Kind.mod),
            new Loader("nilloader", "NilLoader", Kind.mod),
            new Loader("optifine", "OptiFine", Kind.shader),
            new Loader("ornithe", "Ornithe", Kind.mod),
            new Loader("paper", "Paper", Kind.plugin),
            new Loader("purpur", "Purpur", Kind.plugin),
            new Loader("quilt", "Quilt", Kind.mod),
            new Loader("rift", "Rift", Kind.mod),
            new Loader("spigot", "Spigot", Kind.plugin),
            new Loader("sponge", "Sponge", Kind.plugin),
            new Loader("vanilla", "Vanilla", Kind.shader),
            new Loader("velocity", "Velocity", Kind.plugin),
            new Loader("waterfall", "Waterfall", Kind.plugin),
        ];
    }

    Loader find(string id)
    {
        foreach (loader; loaders_)
            if (loader.id == id)
                return loader;
        return null;
    }

    Loader[] ofKind(Kind kind)
    {
        Loader[] result;
        foreach (loader; loaders_)
            if (loader.kind == kind)
                result ~= loader;
        result.sort!((a, b) => a.name.toLower < b.name.toLower);
        return result;
    }

    Kind[] kinds() const pure nothrow @safe
    {
        return [EnumMembers!Kind];
    }

    string kindName(Kind kind) const pure nothrow @safe
    {
        final switch (kind)
        {
        case Kind.mod:
            return "Mods";
        case Kind.plugin:
            return "Plugins";
        case Kind.datapack:
            return "Data packs";
        case Kind.resourcepack:
            return "Resource packs";
        case Kind.shader:
            return "Shaders";
        }
    }

    string singularName(Kind kind) const pure nothrow @safe
    {
        final switch (kind)
        {
        case Kind.mod:
            return "Mod";
        case Kind.plugin:
            return "Plugin";
        case Kind.datapack:
            return "Data pack";
        case Kind.resourcepack:
            return "Resource pack";
        case Kind.shader:
            return "Shader";
        }
    }

    string projectTypeOf(Kind kind) const pure nothrow @safe
    {
        final switch (kind)
        {
        case Kind.mod:
            return "mod";
        case Kind.plugin:
            return "plugin";
        case Kind.datapack:
            return "datapack";
        case Kind.resourcepack:
            return "resourcepack";
        case Kind.shader:
            return "shader";
        }
    }

    string extensionOf(Kind kind) const pure nothrow @safe
    {
        final switch (kind)
        {
        case Kind.mod:
        case Kind.plugin:
            return ".jar";
        case Kind.datapack:
        case Kind.resourcepack:
        case Kind.shader:
            return ".zip";
        }
    }

    immutable(Side)[] sidesOf(Kind kind) const pure nothrow @safe
    {
        final switch (kind)
        {
        case Kind.mod:
            return [Side.client, Side.server];
        case Kind.plugin:
        case Kind.datapack:
            return [Side.server];
        case Kind.resourcepack:
        case Kind.shader:
            return [Side.client];
        }
    }

    Kind scopeKind(const(string)[] loaderIds)
    {
        foreach (id; loaderIds)
            if (auto loader = find(id))
                return loader.kind;
        return Kind.mod;
    }

    Kind kindOf(const(string)[] loaderIds)
    {
        enforce(loaderIds.length > 0, "no loaders given");

        Kind kind;
        foreach (i, id; loaderIds)
        {
            auto loader = find(id);
            enforce(loader !is null, "unknown loader: " ~ id);
            enforce(i == 0 || loader.kind == kind, "loaders belong to different kinds");
            kind = loader.kind;
        }
        return kind;
    }
}
