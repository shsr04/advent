# Task Prompt: Support nested parenthesized constrained list types

## Objective
Implement parser/type-normalization support for nested type syntax such as `(int[] with size(2))[]`, consistent with normative syntax `Type := (Type) | TypeIntersection`.

## Required outcomes
1. Parse and normalize nested constrained element list types in variable/const declarations and params where applicable.
2. Ensure element constraints are enforced on writes (`push`) and assignment checks.
3. Add regression tests for accepted nested types and diagnostics.
4. Verify day5-style declarations can use explicit nested size-constrained element type.
5. Run full compiler test suite.
