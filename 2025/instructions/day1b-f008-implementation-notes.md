# F-008 Implementation Notes

Date: 2026-02-21

Implemented in `compiler/metac.pl`:

1. Expression tokenizer extended with:
   - `<=`, `>=`, `<`, `>`, `,`
2. Expression parser upgraded to support:
   - unary minus (`-expr`)
   - function calls in expressions (`fn(arg1, arg2, ...)`)
   - comparison operators (`<`, `>`, `<=`, `>=`)
3. Type checking/lowering in `compile_expr`:
   - unary `-` requires `number`
   - comparison operators require numeric operands and return `bool`
   - expression-calls are currently allowed for functions returning `number`
   - calling `number | error` functions in expression position is rejected
   - function arg count and arg types are checked against function signatures

Validation:

- Existing day1 program still compiles and runs.
- Program using `<`, unary `-`, and number-returning function calls compiles.
- Invalid expression call to `number | error` function is rejected with compile error.

Notes:

- `>`/`<=`/`>=` were implemented alongside `<` for consistency.
- This is still generic; no puzzle-specific expression rules were introduced.
