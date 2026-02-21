# Destructure Arity Strictness Prompt

Inspect the updated day2 concept and enforce exact-arity destructuring semantics for list expressions:

- `[a, b, ...] = list` must fail if list length differs from number of targets.
- Preserve fail-fast correctness behavior.
- Keep implementation generic (no day/domain-specific logic).
- Ensure day2 sample still builds/runs, and compiler tests are updated.
