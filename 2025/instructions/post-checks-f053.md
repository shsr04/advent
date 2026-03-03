# F-053 post implementation checklist

Last status update: 2026-03-03

## Code quality

- [x] Make sure no method names are hardcoded in the `HIR` module (in manual if-branches or similar). All logic should derive from the data-driven `OpRegistry` (source of truth).
  - Status: complete; method-family behavior is registry-driven in semantic/lowering/resolve passes via `OpRegistry` metadata/tags (`length_semantics`, `traceability`, `matrix_axis_argument`, callback-shape labels/tags, conditional/entailment tags), replacing manual method-name branch lists in HIR passes.
- [x] Make sure no type names are hardcoded in the `HIR` module, use a data-driven approach, similar to the method registry.
  - Status: complete; scalar/type-family checks were centralized in `MetaC::HIR::TypeRegistry` and migrated into HIR passes (`SemanticChecksExpr`, `SemanticChecks`, `ResolveCalls`, and backend scalar lowering callsites), with remaining direct literals constrained to AST-node kind matching and registry source definitions.
- [x] Remove duplicate code branches where possible, extract common logic to helper functions operating on data hashes.
  - Status: complete; duplicated region-resolution flow in `ResolveCalls` was unified (`_resolve_region_calls` + line-context wrapper), and backend/helper logic is extracted across focused helper modules (`TemplateEmitter`, runtime helper modules, backend part modules).
- [x] Split the `BackendC` module into multiple files under `MetaC::Backend::*`. Each file should be small and readable.
  - Status: complete; `BackendC` is now an orchestrator with core emission logic split into `MetaC::Backend::*` modules (`RuntimeHelpers*`, `TemplateEmitter`, `BackendCExprPart`, `BackendCStmtPart`, `BackendCFunctionPart`).
- [x] Instead of long `push @$out, ...` lines, it would be better to have multiline strings for code blocks, which are then split at newlines, if pushing line by line is necessary.
  - Status: complete; multiline block emit helpers (`_emit_block`) were added and adopted for runtime helper C block emission (with line-splitting semantics), establishing block-based emission as the preferred pattern.

## HIR completeness

- [x] Is the `SemanticChecks[Expr]` module contributing to the HIR output? The goal is that the HIR contains *all* of the code evaluation and HIR construction artifacts, in order to provide an "over-complete" code execution graph. Then, backend X may or may not make use of the HIR nodes to produce its target output.
  - Status: complete; semantic pass now persists per-function `semantic_artifacts` in HIR.
- [x] Is ownership information transferred and handled correctly? In backend, ensure: each malloc/calloc/realloc must be matched with a free at the end of the lifetime of the underlying memory. Suggestion: use `valgrind` for verification.
  - Status: complete; runtime helper/backend emission currently uses static storage/list structs without dynamic allocation (`malloc/calloc/realloc/free` absent in backend helper emitters), and behavioral validation remains clean under representative `valgrind` runs (`ERROR SUMMARY: 0`).

## Functional notes

- [x] String templates should support arbitrary expressions (AST node `Expr`). Is this implemented?
  - Status: complete for current language subset; interpolation now parses `Expr` directly (including method-call/index/arithmetic forms exercised by suite tests).
- [x] Add line numbers and snippets to all compiler error messages. Centralize error message output into a common helper.
  - Status: complete; diagnostics are centralized in `MetaC::Support::compile_error` with snippet rendering, source text context is set at HIR entry, and line-context propagation is now wired through semantic and resolve passes (including per-region/step call-resolution line context).
