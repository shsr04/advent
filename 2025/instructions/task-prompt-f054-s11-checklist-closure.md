# Task Prompt: F-054-S11 Full Checklist Closure

Execute this subtask unattended to close every remaining item in `instructions/post-checks-f053.md`.

Primary objectives:
1. Eliminate hardcoded intrinsic method-name branching in HIR-related modules by deriving behavior from `MetaC::HIR::OpRegistry` metadata/helpers.
2. Eliminate hardcoded scalar type-name branching in HIR-related modules by introducing/using data-driven type metadata (`MetaC::HIR::TypeRegistry`) and migrating callsites.
3. Continue de-duplication by extracting repeated backend/HIR logic into focused helper modules.
4. Complete `BackendC` split into `MetaC::Backend::*` modules so each file is small/readable.
5. Replace long `push @$out, ...` emission sequences with multiline block emission helpers where applicable.
6. Close remaining HIR completeness/functional checklist entries by implementing any missing centralization and validation steps.

Execution policy:
- iterate checklist items in order,
- after each major batch run syntax checks + `make test`,
- update checklist statuses with concrete completion notes only when actually complete.

Acceptance gate:
- all checklist entries are marked complete (`[x]`) with specific status notes,
- touched modules compile,
- `make test` remains fully green.
