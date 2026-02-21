# F-007 Implementation Notes

Date: 2026-02-21

Implemented in `compiler/metac.pl`:

1. Function signature parsing with nested parentheses in argument lists.
   - This enables parameter constraints like `range(0,99)` in signatures.
2. Parameter parsing:
   - `name: number`
   - `name: string`
   - optional chained numeric constraints (`range(...) + wrap + positive/negative`) parsed and stored.
3. New supported function return type:
   - `number` (in addition to existing `number | error`).
4. Parameter immutability:
   - Parameters are bound as immutable in function scope.
   - Any assignment to parameter names is compile-time rejected.
5. C lowering updates:
   - Generated function signatures include typed C params.
   - Prototypes are emitted for all non-main functions.
   - `number` functions lower to `static int`.
   - `number | error` functions lower to `static ResultNumber`.
6. Constraint behavior currently active for parameters:
   - `range + wrap` normalizes numeric parameter value on function entry.

Validation:

- day1 source still compiles to C.
- constrained signature parsing works for parameters with `range(0,99) + wrap`.
- assignment to a parameter produces compile error (`Cannot assign to immutable variable`).

Not yet implemented (tracked separately):

- calls in expression grammar,
- `const`, `while`, `+=`,
- producer initialization (`from () => { ... }`),
- full runtime/static semantics for `positive`/`negative` beyond parsing.
