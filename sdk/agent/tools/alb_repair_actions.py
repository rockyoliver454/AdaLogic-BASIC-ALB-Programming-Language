"""Grammar-grounded ALB repair actions (extracted from albt.exe).

The compiler emits structured diagnostics of the form
    [GHOST WARNING] [path] Line N, Col M -> ERR_PARSE_<CODE>
    [FATAL ERROR]   [path] Line N, Col M -> ERR_PARSE_<CODE>
plus an "ALB DIAGNOSTIC FORGE" block. The full error vocabulary below was
extracted from the compiler binary (not guessed), along with the token set.

Each error maps to a bounded textual repair (insert/append/replace) applied
to the reported line/column. Repairs are heuristics -- the loop re-compiles
after every fix and the compiler's next diagnostic drives the next hop, so
a single wrong insertion is corrected one iteration later. This replaces
the blind byte-cycle perturb in synth_loop.

Zero-heap, bounded: every repair caps its insertion and the whole draft
stays within the 128-token injection window (caller enforces).
"""
from __future__ import annotations

import re

# Extracted from albt.exe (obj) string table. Ordered top-down priority:
# lexer errors first, then parser structure, then semantic/emitter.
ERROR_CODES = [
    "ERR_LEX_UNCLOSED_STRING",
    "ERR_LEX_INVALID_HEX",
    "ERR_LEX_INVALID_BIN",
    "ERR_LEX_ROGUE_SYMBOL",
    "ERR_PARSE_MISSING_THEN",
    "ERR_PARSE_MISSING_UNTIL",
    "ERR_PARSE_MISSING_TO",
    "ERR_PARSE_MISSING_ASSIGN",
    "ERR_PARSE_MISSING_TYPE_NAME",
    "ERR_PARSE_MISSING_BRACKET",
    "ERR_PARSE_BLOCK_OVERFLOW",
    "ERR_PARSE_EXPECTED_VALUE",
    "ERR_PARSE_EXPECTED_TYPE",
    "ERR_PARSE_EXPECTED_VAR",
    "ERR_PARSE_EXPECTED_BLOCK_END",
    "ERR_PARSE_ROGUE_SYNTAX",
    "ERR_TYPE_CONFLICT",
    "ERR_SYMBOL_REDECLARED",
    "ERR_MEM_OUT_OF_BOUNDS",
    "ERR_SANDBOX_VIOLATION",
    "ERR_PROC_NOT_FOUND",
    "ERR_EMIT_SYMBOL_NOT_FOUND",
]

_LOC = re.compile(r"Line\s+(\d+),\s*Col\s+(\d+)\s*->\s*(ERR_[A-Z0-9_]+)")
_FORGE_LOC = re.compile(
    r"LOCATION\s*:\s*File\s*\[[^\]]*\]\s*\|\s*Line\s+(\d+)\s*\|\s*Col\s+(\d+)")
_BREACH = re.compile(r"BREACH\s*:\s*([^\r\n]+)")
_MAX_WINDOW = 128


def parse_diagnostics(text: str) -> list[tuple[str, int, int]]:
    """Return ordered (code, line, col) entries; empty when unrecognised."""
    found: list[tuple[str, int, int]] = []
    for m in _LOC.finditer(text):
        code = m.group(3)
        if code in ERROR_CODES:
            found.append((code, int(m.group(1)), int(m.group(2))))
    return found


def parse_forge(text: str) -> tuple[str, int, int] | None:
    """Parse the FORGE block: (breach message, line, col) or None.

    This path fires for lexer-level failures (e.g. unclosed strings that
    swallow the rest of the file) which never reach the ERR_ table.
    """
    loc = _FORGE_LOC.search(text)
    if loc is None:
        return None
    breach = _BREACH.search(text)
    msg = breach.group(1).strip() if breach else ""
    return msg, int(loc.group(1)), int(loc.group(2))


def _lines(data: bytes) -> list[bytes]:
    return data.splitlines(keepends=True)


def _insert_before(data: bytes, line: int, text: bytes) -> bytes:
    """Insert text at the START of `line` (1-based)."""
    parts = _lines(data)
    if not 1 <= line <= len(parts):
        return data + text
    parts.insert(line - 1, text)
    return b"".join(parts)


def _append_to(data: bytes, line: int, text: bytes) -> bytes:
    """Append text at the END of `line` (1-based), before its newline."""
    parts = _lines(data)
    if not 1 <= line <= len(parts):
        return data + text
    parts[line - 1] = parts[line - 1].rstrip(b"\r\n") + text + (b"\n" if parts[line - 1].endswith(b"\n") else b"")
    return b"".join(parts)


def _append(data: bytes, text: bytes) -> bytes:
    return data + text


# Each handler: (data: bytes, line: int, col: int) -> bytes. Bounded, pure.
def _fix_unclosed_string(data: bytes, _l: int, _c: int) -> bytes:
    return _append(data, b'"')


def _fix_missing_then(data: bytes, line: int, _c: int) -> bytes:
    return _append_to(data, max(line - 1, 1), b" = 0 THEN")


def _fix_missing_until(data: bytes, line: int, _c: int) -> bytes:
    return _append_to(data, max(line - 1, 1), b" UNTIL 0")


def _fix_missing_to(data: bytes, line: int, _c: int) -> bytes:
    return _append_to(data, max(line - 1, 1), b" TO 1")


def _fix_missing_assign(data: bytes, line: int, _c: int) -> bytes:
    return _append_to(data, max(line, 1), b" = 0")


def _fix_missing_type(data: bytes, line: int, _c: int) -> bytes:
    return _append_to(data, max(line, 1), b" AS U64")


def _fix_missing_bracket(data: bytes, line: int, _c: int) -> bytes:
    return _append_to(data, max(line, 1), b")")


def _fix_expected_value(data: bytes, line: int, _c: int) -> bytes:
    # If an open block is terminated by a block-closer line, the real
    # defect is the missing inner terminator, not a missing operand.
    if _innermost_open(data) is not None:
        parts = _lines(data)
        if 1 <= line <= len(parts):
            head = parts[line - 1].lstrip().upper()
            if head.startswith(b"END") or head.startswith(b"ENDMODULE"):
                return _close_open_before(data, line)
    return _append_to(data, max(line, 1), b" 0")


def _fix_expected_var(data: bytes, line: int, _c: int) -> bytes:
    return _append_to(data, max(line, 1), b" x")


_OPEN_CLOSE = [
    (b"IF", b"END IF"),
    (b"FOR", b"END FOR"),
    (b"WHILE", b"END WHILE"),
    (b"REPEAT", b"UNTIL"),
    (b"SELECT", b"END SELECT"),
    (b"PROCEDURE", b"END PROCEDURE"),
    (b"FUNCTION", b"END FUNCTION"),
    (b"BEGIN", b"END"),
    (b"MODULE", b"ENDMODULE"),
]


def _innermost_open(data: bytes) -> tuple[bytes, bytes] | None:
    """Return (opener, closer) of the innermost unclosed block, if any."""
    text = data.upper()
    for opener, closer in _OPEN_CLOSE:
        if text.count(opener) > text.count(closer):
            return opener, closer
    return None


def _close_open_blocks(data: bytes) -> bytes:
    """Append the terminator for the last unclosed block keyword."""
    opened = _innermost_open(data)
    if opened is None:
        return _append(data, b"END\n")
    return _append(data, opened[1] + b"\n")


def _close_open_before(data: bytes, line: int) -> bytes:
    """Insert the terminator for the innermost open block BEFORE `line`."""
    opened = _innermost_open(data)
    if opened is None:
        return _insert_before(data, line, b"END IF\n")
    return _insert_before(data, line, opened[1] + b"\n")


def _fix_expected_block_end(data: bytes, line: int, _c: int) -> bytes:
    return _close_open_before(data, line)


def _fix_rogue_syntax(data: bytes, line: int, _c: int) -> bytes:
    return _append(data, b"END\n")


def _fix_unsupported(data: bytes, _l: int, _c: int) -> bytes:
    return data + b"\n"


REPAIRS = {
    "ERR_LEX_UNCLOSED_STRING": _fix_unclosed_string,
    "ERR_LEX_ROGUE_SYMBOL": _fix_rogue_syntax,
    "ERR_PARSE_MISSING_THEN": _fix_missing_then,
    "ERR_PARSE_MISSING_UNTIL": _fix_missing_until,
    "ERR_PARSE_MISSING_TO": _fix_missing_to,
    "ERR_PARSE_MISSING_ASSIGN": _fix_missing_assign,
    "ERR_PARSE_MISSING_TYPE_NAME": _fix_missing_type,
    "ERR_PARSE_MISSING_BRACKET": _fix_missing_bracket,
    "ERR_PARSE_EXPECTED_VALUE": _fix_expected_value,
    "ERR_PARSE_EXPECTED_TYPE": _fix_missing_type,
    "ERR_PARSE_EXPECTED_VAR": _fix_expected_var,
    "ERR_PARSE_EXPECTED_BLOCK_END": _fix_expected_block_end,
    "ERR_PARSE_ROGUE_SYNTAX": _fix_rogue_syntax,
}


def repair(data: bytes, code: str, line: int, col: int) -> bytes | None:
    """Apply a grounded repair; None when the code has no action."""
    handler = REPAIRS.get(code)
    if handler is None:
        return None
    out = handler(data, line, col)
    return out if len(out) <= _MAX_WINDOW else out[:_MAX_WINDOW]


def repair_forge(data: bytes, breach: str, line: int, col: int) -> bytes | None:
    """Content-aware fallback for FORGE-block diagnostics (no ERR code).

    Grounded in the reported location plus the draft content: an unbalanced
    double-quote on the blamed line is closed there; anything else returns
    None so the caller falls back to the byte-cycle perturb.
    """
    _ = breach
    _ = col
    parts = _lines(data)
    if 1 <= line <= len(parts) and parts[line - 1].count(b'"') % 2 == 1:
        out = _append_to(data, line, b'"')
        return out if len(out) <= _MAX_WINDOW else out[:_MAX_WINDOW]
    return None


def minimal_module(name: str = "Gen") -> bytes:
    """A known-valid ALB program (matches DOS/test.alb: procedure + call)."""
    return (
        b"PROCEDURE Main()\n"
        b"  LET x = 1\n"
        b"  PRINT x\n"
        b"END PROCEDURE\n"
        b"Main()\n"
    )
