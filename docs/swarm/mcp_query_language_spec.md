# query_language_spec(query_string)

Search the bundled ALB docs (spec + cheat sheet + albproj spec).

- Args: `query_string` (string) — e.g. "for loop", "arrays STRICT"
- Returns: JSON `{matches: [{doc, section, score, content}]}` (top 5)
- Use BEFORE writing unfamiliar syntax. Never guess keywords.
