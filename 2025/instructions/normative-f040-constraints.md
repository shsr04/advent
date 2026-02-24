# F-040 Normative Constraints

- Feature: `F-040 Constraint Engine V2`
- Status: implemented
- Date: 2026-02-24
- Scope: parsing, applicability validation, matrix-size linkage, wildcard semantics.

## Normative Alignment

This implementation aligns `with`-constraints with the normative reference section 2.3.

Supported constraint forms:
- `range(min,max)` where each arg is integer literal or `*`
- `wrap`
- `positive`
- `negative`
- `size(n)` where arg is integer literal or `*`
- `dim(n)` where arg is integer literal or `*`
- `matrixSize([a, b, ...])` where each element is integer literal or `*`

## Applicability Matrix

- `number`: `range`, `wrap`, `positive`, `negative`
- `string`, `number[]`, `string[]`: `size`
- `matrix(...)`: `dim`, `matrixSize`

Any other pairing is a compile error.

## Core Rules

- Duplicate occurrences of the same constraint are rejected.
- `positive` and `negative` together are rejected.
- `wrap` requires `range(min,max)` and both bounds must be concrete numbers.
- `range(min,max)` with both bounds concrete requires `min <= max`.
- `size(n)` requires `n >= 0` when concrete.
- `dim(n)` requires `n >= 2` when concrete.
- `matrixSize(...)` arity must match resolved matrix dimensions.
- `matrixSize` concrete entries must be positive; `*` leaves that dimension unconstrained.

## Wildcard Semantics

Wildcard `*` means "unconstrained for that argument".

Examples:
- `number with range(0,*)`: lower-bounded only.
- `string with size(*)`: unconstrained length (equivalent to no size bound).
- `matrix(number) with dim(*) + matrixSize([2,*])`: default/known dimensions with per-axis partial bounds.

## Implementation Notes

- Canonical internal representation uses typed constraint nodes (`constraints->{nodes}`).
- Parser/type/codegen consume node-query helpers instead of legacy scalar fields.
- Matrix constraints are integrated into the same typed-node parser and enforcement path.

## Evidence

Constraint coverage tests:
- `constraint_size_string_list_ok`
- `constraint_size_wildcard_ok`
- `constraint_size_requires_applicable_type`
- `constraint_size_duplicate_term`
- `constraint_size_runtime_assign_fail`
- `constraint_range_wildcard_lower_ok`
- `constraint_range_wildcard_upper_violation`
- `constraint_wrap_requires_bounded_range`
- `constraint_range_min_max_order`
- `constraint_matrix_plus_separator`
- `constraint_matrix_requires_matrix_type`
- `constraint_size_parameter_check`
- `constraint_matrix_size_wildcard_partial_ok`
- `constraint_matrix_size_wildcard_oob_fail`
- `constraint_matrix_dim_wildcard_default_ok`
- `constraint_matrix_size_wildcard_invalid_entry`
