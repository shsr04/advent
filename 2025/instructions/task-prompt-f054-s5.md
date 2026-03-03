# Task Prompt: F-054-S5 Sequence/List/Matrix Structural Operations

Execute subtask `F-054-S5` unattended.

Objectives:
- extend `HIR::BackendC` with mechanical structural support for backend-reachable collection operations:
  - list literal emission (`[]`, `[a,b,...]`) into backend runtime list structures,
  - list method calls (`push`, `size`) from resolved method contracts,
  - list destructuring assignment (`const [a,b,...] = list`) in statement emission,
  - `for-in` iteration over list variables via deterministic CFG-label lowering.
- preserve synthetic backend constraints (no backend semantic policy checks).
- keep helper emission usage-driven from emitted operation footprint.

Acceptance gate for this run:
1. syntax checks pass for backend/pipeline modules,
2. targeted structural slice passes:
   - `compiler/tests/cases/bool_array_push.metac`
   - `compiler/tests/cases/bool_array_size_destructure.metac`
   - `compiler/tests/cases/list_push_mutable_number.metac`
   - `compiler/tests/cases/c224_matrix_boolean_domain_ok.metac`
3. generated C for this slice contains no structural backend placeholder markers.
