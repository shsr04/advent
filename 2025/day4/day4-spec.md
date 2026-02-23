Given this new input, I want to add first class support for multidimensional matrices.

Since we already have `<type>[]` as 1-dimensional arrays, it should be possible to extend this logic for new types. The normative syntax is as follows:

- type definition: `matrix(<type>) with dim(<dimensions>), matrixSize(<sizeSpec>)`
  - dimensions: must be at least 2 (must be known at compile time)
    - if no `dim` constraint is given, the default is 2.
  - sizeSpec: `number[] with size(<dimensions>)`, which specifies the size for each of the dimensions of the matrix.
      - if not given, the dimensions are unconstrained at compile time. This means that certain operations become fallible and need to be error checked.
- matrix methods:
  - `members()`: returns the members of the matrix, in ascending order.
    - For example, for a 2d matrix: in order 0,0; 0,1; 0,2; ...
    - Each member is an indexable value, i.e. we can call `<member>.index()` to get the coordinates of the member, e.g. `[0,2]`.
  - `insert(value: <type>, coords: number[] with size(<dimensions>): matrix`: sets a value in the matrix, and returns the matrix for chaining
    - if `matrixSize` constraint is not specified, this operation is fallible. In more detail:
      - On a matrix type with `matrixSize(...)` constraint, `insert` returns `matrix(...) with ...`.
      - On any other matrix type, `insert` returns `matrix(...) with ... | error`.
    - If an invalid index is accessed, this is an error.
  - `neighbours(index: number[] with size(<dimensions>)): <type>[]`: returns an array of all neighbours
    - if possible, add a min/max size constraint to the return type. Probably there is a formula for computing this based on `<dimensions>` at compile time
  - `log()`: as for other types, should print a human-friendly log
