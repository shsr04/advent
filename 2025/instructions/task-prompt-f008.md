# F-008 Implementation Prompt

Implement expression grammar v2 in `compiler/metac.pl`:

1. Add function-call expressions (`foo(a, b)`).
2. Add unary minus (`-x`, `-(a+b)`).
3. Add numeric comparison operators (`<`, `>`, `<=`, `>=`).
4. Keep type checking strict and generic (no domain-specific exceptions).
5. Preserve existing behavior for day1 programs.
