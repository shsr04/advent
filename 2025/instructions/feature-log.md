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
