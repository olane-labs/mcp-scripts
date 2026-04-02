<!-- Copass:START -->

## Copass — Ontology knowledge graph

Copass context is automatically injected via hook on every message. Use it to scope your work.

- If you need deeper context, call `context_query` with `detail_level: "detailed"` or `search_entities`
- For planning/architecture, call `get_score` first to check readiness
- If Copass returns thin results, proceed with code exploration but note the gap

**After meaningful work:** call `ingest_text` or `ingest_code` to feed new knowledge back. Do this when you discover architecture decisions, new concepts, user-shared context, or corrections. Do NOT ingest trivial changes or ephemeral debugging context.

<!-- Copass:END -->
