# Day1b Feature Review

Source reviewed: `day1b/day1b-spec.md`

## New Features Identified

1. Chained constraints on types:
   - Example: `number with range(0,99) + wrap`
2. Explicit wrap behavior as a constraint:
   - `wrap` should control modulo wraparound semantics (not implicit by range alone).
3. Type inference without explicit type annotation:
   - Example: `let zeroHits = 0`
4. Function parameters with constraints:
   - Example: `base: number with range(0,99) + wrap`
5. Parameter immutability:
   - Parameters are read-only inside function body.
6. Additional expression operators:
   - `<` (and by extension likely `>`, `<=`, `>=` soon)
   - unary negative in expressions like `-amount`
7. Compound assignment:
   - `+=`
8. While loops:
   - `while condition { ... }`
9. Local const declarations:
   - Example: `const isNegative = ...`
10. Generic function calls in expressions:
    - Example: `countZeroPasses(dial, amount)`, `max(a,b)`
11. Producer-function initialization:
    - Example:
      - `let remaining: number from () => { ... }`
      - producer has closure access to outer scope
      - producer must assign target variable
12. Additional constraints:
    - `with negative`
    - `with positive`
13. Function return type `number` (non-error union):
    - Example: `function ...(...): number`

## Already Supported

- `function main() { ... }` with `or (e) => { ... }` for `number | error` call.
- `number | error` functions (no parameters).
- `for const line in lines(STDIN)? { ... }`
- destructuring from regex match:
  - `const [a, b, ...] = match(source, /.../)?`
- `if ... { ... } else { ... }`
- `let` declarations for `number` and `string`.
- assignments with `=`.
- binary `+`, `-`, `==`.

## Missing / Needs Extension

- Function parameters (typed + constrained).
- Function return type `number` and generic non-main function call lowering.
- Constraint parser model beyond a single `range`.
- `wrap` as explicit constraint semantics.
- `const` declarations.
- `while` loop AST/lowering.
- `+=` parsing/lowering.
- comparison operators (at least `<`).
- unary minus.
- calls in expression grammar.
- producer-function initialization (`from () => { ... }`) and closure checks.
- constraint checks for `positive` / `negative`.
- immutability enforcement for parameters.

## Recommended Implementation Order (Generic)

1. `F-007`: function signatures with parameters + immutable param scope + return `number`.
2. `F-008`: expression grammar upgrade (`<`, unary `-`, calls).
3. `F-009`: statements (`const`, `while`, `+=`).
4. `F-010`: generalized constraint chains (`range + wrap + positive/negative`).
5. `F-011`: producer initialization (`from () => { ... }`) with closure + must-assign check.

This order keeps parser/compiler changes incremental while preserving genericity.
