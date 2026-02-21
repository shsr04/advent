# Destructure Arity Strictness Notes

## Change

Destructuring from list values now requires exact arity at runtime.

- Previously: `[a, b] = list` would take first elements and fill missing values with defaults.
- Now: mismatch triggers failure.

## Semantics

For both `string_list` and `number_list`:

- If `list.count != target_count`, destructuring fails.
- In `number | error` functions: fail-fast via `err_number("Destructure arity mismatch", ...)`.
- In non-error-return functions: fail-fast process error (`stderr` + `exit(2)`).

## Motivation

This enforces correctness guarantees around destructuring and avoids silently accepting malformed list sizes.

## Current Limitation

Exact arity is not yet proven statically in general; this is runtime strictness.
Compile-time arity proofs can be added later via list-shape type/narrowing features.
