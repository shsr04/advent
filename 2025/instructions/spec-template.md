# Feature Spec Template

Copy this template for each language feature.

---

# Feature: `<name>`

## 1) Summary

- Problem this feature solves:
- Why now:
- Expected impact:

## 2) User-Facing Syntax

- Grammar additions:
- Examples:
- Invalid examples:

## 3) Static Semantics

- Type rules:
- Constraint rules:
- Effect/resource rules (if any):
- Compile-time rejection conditions:

## 4) Runtime/Operational Semantics

- Evaluation model:
- Order of evaluation:
- Error behavior:
- Determinism notes:

## 5) Lowering Rules

### 5.1 Source -> IR

- Transformation rules:
- Required metadata carried forward:

### 5.2 IR -> C

- C patterns emitted:
- Mapping of lifetimes/ownership/aliasing:
- UB avoidance strategy:

## 6) Correctness Contract

- Stated guarantees:
- Assumptions:
- Proof obligations:
- What is intentionally not guaranteed:

## 7) Verification Plan

- Static checks:
- Proof artifacts (SMT/assistant/manual proof sketch):
- Test plan:
- Differential or metamorphic tests:

## 8) Performance and Ergonomics

- Compile-time cost:
- Runtime cost in generated C:
- Expected user complexity:

## 9) Open Questions

- Q1:
- Q2:

## 10) Status

- Stage: `draft | review | accepted | implemented | verified`
- Owner:
- Last updated:
