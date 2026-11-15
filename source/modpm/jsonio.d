module modpm.jsonio;

import std.json;

import modpm.atomicfile;

interface JsonSerializable
{
    JSONValue toJson() const;
}

final class JsonObject
{
    private JSONValue value_;

    this()
    {
        value_ = parseJSON("{}");
    }

    JsonObject putString(string key, string value)
    {
        value_[key] = JSONValue(value);
        return this;
    }

    JsonObject putNumber(string key, long value)
    {
        value_[key] = JSONValue(value);
        return this;
    }

    JsonObject putFlag(string key, bool value)
    {
        value_[key] = JSONValue(value);
        return this;
    }

    JsonObject putNull(string key)
    {
        value_[key] = JSONValue(null);
        return this;
    }

    JsonObject putJson(string key, JSONValue value)
    {
        value_[key] = value;
        return this;
    }

    JsonObject putStrings(string key, const(string)[] items)
    {
        value_[key] = stringArray(items);
        return this;
    }

    static JSONValue stringArray(const(string)[] items)
    {
        JSONValue[] values;
        foreach (item; items)
        {
            string text = item;
            values ~= JSONValue(text);
        }
        return JSONValue(values);
    }

    JSONValue build()
    {
        return value_;
    }
}

final class JsonView
{
    private JSONValue value_;

    this(JSONValue value)
    {
        value_ = value;
    }

    static JsonView parse(string text)
    {
        return new JsonView(parseJSON(text));
    }

    bool isObject()
    {
        return value_.type == JSONType.object;
    }

    bool isArray()
    {
        return value_.type == JSONType.array;
    }

    bool isTrue(string key)
    {
        if (isObject)
            if (auto p = key in value_.object)
                return p.type == JSONType.true_;
        return false;
    }

    JsonView child(string key)
    {
        if (isObject)
            if (auto p = key in value_.object)
                return new JsonView(*p);
        return new JsonView(JSONValue(null));
    }

    string str(string key)
    {
        if (isObject)
            if (auto p = key in value_.object)
                if (p.type == JSONType.string)
                    return p.str;
        return "";
    }

    string[] strings(string key)
    {
        string[] result;
        foreach (item; list(key))
        {
            immutable text = item.asString();
            if (text.length)
                result ~= text;
        }
        return result;
    }

    string asString()
    {
        return value_.type == JSONType.string ? value_.str : "";
    }

    JsonView[] items()
    {
        JsonView[] result;
        if (isArray)
            foreach (element; value_.array)
                result ~= new JsonView(element);
        return result;
    }

    JsonView[] list(string key)
    {
        if (isObject)
            if (auto p = key in value_.object)
                return new JsonView(*p).items();
        return null;
    }

    JsonView[string] fields()
    {
        JsonView[string] result;
        if (isObject)
            foreach (key, element; value_.object)
                result[key] = new JsonView(element);
        return result;
    }
}

final class JsonDocument
{
    private JSONValue value_;

    this(JSONValue value)
    {
        value_ = value;
    }

    string render()
    {
        return value_.toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n";
    }

    void save(string path)
    {
        new AtomicFile(path).write(render());
    }
}
