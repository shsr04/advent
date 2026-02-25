# Task Prompt: Extend Compiler Support for Day 5

## Objective
Update the MetaC compiler so that `day5/day5.metac` is supported by language features (parser + codegen + runtime where needed), while preserving generic compiler behavior and ownership/cleanup correctness.

## Required outcomes
1. Add parser/codegen support needed by day5 constructs:
- fallible iterable in `for const x in <expr>? { ... }` when `<expr>` is `split(...)` or equivalent string split expression
- string method `isBlank()` in expressions
- fallible string method split usage in try chains (`row.split("-")?`)
2. Keep behavior generic (no day-specific hardcoding).
3. Add/adjust regression tests in `compiler/tests/cases` for new features.
4. Run compiler tests and verify no regressions.
5. Compile `day5/day5.metac` and report remaining metac source errors (if any) separately from compiler feature gaps.

## Constraints
- Respect existing code style and module boundaries.
- Ensure any emitted memory allocation has matching cleanup on logical lifetime end.
- Keep changes focused and maintainable.
