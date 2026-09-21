# Search Selection Learning — Specs

Search learning maps one normalized query to one application bundle identifier. It never adds a search
result: ordering may promote the learned application only when that application's window already matches
the query and survives the active shortcut slot's filters.

- Explicit keyboard selection followed by focus records or replaces a mapping.
- A direct tile click is explicit even when hover selection is disabled.
- Accepting an already-learned default touches its last-used time; accepting an untouched unlearned default
  records nothing.
- Records expire after 180 unused days and are capped at 100 normalized queries using LRU eviction.
- Queries longer than 64 normalized characters and applications without bundle identifiers are not learned.
- Corrupt persisted rows are discarded independently.
- The in-memory query lookup is constant-time. Persistence is deferred until after the focus/dismissal turn
  and preference notifications for this key only reload this cache.
