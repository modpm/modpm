module modpm.transaction;

import std.file : readText;
import std.json : JSONValue;

import modpm.jsonio;
import modpm.manifest;

final class Operation : JsonSerializable
{
    string projectId;
    Entry from;
    Entry to;

    this(string projectId, Entry from, Entry to)
    {
        this.projectId = projectId;
        this.from = from;
        this.to = to;
    }

    @property bool placesFile() const
    {
        return to !is null && (from is null || from.versionId != to.versionId);
    }

    @property bool removesOldFile() const
    {
        return from !is null && (to is null || from.filename != to.filename);
    }

    static Operation fromJson(JsonView json)
    {
        auto before = json.child("from");
        auto after = json.child("to");
        return new Operation(json.str("project_id"),
            before.isObject ? Entry.fromJson(before) : null,
            after.isObject ? Entry.fromJson(after) : null);
    }

    JSONValue toJson() const
    {
        auto json = new JsonObject().putString("project_id", projectId);
        if (from !is null)
            json.putJson("from", from.toJson());
        else
            json.putNull("from");
        if (to !is null)
            json.putJson("to", to.toJson());
        else
            json.putNull("to");
        return json.build();
    }
}

final class OptionalPackage
{
    string slug;
    string title;
    string versionNumber;

    static OptionalPackage fromJson(JsonView json)
    {
        auto item = new OptionalPackage();
        item.slug = json.str("slug");
        item.title = json.str("title");
        item.versionNumber = json.str("version_number");
        return item;
    }

    JSONValue toJson() const
    {
        auto json = new JsonObject().putString("slug", slug).putString("title", title);
        if (versionNumber.length)
            json.putString("version_number", versionNumber);
        return json.build();
    }
}

final class Suggestion
{
    string title;
    string versionNumber;
    OptionalPackage[] optional;

    static Suggestion fromJson(JsonView json)
    {
        auto suggestion = new Suggestion();
        suggestion.title = json.str("title");
        suggestion.versionNumber = json.str("version_number");
        foreach (item; json.list("optional"))
            suggestion.optional ~= OptionalPackage.fromJson(item);
        return suggestion;
    }

    JSONValue toJson() const
    {
        JSONValue[] items;
        foreach (item; optional)
            items ~= item.toJson();
        return new JsonObject()
            .putString("title", title)
            .putString("version_number", versionNumber)
            .putJson("optional", JSONValue(items))
            .build();
    }
}

final class Transaction : JsonSerializable
{
    long id;
    Operation[] operations;
    string[] applied;
    Suggestion[] suggestions;

    static Transaction fromJson(JsonView json)
    {
        auto transaction = new Transaction();
        transaction.id = json.integer("id");
        foreach (operation; json.list("operations"))
            transaction.operations ~= Operation.fromJson(operation);
        transaction.applied = json.strings("applied");
        foreach (suggestion; json.list("suggestions"))
            transaction.suggestions ~= Suggestion.fromJson(suggestion);
        return transaction;
    }

    static Transaction load(string path)
    {
        return fromJson(JsonView.parse(readText(path)));
    }

    JSONValue toJson() const
    {
        return new JsonObject()
            .putNumber("id", id)
            .putJson("operations", operationsJson())
            .putStrings("applied", applied)
            .putJson("suggestions", suggestionsJson())
            .build();
    }

    JSONValue toHistoryJson(string time) const
    {
        return new JsonObject()
            .putNumber("id", id)
            .putString("time", time)
            .putJson("operations", operationsJson())
            .build();
    }

    void save(string path)
    {
        new JsonDocument(toJson()).save(path);
    }

    private JSONValue suggestionsJson() const
    {
        JSONValue[] values;
        foreach (suggestion; suggestions)
            values ~= suggestion.toJson();
        return JSONValue(values);
    }

    private JSONValue operationsJson() const
    {
        JSONValue[] values;
        foreach (operation; operations)
            values ~= operation.toJson();
        return JSONValue(values);
    }
}
