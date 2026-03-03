# F-053 post implementation checklist

## Code quality

- Make sure no method names are hardcoded in the `HIR` module (in manual if-branches or similar). All logic should derive from the data-driven `OpRegistry` (source of truth).
- Make sure no type names are hardcoded in the `HIR` module, use a data-driven approach, similar to the method registry.
- Remove duplicate code branches where possible, extract common logic to helper functions operating on data hashes. 
- Split the `BackendC` module into multiple files under `MetaC::Backend::*`. Each file should be small and readable.
- Instead of long `push @$out, ...` lines, it would be better to have multiline strings for code blocks, which are then split at newlines, if pushing line by line is necessary.

## HIR completeness

- Is the `SemanticChecks[Expr]` module contributing to the HIR output? The goal is that the HIR contains *all* of the code evaluation and HIR construction artifacts, in order to provide an "over-complete" code execution graph. Then, backend X may or may not make use of the HIR nodes to produce its target output.
- Is ownership information transferred and handled correctly? In backend, ensure: each malloc/calloc/realloc must be matched with a free at the end of the lifetime of the underlying memory. Suggestion: use `valgrind` for verification.

## Functional notes

- String templates should support arbitrary expressions (AST node `Expr`). Is this implemented?
- Add line numbers and snippets to all compiler error messages. Centralize error message output into a common helper.
