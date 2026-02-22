Given this new input, I want to add first class support for multidimensional matrices.

Since we already have `<type>[]` as 1-dimensional arrays, it should be possible to extend this logic for new types. The normative syntax is as follows:

- type definition: `matrix(<type>) with dim(<dimensions>)`
  - dimensions: must be at least 2 (must be known at compile time)
  - if no `dim` constraint is given, the default is 2-dimensional.
- matrix methods:
  - `neighbours(index: number[] with size(<dimensions>)): <type>[]`: returns an array of all neighbours
    - if possible, add a min/max size constraint to the return type. Probably there is a formula for computing this based on `<dimensions>` at compile time
  - `log()`: as for other types, should print a human-friendly log
