# Task Prompt: F-054-S6 Mechanical Fallibility and Or-Catch Lowering

Execute subtask `F-054-S6` unattended.

Objectives:
- keep fallibility handling mechanical in backend emission:
  - route `TryExit` via generated error-channel state instead of unconditional success,
  - emit `const_or_catch` and `expr_or_catch` statement kinds in backend C output,
- add only runtime glue required by emitted fallible operations (for this slice: regex-based `match`, parse-number error flagging),
- keep semantic policy ownership upstream (backend just consumes HIR contracts and fallibility shape).

Acceptance gate for this run:
1. syntax checks pass for backend/pipeline modules,
2. targeted fallibility slice passes:
   - `compiler/tests/cases/bool_error_return_try.metac`
   - `compiler/tests/cases/expr_stmt_nested_try_arg_push.metac`
   - `compiler/tests/cases/c730_or_catch_fallible_method_ok.metac`
   - `compiler/tests/cases/c742_lexical_match_capture_and_invalid_regex_handled_ok.metac`
3. generated C for this slice contains no `const_or_catch` / `expr_or_catch` backend-missing markers.
