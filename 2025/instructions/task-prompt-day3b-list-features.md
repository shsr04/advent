# Day3b Compiler Feature Prompt

Implement generic MetaC compiler support needed by `day3b`:

1. Add typed mutable list declarations for explicit empty initialization:
   - `let xs: number[] = []`
   - `let xs: string[] = []`
2. Add list mutation method support:
   - `xs.push(value)` for mutable list variables with type-checked element values.
3. Keep behavior compiler-generic (no day-specific branches).
4. Add regression tests for success and diagnostics.
5. Update `day3b/day3b.metac` to use the new capabilities and produce the correct part-two result.
