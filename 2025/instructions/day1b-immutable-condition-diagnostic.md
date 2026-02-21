# Immutable Comparison Diagnostic

Date: 2026-02-21

Added compiler diagnostic in `compiler/metac.pl`:

- Detects `while` conditions where comparison expressions depend only on immutable values.
- Emits compile error:
  - `Conditional comparison in while condition depends only on immutable values`

Purpose:

- Catch likely non-terminating loops like `while base > 0` where `base` is immutable.

Scope:

- Applied to `while` conditions (loop safety check).
- Does not block normal immutable comparisons in `if` expressions.
