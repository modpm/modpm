module modpm.orphans;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;

import modpm.manifest;

final class OrphanFinder
{
    string[] find(Manifest state, Entry[] gone, bool[string] skip)
    {
        string[] found;
        Entry[] queue = gone.dup;
        for (size_t i = 0; i < queue.length; i++)
        {
            foreach (projectId; referencesOf(queue[i]))
            {
                if (projectId in skip)
                    continue;
                auto entry = projectId in state.installed;
                if (entry is null || (*entry).reason != "dependency" || (*entry).frozen)
                    continue;
                if (isReferenced(state, projectId))
                    continue;

                found ~= projectId;
                queue ~= *entry;
                state.installed.remove(projectId);
            }
        }
        found.sort();
        return found;
    }

    private static string[] referencesOf(Entry entry)
    {
        string[] ids = entry.requires.keys;
        foreach (projectId; entry.suggests)
            if (!ids.canFind(projectId))
                ids ~= projectId;
        return ids;
    }

    private static bool isReferenced(Manifest state, string projectId)
    {
        foreach (otherId, other; state.installed)
            if (projectId in other.requires || other.suggests.canFind(projectId))
                return true;
        return false;
    }
}
