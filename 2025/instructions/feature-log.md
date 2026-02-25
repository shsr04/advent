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
13. `F-013` Error-flow expressions (`?`, `or catch(e) { ... }`) - `implemented`
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
30. `F-030` Mutable list initialization + push method - `implemented`
31. `F-031` Nullable number type (`number | null`) - `implemented`
32. `F-032` Logical OR (`||`) with short-circuit nullable narrowing - `implemented`
33. `F-033` Codegen module split (type/scope/runtime extraction) - `implemented`
34. `F-034` List reduce method with two-parameter lambdas - `implemented`
35. `F-035` Runtime helper dead-stripping in generated C - `implemented`
36. `F-036` Generic program/entrypoint lowering (remove subset-locked `main` pattern) - `implemented`
37. `F-037` Full boolean connective grammar (`&&`) and precedence parity - `implemented`
38. `F-038` Generalized union type model (beyond hardcoded unions) - `implemented`
39. `F-039` Generic fallibility handlers (`?`, `or`) over all fallible expressions - `implemented`
40. `F-040` Constraint engine v2 (`size`, applicability matrix, matrix-size linkage) - `implemented`
41. `F-041` Generic array type model (`T[]`) and operation typing - `implemented`
42. `F-042` Number semantics policy alignment (normative rational model vs backend modes) - `draft`
43. `F-043` Return-lowering generalization for union return types - `implemented`
44. `F-044` Normative conformance harness + implementation-percentage gate - `draft`
45. `F-045` Optional extension: effect-system abstraction for fallibility - `draft`
46. `F-046` Loop rewind statement (`rewind`) for iterable recomputation - `implemented`
47. `F-047` Compiler architecture split (`parser -> IR -> correctness gates -> codegen`) - `draft`

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
- Blocking questions: parser precedence for `or catch(e) { ... }` versus other expression forms
- Notes/evidence: `split(...)?` and `split(...) or catch(e) { ... }` lowered generically in compiler; regression coverage in `compiler/tests/cases/split_handler_error.metac`

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

### F-030 `Mutable List Initialization + Push`
- Status: implemented
- Spec file: n/a (task-driven implementation for day3b)
- Correctness classes: C0/C1/C3
- Key guarantees: typed mutable list declarations support explicit empty literal initialization (`let xs: number[] = []` / `let xs: string[] = []`), and `push(...)` mutates only mutable list variables with type-checked element appends
- Blocking questions: non-empty list literals and fallible list capacity/error policy
- Notes/evidence: parser/codegen/runtime updates in `compiler/lib/MetaC/Parser.pm` and `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/list_push_mutable_number.metac`, `compiler/tests/cases/diagnostic_empty_list_requires_type.metac`, and `compiler/tests/cases/diagnostic_push_requires_mutable_list.metac`

### F-031 `Nullable Number Type`
- Status: implemented
- Spec file: n/a (task-driven implementation for day3b)
- Correctness classes: C0/C1/C3
- Key guarantees: supports `null` literal and `number | null` type for declarations/assignments, typed equality checks against `null`, and branch-local narrowing to `number` for safe arithmetic/comparison
- Blocking questions: generalized nullable unions for non-number types and nullable function return modes
- Notes/evidence: parser/codegen/runtime updates in `compiler/lib/MetaC/Parser.pm` and `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/null_number_branch_narrowing.metac` and `compiler/tests/cases/diagnostic_nullable_number_requires_check.metac`

### F-032 `Logical OR with Nullable-aware RHS Narrowing`
- Status: implemented
- Spec file: n/a (task-driven implementation for day3b)
- Correctness classes: C0/C1/C3
- Key guarantees: supports `||` in boolean expressions with short-circuit codegen and nullable-number narrowing on RHS for `x == null || <rhs-using-x-as-number>`
- Blocking questions: generalized boolean connective support (`&&`) and richer control-flow fact propagation
- Notes/evidence: parser/codegen updates in `compiler/lib/MetaC/Parser.pm` and `compiler/lib/MetaC/Codegen.pm`; regression coverage in `compiler/tests/cases/null_or_short_circuit_narrowing.metac`

### F-033 `Codegen Module Split`
- Status: implemented
- Spec file: n/a (task-driven refactor)
- Correctness classes: C0/C3
- Key guarantees: preserved compiler behavior while splitting codegen internals into focused modules for type helpers, scope/fact helpers, and runtime prelude emission
- Blocking questions: further split opportunities for expression lowering and statement lowering layers
- Notes/evidence: new modules `compiler/lib/MetaC/CodegenType.pm`, `compiler/lib/MetaC/CodegenScope.pm`, and `compiler/lib/MetaC/CodegenRuntime.pm`; full regression suite remains green (`make test`)

### F-034 `List Reduce Method`
- Status: implemented
- Spec file: n/a (task-driven implementation for day3b)
- Correctness classes: C0/C1/C3
- Key guarantees: supports `<list>.reduce(initial, (acc, item) => expr)` for `number_list` and `string_list` with deterministic left-to-right accumulation and numeric accumulator typing
- Blocking questions: reducer closure capture model beyond explicit lambda parameters
- Notes/evidence: parser/codegen/runtime updates in `compiler/lib/MetaC/Parser.pm`, `compiler/lib/MetaC/Codegen.pm`, and `compiler/lib/MetaC/CodegenRuntime.pm`; regression coverage in `compiler/tests/cases/reduce_number_string_lists.metac` and `compiler/tests/cases/diagnostic_reduce_requires_lambda2.metac`

### F-035 `Runtime Helper Dead-stripping`
- Status: implemented
- Spec file: n/a (task-driven implementation for day3b warning cleanup)
- Correctness classes: C0/C3
- Key guarantees: generated C now includes only runtime helper functions actually referenced by compiled program code plus transitive runtime dependencies
- Blocking questions: optional future extension to strip unused runtime typedef/includes where safe
- Notes/evidence: runtime dependency pruning implemented in `compiler/lib/MetaC/CodegenRuntime.pm` and wired in `compiler/lib/MetaC/Codegen.pm`; full regression suite remains green (`make test`); day3b C no longer emits unused-runtime helper warnings like `metac_log_string_list`

## Normative Gap Closure Plan (Future)

- Baseline: normative conformance is currently estimated at `55-60%`.
- Objective: raise normative conformance to `>=90%` without losing deterministic lowering or current regression stability.
- Stage ordering:
  1. Stage A (syntax/front-door parity): `F-036`, `F-037`
  2. Stage B (type/fallibility core): `F-038`, `F-039`
  3. Stage C (constraints/containers): `F-040`, `F-041`
  4. Stage D (semantic/backend parity): `F-042`, `F-043`
  5. Stage E (measurement/release): `F-044`
  6. Optional generalization track: `F-045`
- Phase gate rule: each stage must keep existing compiler tests green and add dedicated normative conformance cases before advancing.

### F-036 `Generic Program/Entrypoint Lowering`
- Status: implemented
- Spec file: `instructions/normative-f036-program-entrypoint.md` (planned)
- Correctness classes: C0/C1/C3
- Key guarantees: remove hardcoded `main` body regex requirements; lower entrypoint behavior via parsed AST statements; keep deterministic C main emission without day-specific patterns.
- Blocking questions: whether initial version keeps `main` as default entrypoint only or also supports explicit alternate entrypoint selection.
- Notes/evidence: implemented generic `main` lowering via parsed statement blocks in `compiler/lib/MetaC/Codegen/Compile.pm` (`compile_main_body_generic_void`), removing runtime reliance on legacy `printf(... or handler ...)` pattern matching. Regression suite updated to parser-native `main` bodies and remains green.

### F-037 `Boolean Connective Parity (`&&`)`
- Status: implemented
- Spec file: `instructions/normative-f037-boolean-connectives.md` (planned)
- Correctness classes: C0/C1/C3
- Key guarantees: parser accepts `&&` with normative precedence (`&&` tighter than `||`); codegen preserves short-circuit semantics and flow-fact safety.
- Blocking questions: how far to extend fact propagation on `&&` in first pass (minimal correctness vs advanced narrowing).
- Notes/evidence: parser now tokenizes/parses `&&` between equality and `||` in `compiler/lib/MetaC/Parser/Expr.pm`; short-circuit codegen and RHS nullable narrowing support added in `compiler/lib/MetaC/Codegen/Expr.pm` and `compiler/lib/MetaC/Codegen/Facts.pm`. Coverage: `and_precedence_narrowing` and `diagnostic_and_requires_bool`.

### F-038 `Generalized Union Type Model`
- Status: implemented
- Spec file: `instructions/normative-f038-union-types.md` (planned)
- Correctness classes: C0/C1/C3/C4
- Key guarantees: parse and normalize arbitrary type unions (not just specialized aliases like `number | null`); track union membership in type-checker; enable member-safe narrowing paths.
- Blocking questions: whether unions require nominal tagging strategy in internal type representation immediately, or can start with canonical sorted member sets.
- Notes/evidence: parser/type layer now normalizes unions canonically in `compiler/lib/MetaC/TypeSpec.pm` (ordering/duplicate collapse, parenthesized unions, alias normalization), and exposes union membership helpers used by codegen return/fallibility classification. Union-typed variable declarations/assignments/params now lower via `MetaCValue` conversions in `compiler/lib/MetaC/CodegenType.pm`, `compiler/lib/MetaC/Codegen/BlockStageDecls.pm`, `compiler/lib/MetaC/Codegen/BlockStageAssignLoops.pm`, and `compiler/lib/MetaC/Codegen/CompileParams.pm`. Member-safe narrowing for `if`/`&&`/`||` checks against scalar members is implemented in `compiler/lib/MetaC/Codegen/Facts.pm`, `compiler/lib/MetaC/Codegen/Expr.pm`, and `compiler/lib/MetaC/Codegen/BlockStageControl.pm`. Coverage includes `union_return_number_error_normalized`, `union_var_and_narrowing`, and `diagnostic_union_var_requires_narrowing`; full suite green (`88 passed, 0 failed`).

### F-039 `Generic Fallibility Handling (`?` and `or`)`
- Status: implemented
- Spec file: `instructions/normative-f039-fallibility.md` (planned)
- Correctness classes: C1/C3/C4
- Key guarantees: treat any expression containing `error` in its type union as fallible; allow `?` and `or catch(...) { ... }` handling uniformly in call and chain contexts; remove return-mode-specific try restrictions.
- Blocking questions: shape of handler lambda typing for non-`error` future effect members.
- Notes/evidence: `?` handling is generalized for function-call fallibility across supported `error`-containing return unions, including multi-member unions, in const and statement try lowering (`compiler/lib/MetaC/Codegen/BlockStageDeclsTry.pm`, `compiler/lib/MetaC/Codegen/BlockStageControl.pm`). `or catch(...) { ... }` handlers are now supported for split-destructure plus fallible user-function calls in const assignment and statement contexts, with handler blocks executed in the enclosing function scope (`compiler/lib/MetaC/Parser/BlockParse.pm`, `compiler/lib/MetaC/Codegen/BlockStageTry.pm`, `compiler/lib/MetaC/Codegen/BlockStageDeclsTry.pm`, `compiler/lib/MetaC/Codegen/BlockStageControl.pm`). Legacy `or (e) => { ... }` syntax is rejected via dedicated diagnostic coverage (`diagnostic_legacy_or_handler_syntax`). Additional coverage: `stmt_try_generic_user_call`, `try_union_multimember_narrowing`, `or_catch_const_call_success`, `or_catch_const_call_handler_return`, `or_catch_expr_stmt_handler_return`, `split_or_catch_destructure`; full suite green (`95 passed, 0 failed`).

### F-040 `Constraint Engine V2`
- Status: implemented
- Spec file: `instructions/normative-f040-constraints.md`
- Correctness classes: C0/C1/C3/C4
- Key guarantees: support normative `size(n)` constraint and explicit per-type constraint applicability checks; keep `range`, `wrap`, `dim`, `matrixSize` consistent and composable.
- Blocking questions: whether non-literal constraint arguments are accepted in this stage or deferred behind proof obligations.
- Notes/evidence: spec and acceptance scope documented in `instructions/normative-f040-constraints.md`; constraint parser now uses typed nodes as the canonical representation (`constraints = { nodes => [...] }`) across scalar and matrix constraints, including wildcard args for `range`, `size`, `dim`, and `matrixSize`, duplicate-term rejection, and `wrap`/`range` boundedness+order validation in `compiler/lib/MetaC/Support.pm`; parser/type applicability checks run against typed nodes in `compiler/lib/MetaC/Parser/Functions.pm`; matrix constraints are lowered from the same node pipeline in `compiler/lib/MetaC/TypeSpec.pm`; codegen constraint checks (`range/wrap/size/sign`) consume node-query helpers in `compiler/lib/MetaC/Codegen/Facts.pm`, `compiler/lib/MetaC/Codegen/BlockStageDecls.pm`, `compiler/lib/MetaC/Codegen/BlockStageAssignLoops.pm`, and `compiler/lib/MetaC/Codegen/Compile.pm`; matrix runtime coordinate checks now honor wildcard matrix-size entries in `compiler/lib/MetaC/CodegenRuntime/Matrix.pm` and `compiler/lib/MetaC/CodegenRuntime/MatrixString.pm`. Coverage includes prior F-040 cases plus `constraint_matrix_size_wildcard_partial_ok`, `constraint_matrix_size_wildcard_oob_fail`, `constraint_matrix_dim_wildcard_default_ok`, and `constraint_matrix_size_wildcard_invalid_entry`; full suite green (`82 passed, 0 failed`).

### F-041 `Generic Array Type Model`
- Status: implemented
- Spec file: `instructions/normative-f041-array-model.md` (planned)
- Correctness classes: C0/C1/C2/C3
- Key guarantees: represent arrays as generic `array<T>`/`T[]` rather than fixed `number[]`/`string[]` special cases; type-check indexing and list operations from element type.
- Blocking questions: ownership/lifetime model for arrays of non-primitive element types in generated C.
- Notes/evidence: implemented a third element-specialized array model (`bool[]` -> `bool_list`) to establish non-number/string generic-array path while preserving existing number/string fast paths. Parser/type normalization and applicability accept `bool[]` in `compiler/lib/MetaC/TypeSpec.pm` and `compiler/lib/MetaC/Parser/Functions.pm`; runtime/container support is provided via `BoolList` + helpers in `compiler/lib/MetaC/CodegenRuntime/Prefix.pm`, `compiler/lib/MetaC/CodegenRuntime/Core.pm`, `compiler/lib/MetaC/CodegenRuntime/Lists.pm`, and `compiler/lib/MetaC/CodegenRuntime/Logging.pm`; element-aware indexing/size/destructure/for-each/push/log typing is wired in `compiler/lib/MetaC/Codegen/Expr.pm`, `compiler/lib/MetaC/Codegen/ExprMethodCall.pm`, `compiler/lib/MetaC/Codegen/BlockStageTry.pm`, `compiler/lib/MetaC/Codegen/ProofIter.pm`, `compiler/lib/MetaC/Codegen/LoopSupport.pm`, `compiler/lib/MetaC/Codegen/BlockStageDecls.pm`, `compiler/lib/MetaC/Codegen/BlockStageAssignLoops.pm`, and `compiler/lib/MetaC/Codegen/CompileParams.pm`. Coverage includes `bool_array_size_destructure`, `bool_array_for_each_count`, `bool_array_push`, and `diagnostic_bool_array_filter_unsupported`; suite remains green.

### F-042 `Number Semantics Policy Alignment`
- Status: draft
- Spec file: `instructions/normative-f042-number-semantics.md` (planned)
- Correctness classes: C1/C3/C4
- Key guarantees: explicitly reconcile normative number-domain statement with backend behavior; define approved numeric modes and diagnostics when a mode cannot preserve promised semantics.
- Blocking questions: whether rational semantics is mandatory in default mode now or staged behind an opt-in `exact-number` mode.
- Notes/evidence: Planned implementation: produce decision record with accepted numeric modes; add compiler mode flag and diagnostics for unsupported arithmetic guarantees; keep deterministic lowering per selected mode. Verification targets: mode-specific arithmetic tests, overflow/precision diagnostics, documentation sync with normative reference.

### F-043 `Union Return-Lowering Generalization`
- Status: implemented
- Spec file: `instructions/normative-f043-return-lowering.md` (planned)
- Correctness classes: C1/C2/C3/C4
- Key guarantees: remove hardcoded function return whitelist (`number | error`, `number`, `bool`); lower union returns via generalized tagged-result strategy compatible with call sites and handlers.
- Blocking questions: C ABI strategy for nested unions and strings without excessive copying.
- Notes/evidence: backend now supports generic union-return lowering over scalar members (`number`, `bool`, `string`, `error`, `null`) via `MetaCValue` plus specialized fast paths (`ResultNumber`, `ResultBool`, `ResultStringValue`) in `compiler/lib/MetaC/Codegen/Compile.pm` and runtime modules. Return typing and `?` propagation/fail-fast integrate across these modes in `compiler/lib/MetaC/Codegen/BlockStageControl.pm` and `compiler/lib/MetaC/Codegen/BlockStageDecls.pm`. Coverage includes `union_number_bool_forward`, `bool_error_return_try`, `bool_error_call_try_in_number`, `string_error_return_try`, and `string_error_try_failfast`; full compiler suite remains green.

### F-044 `Normative Conformance Harness + Percentage Gate`
- Status: draft
- Spec file: `instructions/normative-f044-conformance-harness.md` (planned)
- Correctness classes: C0/C1/C3/C4
- Key guarantees: trace every normative requirement to parser/type/codegen checks and tests; compute reproducible implementation percentage from machine-readable checklist.
- Blocking questions: denominator policy for open-ended normative items marked `...`.
- Notes/evidence: Planned implementation: create requirement matrix file (`requirement-id`, `status`, `tests`, `code refs`); add script that derives conformance percentage; integrate into CI/test run and expose deltas in release notes. Verification targets: deterministic percentage output, fail gate on regression of previously satisfied requirements.

### F-045 `Optional Extension: Effect-System Abstraction`
- Status: draft
- Spec file: `instructions/normative-f045-effect-abstraction.md` (planned)
- Correctness classes: C1/C3/C4
- Key guarantees: generalize fallibility from ad-hoc `error` union checks into effect annotations that can cover future non-error effects without grammar redesign.
- Blocking questions: whether to prioritize this immediately after `F-039` or defer until baseline normative parity is reached.
- Notes/evidence: Planned implementation: define minimal effect lattice (`pure`, `throws(error)`, extensible effect set); map current `?`/`or` behavior onto effect rules; keep source compatibility with existing syntax. Verification targets: effect inference/unit tests and backward-compatibility suite with current programs.

### F-046 `Loop Rewind Statement`
- Status: implemented
- Spec file: `day4b/dayb-spec.md`
- Correctness classes: C0/C1/C3
- Key guarantees: `rewind` restarts the current loop statement from its beginning; for `for-in` loops this recomputes the iterable and loop variable sequence against current outer state.
- Blocking questions: whether future normative scope should include/exclude `rewind` in all loop kinds or constrain it to `for-in` only.
- Notes/evidence: parser support added for `rewind` statements in `compiler/lib/MetaC/Parser/BlockParse.pm`; loop restart lowering added via per-loop rewind labels in `compiler/lib/MetaC/Codegen/Compile.pm`, `compiler/lib/MetaC/Codegen/ProofIter.pm`, and `compiler/lib/MetaC/Codegen/BlockStageAssignLoops.pm`; misuse diagnostic covered by `compiler/tests/cases/diagnostic_rewind_outside_loop.metac`; iterable recomputation behavior covered by `compiler/tests/cases/rewind_recomputes_iterable.metac`; full suite green (`97 passed, 0 failed`).

### F-047 `Compiler Architecture Split: Parser -> IR -> Correctness Gates -> Codegen`
- Status: draft
- Spec file: `instructions/ir-spec-f047.md`
- Correctness classes: C0/C1/C2/C3/C4
- Key guarantees:
  - implement the single Verified Normal-Form HIR (VNF-HIR) described in `instructions/ir-spec-f047.md` as the only accepted codegen input; parser/AST nodes must not be lowered directly to C.
  - preserve high-level constructs in HIR while making control-flow explicit via region exits (`Goto`, `IfExit`, `TryExit`, `ForInExit`, `WhileExit`, `Return`, `PropagateError`) and explicit region edges.
  - implement flowing fact state in HIR (`entryFacts`, `factsIn`, `factsOutByExit`) with deterministic transfer, merge, and loop-fixpoint behavior.
  - implement ownership semantics via explicit `Move`/`Copy`/`Borrow`/`EndBorrow`/`Drop`, including implicit temporaries from normalized exits (for example `ForInExit` iterable epochs) and guaranteed cleanup proofs on all reachable paths.
  - enforce correctness gates as hard blockers before C emission:
    - `Gate-CFG`: structurally valid region/edge graph with resolved targets.
    - `Gate-Type`: HIR type consistency and narrowing validity.
    - `Gate-Effect`: fallibility/effect flow consistency (`?`, `or catch`, fail-fast paths).
    - `Gate-Ownership`: no use-after-free, no double-free, and no leak on any reachable path.
    - `Gate-Lowering`: deterministic HIR->C mapping with reproducible output for identical normalized HIR.
    - `Gate-Traceability`: every accepted guarantee maps to check IDs + tests.
  - standardize compiler phase contracts:
    - parser outputs canonical AST with source spans.
    - AST->HIR lowering carries provenance metadata (`source span`, `type facts`, `constraint facts`, `effect facts`).
    - codegen accepts only verified HIR; unverified HIR must be rejected.
  - provide explainable failure output: diagnostics must cite failing gate/check and the originating source span.
- Blocking questions:
  - merge policy per fact kind at joins (for example type/effect/ownership meet strategy) should be fixed in spec text vs left to implementation notes.
  - whether to add optional `retain/release`-style nodes now or defer until a backend requires ref-count-specific lowering.
  - migration policy: feature-freeze during migration vs compatibility shim that allows old lowering for a bounded transition window.
  - proof tooling depth for first release: custom dataflow checks only vs SMT-backed obligations for selected gates.
- Notes/evidence:
  - Motivation: direct AST->C lowering has exposed correctness-risk regressions in control-flow/ownership interactions; this feature institutionalizes fact-checked, gate-validated lowering.
  - Initial implementation plan:
    - Phase 1: introduce VNF-HIR data structures (`Program`, `Function`, `Region`, `Edge`) and deterministic ID/order normalization.
    - Phase 2: lower AST statements/control-flow into VNF-HIR exits (`IfExit`/`TryExit`/`ForInExit`/`WhileExit`) with provenance + initial fact annotations.
    - Phase 3: implement fact transfer/merge/fixpoint engine and gate checks (`CFG`, `Type`, `Effect`, `Ownership`, `Lowering`, `Traceability`).
    - Phase 4: require verified HIR before codegen; retire direct AST->C lowering paths.
    - Phase 5: add conformance reporting (gate pass/fail matrix + requirement trace links).
  - Required verification artifacts:
    - adversarial CFG tests (loop back-edges, rewind, nested handlers, early returns, error edges).
    - ownership stress tests proving cleanup pairing for explicit and implicit owned values (including `ForInExit` iterable epochs).
    - deterministic-codegen snapshots from normalized VNF-HIR inputs.
    - migration parity suite: old vs new pipeline output/behavior equivalence where guarantees overlap.
