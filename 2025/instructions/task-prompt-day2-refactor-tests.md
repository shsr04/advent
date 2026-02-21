# Day2 Compiler Refactor + Test Harness Prompt

Refactor the Perl MetaC compiler into multiple readable modules while preserving current behavior.

Deliverables:
1. Split compiler implementation into parser/codegen/shared utility modules under `compiler/lib/MetaC/`.
2. Keep `compiler/metac.pl` as a thin CLI entrypoint.
3. Update build dependencies so changing compiler modules triggers regeneration from `.metac -> .c -> binary`.
4. Add a tracked compiler test suite under `compiler/tests/` with both compile+run success cases and compile-fail diagnostics.
5. Provide a `make` target to run compiler tests and document how to run them.
