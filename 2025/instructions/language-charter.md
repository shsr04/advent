# Language Charter

## Working Name

`MetaC` (placeholder)

## Mission

Design a high-level meta language that compiles to C while preserving formally stated correctness constraints.

## Primary Objectives

- Compile predictably to portable C.
- Enable strong static guarantees (safety, invariants, totality where required).
- Keep runtime overhead low and generated C auditable.
- Make proofs and checks part of normal development, not an afterthought.

## Non-Goals (Initial)

- JIT/runtime VM dependency.
- Hidden global state in core language semantics.
- Undefined behavior inheritance from source constructs.

## Core Invariants

- Every source construct has deterministic lowering to an intermediate representation (IR).
- Every IR construct has deterministic lowering to C.
- Type and effect constraints are decidable at compile time for accepted programs.
- Any rejected program must have a traceable reason in the constraint/proof pipeline.

## Threat Model for Correctness

- Miscompilation from source to C.
- Violation of user-declared invariants.
- Memory/aliasing unsoundness introduced during lowering.
- Non-deterministic behavior from unspecified evaluation order.

## Acceptance Criteria for "Correct"

A feature is considered correct only when:

1. Its syntax and static semantics are specified.
2. Its dynamic semantics or equivalent operational behavior is specified.
3. Its lowering rule(s) to IR and C are specified.
4. Required proof obligations are listed and validated by defined checks.
5. At least one adversarial test case is included.
