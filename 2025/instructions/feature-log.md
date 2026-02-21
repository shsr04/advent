# Feature Log

Track all language features here. Add items as we iterate.

## Status Legend

- `draft`: rough idea captured.
- `review`: spec under active critique.
- `accepted`: spec approved for implementation.
- `implemented`: code complete, verification pending.
- `verified`: correctness gates passed.

## Active Roadmap

1. `F-001` Core type system baseline - `draft`
2. `F-002` Constraint declaration syntax - `draft`
3. `F-003` Deterministic evaluation order semantics - `draft`
4. `F-004` Source -> IR mapping rules - `draft`
5. `F-005` IR -> C safe subset backend rules - `draft`
6. `F-006` Day1 compiler subset (source -> C, validated on sample) - `implemented`
7. `F-007` Function signatures + parameter immutability + `number` return - `draft`
8. `F-008` Expression grammar v2 (`<`, unary `-`, calls) - `draft`
9. `F-009` Statement grammar v2 (`const`, `while`, `+=`) - `draft`
10. `F-010` Constraint chains (`range + wrap + positive/negative`) - `draft`
11. `F-011` Producer initialization (`from () => { ... }`) - `draft`
12. `F-012` Iterable model (`split`, `seq`, generic `for-in`) - `implemented`
13. `F-013` Error-flow expressions (`?`, `or (e) => { ... }`) - `implemented`
14. `F-014` String templates + `error(...)` constructor - `implemented`
15. `F-015` Bool-return user function support (no day-specific builtin) - `implemented`
16. `F-016` Bool alias (`boolean`) type normalization - `implemented`
17. `F-017` String member-call expressions (`.size()`, `.chunk(n)`) - `implemented`
18. `F-018` Multiplicative expression ops (`*`, `/`) - `implemented`
19. `F-019` Generic list destructuring from expression values - `implemented`
20. `F-020` Numeric parsing builtin (`parseNumber(string)`) - `implemented`
21. `F-021` Strict numeric `seq` bounds - `implemented`
22. `F-022` Lodash-style `chunk` semantics - `implemented`
23. `F-023` Fail-fast map over string lists (`map(parseNumber)?`) - `implemented`
24. `F-024` Try-expression assignment (`const x = expr?`) - `implemented`
25. `F-025` Inequality operator (`!=`) - `implemented`
26. `F-026` Guard-proven list destructuring arity - `implemented`
27. `F-027` Boolean literals + list-valued `const` declarations - `implemented`
28. `F-028` Inline list assert helper (`.assert(x => predicate, message)?`) - `implemented`
29. `F-029` 64-bit numeric backend for `number` - `implemented`

## Feature Record Template

Use this block for each feature:

```md
### F-XXX `<feature name>`
- Status:
- Spec file:
- Correctness classes: C0/C1/C2/C3/C4
- Key guarantees:
- Blocking questions:
- Notes/evidence:
```

### F-006 `Day1 Compiler Subset`
- Status: implemented
- Spec file: `instructions/day1-compiler-subset-spec.md`
- Correctness classes: C0/C1/C3
- Key guarantees: deterministic C codegen, explicit parse errors, feature-generic lowering (no domain-specific compiler branches)
- Blocking questions: general parser architecture for features beyond day1 subset
- Notes/evidence: sample case from `day1/day1-task.md` executed against generated binary

### F-007 `Function Signatures + Immutable Params + Number Return`
- Status: implemented
- Spec file: `instructions/day1b-f007-implementation-notes.md`
- Correctness classes: C0/C1/C3
- Key guarantees: typed parameter binding, read-only parameter enforcement, deterministic call lowering
- Blocking questions: calling convention for non-`number | error` functions in current backend
- Notes/evidence: parser and lowering support added in `compiler/metac.pl`; parameter assignment rejection verified

### F-008 `Expression Grammar V2`
- Status: implemented
- Spec file: `instructions/day1b-f008-implementation-notes.md`
- Correctness classes: C0/C1
- Key guarantees: operator typing for `<` and unary `-`, typed function calls in expression context
- Blocking questions: precedence table for future operators
- Notes/evidence: compiler now supports unary minus, comparisons, and typed number-return function calls in expressions

### F-009 `Statement Grammar V2`
- Status: implemented
- Spec file: `instructions/day1b-f009-implementation-notes.md`
- Correctness classes: C0/C1/C3
- Key guarantees: safe lowering for `const`, `while`, and `+=`
- Blocking questions: lvalue eligibility rules for compound assignment
- Notes/evidence: parser/lowering support added; const immutability rejection validated

### F-010 `Constraint Chains`
- Status: implemented
- Spec file: `instructions/day1b-f010-implementation-notes.md`
- Correctness classes: C1/C3
- Key guarantees: compositional constraints with explicit `wrap` semantics and sign constraints
- Blocking questions: interaction of sign constraints with inferred types and runtime paths
- Notes/evidence: typed let constraint chains + explicit wrap semantics + inferred let support added

### F-011 `Producer Initialization`
- Status: implemented
- Spec file: `instructions/day1b-f011-implementation-notes.md`
- Correctness classes: C1/C3/C4
- Key guarantees: producer must assign target variable, closure reads outer scope safely
- Blocking questions: static proof strategy for must-assign in conditional producer branches
- Notes/evidence: producer syntax + typed assignment + must-assign checks implemented in compiler

### F-012 `Iterable Model`
- Status: implemented
- Spec file: `instructions/day2-feature-review.md`
- Correctness classes: C0/C1/C3
- Key guarantees: deterministic iteration semantics for split results and numeric ranges
- Blocking questions: representation of list/string slices in generated C
- Notes/evidence: lowering implemented in `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/split_seq_sum.metac`

### F-013 `Error-Flow Expressions`
- Status: implemented
- Spec file: `instructions/day2-feature-review.md`
- Correctness classes: C1/C3
- Key guarantees: explicit and implicit error propagation are statically structured
- Blocking questions: parser precedence for `or (e) => { ... }` versus other expression forms
- Notes/evidence: `split(...)?` and `split(...) or (e) => { ... }` lowered generically in compiler; regression coverage in `compiler/tests/cases/split_handler_error.metac`

### F-014 `String Templates + Error Constructor`
- Status: implemented
- Spec file: `instructions/day2-feature-review.md`
- Correctness classes: C1/C3
- Key guarantees: deterministic interpolation lowering and explicit error value construction
- Blocking questions: runtime buffer model for interpolation safety
- Notes/evidence: template interpolation and `error(...)` expression compilation in `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/string_template_condition.metac`

### F-015 `Bool-Return User Function Support`
- Status: implemented
- Spec file: `instructions/day2-feature-review.md`
- Correctness classes: C1/C3
- Key guarantees: user-defined predicates are callable in condition context without compiler builtins
- Blocking questions: return-type inference/checking strategy for bool-return functions
- Notes/evidence: bool-return signatures/calls implemented generically; regression coverage in `compiler/tests/cases/number_bool_while.metac`

### F-016 `Bool Alias Type Normalization`
- Status: implemented
- Spec file: `instructions/day2-hasrepeating-update-notes.md`
- Correctness classes: C1/C3
- Key guarantees: `boolean` is accepted as an alias for `bool` in params, variable annotations, and function return typing
- Blocking questions: whether additional aliases should be standardized in future revisions
- Notes/evidence: parser and compile-source return normalization now accept `boolean`; validated by `compiler/tests/cases/string_methods_boolean.metac`

### F-017 `String Member-Call Expressions`
- Status: implemented
- Spec file: `instructions/day2-hasrepeating-update-notes.md`
- Correctness classes: C1/C3
- Key guarantees: deterministic lowering for string methods `.size()` and `.chunk(number)` with explicit runtime support
- Blocking questions: memory lifetime model for allocated chunk results
- Notes/evidence: parser supports member-call postfix syntax; lowering/runtime implemented in `compiler/lib/MetaC/Codegen.pm`; validated by `compiler/tests/cases/string_methods_boolean.metac`

### F-018 `Multiplicative Expression Ops`
- Status: implemented
- Spec file: `instructions/day2-hasrepeating-update-notes.md`
- Correctness classes: C1
- Key guarantees: precedence-aware parse and typed lowering for `*` and `/` on numeric operands
- Blocking questions: explicit divide-by-zero behavior policy for future correctness modes
- Notes/evidence: expression parser/codegen updated and exercised by `input.size() / 2` in compiler tests and day2 program

### F-019 `Generic List Destructuring`
- Status: implemented
- Spec file: `instructions/day2-hasrepeating-update-notes.md`
- Correctness classes: C1/C3
- Key guarantees: `const [a, b, ...] = <list-expression>` works for string-list values without day-specific branches
- Blocking questions: whether arity mismatch should be strict or permissive by default
- Notes/evidence: implemented as `destructure_list` statement lowering; validated by `compiler/tests/cases/string_methods_boolean.metac`

### F-020 `Numeric Parsing Builtin`
- Status: implemented
- Spec file: `instructions/day2-seq-chunk-adjustments-notes.md`
- Correctness classes: C1/C3
- Key guarantees: string-to-number conversion is explicit in source via `parseNumber(...)`
- Blocking questions: future error-propagation shape for parse failures
- Notes/evidence: builtin implemented in expression lowering/runtime and used in `day2/day2.metac`

### F-021 `Strict Numeric seq Bounds`
- Status: implemented
- Spec file: `instructions/day2-seq-chunk-adjustments-notes.md`
- Correctness classes: C1/C3
- Key guarantees: `seq(start, end)` now requires numeric bounds at compile time
- Blocking questions: whether implicit coercions should ever be allowed under opt-in modes
- Notes/evidence: codegen check tightened; compile-fail regression `compiler/tests/cases/diagnostic_seq_requires_numbers.metac`

### F-022 `Lodash-style chunk Semantics`
- Status: implemented
- Spec file: `instructions/day2-seq-chunk-adjustments-notes.md`
- Correctness classes: C0/C1
- Key guarantees: chunking preserves remainder chunk for uneven splits; non-positive size yields empty list
- Blocking questions: none for current subset
- Notes/evidence: runtime helper `metac_chunk_string` updated; regression coverage in `compiler/tests/cases/string_methods_boolean.metac`

### F-023 `Fail-fast Map Over String Lists`
- Status: implemented
- Spec file: `instructions/day2-seq-chunk-adjustments-notes.md`
- Correctness classes: C1/C3
- Key guarantees: `<string_list>.map(parseNumber)?` propagates first parse error and returns mapped numeric list on success
- Blocking questions: extension to generic user-function mappers for non-number result lists
- Notes/evidence: map fail-fast lowering in `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/map_parse_number_failfast.metac`

### F-024 `Try-expression Assignment`
- Status: implemented
- Spec file: `instructions/day2-seq-chunk-adjustments-notes.md`
- Correctness classes: C1/C3
- Key guarantees: `const <id> = <fallible-expr>?` provides structured fail-fast propagation in `number | error` functions
- Blocking questions: generalized try-expression typing for nested/future fallible expressions
- Notes/evidence: parser + codegen support for `const_try_expr`; regression coverage in `compiler/tests/cases/parse_number_try.metac`

### F-025 `Inequality Operator`
- Status: implemented
- Spec file: `instructions/day2-seq-chunk-adjustments-notes.md`
- Correctness classes: C1
- Key guarantees: typed `!=` across number/bool/string with deterministic lowering
- Blocking questions: none for current subset
- Notes/evidence: expression parser/codegen updated; used in `day2/day2.metac`

### F-026 `Guard-proven List Destructuring Arity`
- Status: implemented
- Spec file: `instructions/destructure-arity-strictness-notes.md`
- Correctness classes: C1/C3/C4
- Key guarantees: list destructuring now requires compile-time proof of exact list arity (for example from `if list.size() != N { return ... }`)
- Blocking questions: richer path-sensitive proofs beyond simple `size()` guards
- Notes/evidence: guard-fact analysis implemented in `compiler/lib/MetaC/Codegen.pm`; compile-fail regression in `compiler/tests/cases/diagnostic_destructure_requires_proof.metac`; day2 remains green

### F-027 `Boolean Literals + List-valued const`
- Status: implemented
- Spec file: `instructions/day2-guarded-destructure-notes.md`
- Correctness classes: C1/C3
- Key guarantees: `true`/`false` are first-class boolean literals; `const` can bind `string_list`/`number_list` expressions generically
- Blocking questions: future list mutability and ownership model
- Notes/evidence: parser/codegen updates in `compiler/lib/MetaC/Parser.pm` and `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/bool_literals_size_property.metac`

### F-028 `Inline List Assert Helper`
- Status: implemented
- Spec file: `instructions/day2-guarded-destructure-notes.md`
- Correctness classes: C1/C3/C4
- Key guarantees: `<list>.assert(x => x.size() == <N>, <message>)?` fail-fast checks list arity and establishes compile-time arity proof for downstream destructuring
- Blocking questions: whether to support non-literal expected sizes in future proof modes
- Notes/evidence: `const_try_expr` lowering extended in `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/assert_inline_arity.metac`

### F-029 `64-bit Numeric Backend`
- Status: implemented
- Spec file: `instructions/number-backend-64bit-notes.md`
- Correctness classes: C1/C3
- Key guarantees: MetaC `number` now lowers to `int64_t` across values, function signatures, lists, parsing, and iteration
- Blocking questions: exact-integer / bigint semantics and overflow policy for future correctness levels
- Notes/evidence: runtime/codegen migration in `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/parse_number_64bit.metac`; day2 real input now runs
