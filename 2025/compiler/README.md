# MetaC Compiler (Perl, Current Subset)

This directory contains the active MetaC compiler slice in Perl.
It is feature-generic within the supported subset: the compiler does not hardcode day/domain identifiers.

## Module Layout

- `compiler/metac.pl`: thin CLI entrypoint
- `compiler/lib/MetaC/Support.pm`: shared helpers (errors, trimming, constraints, CSV-like splitting, emit helpers)
- `compiler/lib/MetaC/Parser.pm`: source parsing into AST-style statement/expression structures
- `compiler/lib/MetaC/Codegen.pm`: top-level typing checks and C lowering orchestration
- `compiler/lib/MetaC/CodegenType.pm`: codegen type helpers (parameter C signatures and number-like conversions)
- `compiler/lib/MetaC/CodegenScope.pm`: scope table and flow-fact helpers (list arity and nullable facts)
- `compiler/lib/MetaC/CodegenRuntime.pm`: generated C runtime prelude text

## Compile MetaC -> C

```bash
perl compiler/metac.pl day1/day1.metac -o compiler/build/day1.c
```

## Build Generated C

```bash
cc -std=c11 -O2 -Wall -Wextra -pedantic compiler/build/day1.c -o compiler/build/day1
```

## Run With Sample Input

```bash
./compiler/build/day1 < day1/sample-input.txt
```

Expected output:

```text
Result: 3
```

## Compiler Test Suite

Tracked compiler regression tests live in `compiler/tests/`.

Run all compiler tests:

```bash
make test
```

Or directly:

```bash
perl compiler/tests/run.pl
```

Test cases live in `compiler/tests/cases/`:

- `*.metac`: source test program
- `*.in` (optional): stdin input
- `*.out` (required for run tests): expected stdout
- `*.exit` (optional): expected process exit code (default `0`)
- `*.compile_err` (optional): expected compile-failure diagnostic substring

## Supported Subset (Current)

- numeric backend note:
  - MetaC `number` currently lowers to signed 64-bit (`int64_t`) in generated C
  - silent overflow is still possible in the current backend for large arithmetic; bigint semantics are not implemented yet
  - generated C runtime helper emission is usage-pruned (unused `metac_*` helper functions are omitted)

- `function main() { ... }`
- `function <name>(): number | error { ... }`
- `function <name>(<typed params>): number { ... }`
- typed parameters:
  - `<id>: number`
  - `<id>: string`
  - numeric constraints in signatures, including `range(...) + wrap`
- wraparound behavior is explicit via `+ wrap` (not implicit from `range(...)` alone)
- function parameters are immutable (compile-time assignment rejection)
- `let <id>: number with range(0,99) + wrap = <expr>`
- `let <id>: number with <constraint + constraint + ...> = <expr>`
- `let <id>: number = <number_expr>`
- `let <id>: number | null = <number_expr-or-null>`
- `let <id>: string = <string_expr>`
- `let <id>: number[] = []`
- `let <id>: string[] = []`
- `let <id> = <expr>` (type inference for `number`, `string`, `bool`)
- `const <id> = <expr>` with inferred immutable type (`number`, `bool`, `string`, `string_list`, `number_list`)
- `const <id> = split(<string>, <delimiter>)?` with error propagation
- `while <bool_expr> { ... }`
- `break` (inside `for`/`while` loops)
- `continue` (inside `for`/`while` loops)
- compound assignment: `<id> += <number_expr>`
- increment/decrement: `<id>++`, `<id>--`
- `for const <id> in lines(STDIN)? { ... }`
- `for const <id> in <iterable> { ... }`
  - iterable is a general expression
  - supports `seq(start, end)` with `number` bounds
  - supports list-valued expressions (`string_list` / `number_list`)
  - supports chained `.filter(x => <bool-expr>)` over either form
- `const [a, b, ...] = match(source, /<regex-with-captures>/)?`
- `const [a, b, ...] = split(source, delim) or (e) => { ... }`
- producer initialization: `let <id>: <type> from () => { ... }`
- typed assignment form: `<id>: <type> [with <constraints>] = <expr>`
- expression grammar includes:
  - arithmetic: `+`, `-`, `*`, `/`, `%` (integer division/modulo)
  - unary minus: `-x`
  - equality/comparisons: `==`, `!=`, `<`, `>`, `<=`, `>=`, `||`
  - boolean literals: `true`, `false`
  - null literal: `null` (currently for `number | null`)
  - typed function calls: `fn(...)` for `number`- and `bool`-return functions
  - numeric parsing builtin: `parseNumber(<string>)` (fallible; use with `?` or via `map(parseNumber)?`)
  - method calls: `<expr>.<method>(...)`
    - string methods: `.size()`, `.chunk(<number>)`, `.chars()`
    - string methods operate on UTF-8 symbols (code points), not raw bytes
    - list methods: `.size()`, `.slice(<number>)`, `.max()`, `.sort()` (on number lists), `.reduce(<initial>, (acc, item) => <number-expr>)`
    - mutable list methods: `.push(<value>)` on mutable `number_list`/`string_list` variables
    - all major scalar/list types: `.log()` (prints value, returns original value)
  - lambda expressions:
    - single parameter: `x => <expr>`
    - two parameter: `(a, b) => <expr>` (used by `reduce`)
  - indexing:
    - `<string-expr>[<number-expr>]` (returns numeric UTF-8 symbol code point)
    - `<string-list-expr>[<number-expr>]` (returns `string`)
    - `<number-list-expr>[<number-expr>]` (returns `number`)
    - index access requires compile-time in-bounds proof
  - numeric builtins: `max(a,b)`, `min(a,b)`
  - logging builtin: `log(x)` (prints value, returns original value)
- interpolation templates in string literals:
  - `"Invalid range: ${range}"`
- explicit error expression:
  - `error("message")` in `number | error` return paths
- bool aliases:
  - `boolean` is accepted as an alias for `bool` in parameter, variable, and return type positions
- list destructuring from list expressions:
  - `const [a, b, ...] = <string-list-expression>`
  - compile-time arity proof is required (for example via a guard like `if list.size() != N { return ... }` or `... .assert(x => x.size() == N, "...")?`)
- fail-fast try assignment:
  - `const <id> = <fallible-expression>?`
  - supported fallible expressions include:
    - `split(<string>, <string>)`
    - `parseNumber(<string>)`
    - `<string_list>.map(<mapper>)` when mapper returns `number | error`
    - `<list>.filter(x => <predicate>)`
    - `<list>.assert(x => x.size() == <numeric-literal-size>, <message>)`

## Genericity Rule

- Compiler code remains domain-agnostic.
- Day-specific behavior must come from source language features, not hardcoded compiler branches.
