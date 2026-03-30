<!-- Copass:START -->

## MANDATORY: Copass-First Context Engineering

**BEFORE any task, search, or response**, you MUST query Copass for context:

1. **Every new task** — Call `context_query` or `search_entities` BEFORE reading files, searching code, or exploring the codebase. Use discovered entities to guide your exploration.
2. **Every plan** — Call `get_score` to score readiness BEFORE presenting the plan to the user. If the cosync score is low, call `context_summary` to get detailed context for key entities and surface the gaps before proceeding.
3. **Personal questions about the user** — Always check Copass first. The ontology contains personal context that your built-in memory does not.

Do NOT skip Copass even if you think you already know the answer. The ontology is the source of truth for this project.
<!-- Copass:END -->
