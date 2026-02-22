# Task Prompt: Add `reduce()` Support

Goal: implement first-class compiler support for list `reduce()` in MetaC so programs like day3b can compile and run without ad-hoc rewrites.

Scope:
- Parse and represent reducer lambdas needed by `reduce` (two-parameter lambdas).
- Add semantic/codegen support for `list.reduce(initial, (acc, item) => expr)`.
- Ensure type expectations are explicit and diagnostics are clear for invalid usages.
- Keep implementation modular and readable, consistent with recent code split.
- Add regression tests covering success and failure cases.

Constraints:
- Preserve existing behavior for `map`, `filter`, and other list methods.
- Prefer minimal changes to AST contracts unless necessary.
- Follow current runtime model and C backend conventions.

Validation:
- Run compiler test suite (`make test`).
- Build/verify day3b path that currently depends on `reduce`.

Deliverable:
- Working `reduce()` compiler feature with tests and passing suite.
