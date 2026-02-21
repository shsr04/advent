# Correctness Framework

## 1) Proof Strategy

Use layered assurance:

1. **Language-level guarantees** from syntax + static semantics.
2. **IR invariants** preserved by source-to-IR lowering.
3. **Backend invariants** preserved by IR-to-C lowering.
4. **Executable checks** (tests, property checks, differential tests).

No feature skips a layer.

## 2) Minimum Formal Artifacts Per Feature

- Precise typing/constraint rules.
- Small-step or equivalent behavioral specification (or total denotational equivalent).
- Lowering theorem statement (informal + checkable approximation).
- Soundness checklist for generated C assumptions.

## 3) Compiler Verification Gates

A feature cannot move to `verified` unless all gates pass:

1. **Spec Gate**: syntax, semantics, lowering, and guarantee sections complete.
2. **Constraint Gate**: compile-time checks enforce stated invariants.
3. **Lowering Gate**: generated IR/C satisfies documented invariants.
4. **Adversarial Gate**: hostile examples fail safely or are rejected.
5. **Regression Gate**: existing guarantees remain intact.

## 4) Correctness Classes

- `C0` Structural: parser/AST/well-formedness checks.
- `C1` Type Safety: no type-rule violations in accepted programs.
- `C2` Memory/Aliasing: no UB introduced by lowering model assumptions.
- `C3` Semantic Preservation: behavior preserved from source to generated C.
- `C4` Totality/Termination (optional per feature): where explicitly promised.

Each feature must declare target class coverage.

## 5) Traceability Rules

Every guarantee must map to:

- one or more compile-time checks,
- one or more tests/proof artifacts,
- one or more lowering assumptions.

If a guarantee cannot be traced, it is removed or downgraded.

## 6) Initial Tooling Direction (Adjustable)

- Constraint solving: SMT-backed checks for non-trivial predicates.
- IR validator pass before C emission.
- Deterministic codegen mode for reproducible diffs.
- Proof/log output mode to explain acceptance/rejection.

## 7) Definition of Done (Per Feature)

- Spec completed with no unresolved blockers.
- Implementation merged with deterministic output tests.
- Correctness gates all green.
- Feature documented in `feature-log.md` with evidence links/notes.
