# Coding rules (pointer)

Do not fork compiler policy here.

Human standard for this engine:

`src/RULES/CODING_RULES.txt`

Operational extras from `src/HUGE-ENGINE-PLAN.md`:

- Bounded loops, explicit caps, `STRICT` tables
- `ASSERT` on public entry (two per new procedure)
- `REQUIRE` / `ENSURE` on module API where the compiler accepts them
- No heap on `ON TICK`
- Integer camera; packed RGB is presentation, not navigation
- Fail closed on missing assets
- Pipe `|` only for strings
