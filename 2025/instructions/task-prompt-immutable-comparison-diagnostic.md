# Immutable-Comparison Diagnostic Prompt

Add a compiler diagnostic that rejects loop conditions when comparison expressions depend only on immutable values.

Goal:

- Prevent non-terminating loops like `while base > 0` where `base` is immutable.

Constraints:

- Keep behavior generic and static (compile-time check).
- Do not rely on day/domain-specific names.
