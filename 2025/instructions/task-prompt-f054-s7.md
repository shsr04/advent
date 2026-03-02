# Task Prompt: F-054-S7 Semantic/Backend Boundary Hardening

Execute subtask `F-054-S7` unattended.

Objectives:
- validate backend purity constraints (no backend policy-helper logic such as `type_is_*` shape checks),
- add explicit malformed-HIR passthrough fixtures that invoke `HIR::BackendC` directly and assert:
  - malformed HIR does not cause backend rejection,
  - emitted C includes structural missing-emitter diagnostics for malformed nodes.

Acceptance gate for this run:
1. backend purity check passes (`type_is_*` absent from backend/materialization surfaces),
2. malformed-HIR passthrough fixture script passes with non-zero fixture coverage,
3. fixture output confirms missing-emitter diagnostics are present in generated C.
