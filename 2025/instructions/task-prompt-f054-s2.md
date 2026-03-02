# Task Prompt: F-054-S2 Scalar/Control Emitters

Execute subtask `F-054-S2` unattended.

Objectives:
- keep the backend purely mechanical over HIR contracts,
- complete scalar expression and statement emitter coverage for:
  - expr: `num`, `str`, `bool`, `null`, `ident`, `unary`, `binop`,
  - stmt: `let`, `const`, `assign`, `assign_op`, `incdec`, `return`, `expr_stmt`,
  - exits: `Goto`, `IfExit`, `WhileExit`, `Return`,
- ensure deterministic emission templates and stable region ordering.

Acceptance gates for this run:
1. syntax checks for backend/pipeline modules pass,
2. targeted scalar/control cases compile and run green:
   - `compiler/tests/cases/c302_mutable_while_reassignment_ok.metac`
   - `compiler/tests/cases/c701_main_return_exit_code.metac`
   - `compiler/tests/cases/c738_math_add_sub_mul_homogeneous_ok.metac`
3. generated C for those cases contains no `Backend/F054 missing expr emitter` or `Backend/F054 missing stmt emitter` markers for covered kinds.
