# Diagnostics contract — read the "why", not just the "what"

albt prints an ALB DIAGNOSTIC FORGE banner on breach:

    LOCATION : File [../ZDepth.ALBI] | Line 9 | Col 100
    BREACH   : Unexpected Token Encountered.
    COUNSEL  : Review the syntax near this token.

MCP tools return this as: {file, line, col, error, hint}.

Fork: Environment First — if code previously compiled, check
include paths / .albproj / staging before editing source.
Compiler-fix vs source-fix: emitter bugs -> fix toolchain;
language violations -> fix the .alb.
