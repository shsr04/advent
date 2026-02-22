# Nullable Type Feature Prompt

Implement first-class nullable number support in MetaC:

1. Add `null` literal parsing.
2. Add `number | null` type annotations in declarations/assignments/parameters.
3. Add codegen/runtime representation for nullable numbers.
4. Support `== null` / `!= null` checks and branch-local narrowing to `number` in `if` blocks.
5. Keep behavior generic (no day-specific compiler paths).
6. Add regression tests for successful narrowing and compile-time rejection when nullable values are used as numbers without checks.
7. Update day3b to replace sentinel `-1` with `number | null` where appropriate.
