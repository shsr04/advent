# Normative Reference of the MetaC language

- Status: **Normative**
- Scope: MetaC language syntactic structure and semantic contexts
- Last updated: 2026-02-23
- Implementation status: *55-60 % implemented*
- Keywords:
  - *specifies*: Indicates that a valid implementation must follow the given specified state of affairs.
  - *a/any*: Indicates that a valid implementation must ensure the state of affairs for all possible occurrences.
  - *is/are*: Indicates that a valid implementation must ensure the given entailment.
  - *can/cannot*: Indicates that a valid implementation must make the given state of affairs possible/impossible.
  - *must/must not*: Indicates that a valid implementation must enforce the given state of affairs.
  - *either ... or ... [or ...]*: Indicates that a valid implementation must allow only the given alternatives.
  - *... and ...*: Indicates that a valid implementation must ensure all of the alternatives.

## Preliminary

If not specified otherwise, a valid implementation *can* assume a semantic baseline based on the *C Programming Language Standard (ISO/IEC 9899:2024)*. 

## Syntax

This section *specifies* the syntactic structure of a parseable MetaC program.

- Program := DeclarationSeq
- DeclarationSeq := nil | Function DeclarationSeq
- Function := `function` Name ParamList TypeSpecOpt Scope
- Name := `[a-zA-Z_][a-zA-Z0-9_]*`
- ParamList := `(` ParamSeq? `)`
- ParamSeq := Param | Param `,` ParamSeq
- Param := Name TypeSpec
- TypeSpecOpt := TypeSpec?
- TypeSpec := `:` Type
- Type := `(` Type `)` | TypeIntersection
- TypeIntersection := SingleType | SingleType `|` Type
- SingleType := TypeName TypeConstraintList?
- TypeName := `number` | `int` | `float` | `string` | `boolean` | `null` | `error` | Type `[]` | `matrix(` Type `)`
- TypeConstraintList := `with` TypeConstraintSeq
- TypeConstraintSeq := TypeConstraint | TypeConstraint `+` TypeConstraintSeq
- TypeConstraint := Name TypeConstraintArgList?
- TypeConstraintArgList := `(` TypeConstraintArgSeq? `)`
- TypeConstraintArgSeq := TypeConstraintArg | TypeConstraintArg `,` TypeConstraintArgSeq
- TypeConstraintArg := (Expr | `*`)
- ArgList := `(` ArgSeq? `)`
- ArgSeq := Expr | Expr `,` ArgSeq
- Scope := `{` StatementSeq `}`
- StatementSeq := nil | Statement StatementSeqRest
- StatementSeqRest := nil | whitespace Statement StatementSeqRest
- Statement := Definition | Assignment | Conditional | Loop | LoopControl | Expr | Return
- Definition := (`let` | `const`) Name TypeSpecOpt `=` Expr
- Assignment := Name TypeSpecOpt (`=` Expr | `from` Scope)
- Conditional := `if` Expr Scope CondElse?
- CondElse := `else` (Conditional | Scope)
- Loop := ForLoop | WhileLoop
- ForLoop := `for` LoopIterator `in` Expr Scope
- LoopIterator := `const` Name TypeSpecOpt
- WhileLoop := `while` Expr Scope
- LoopControl := `break` | `continue` | `rewind`
- Return := `return` Expr?
- Expr := OrExpr
- OrExpr := AndExpr (`||` AndExpr)*
- AndExpr := EqExpr (`&&` EqExpr)*
- EqExpr := CmpExpr ((`==` | `!=`) CmpExpr)*
- CmpExpr := AddExpr ((`<` | `>` | `<=` | `>=`) AddExpr)*
- AddExpr := MulExpr ((`+` | `-`) MulExpr)*
- MulExpr := UnaryExpr ((`*` | `/` | `~/` | `%`) UnaryExpr)*
- UnaryExpr := `-` UnaryExpr | PrimaryExpr
- PrimaryExpr := AtomExpr ChainSeqOpt
- ChainSeqOpt := nil | ChainPart ChainSeqOpt
- ChainPart := `.` FunctionCall | IndexExpr
- IndexExpr := `[` Expr `]` ErrorHandler?
- AtomExpr := literal | `[` ArgSeq? `]` | FunctionCall | `(` Expr `)`
- FunctionCall := Name ArgList ErrorHandler?
- ErrorHandler := `?` | `or` (Expr | ErrorHandlerBlock)
- ErrorHandlerBlock := `catch` `(` LambdaArgSeq? `)` Scope
- Lambda := `(` LambdaArgSeq? `)` `=>` (Scope | Expr)
- LambdaArgSeq := Name | Name `,` LambdaArgSeq

## Semantic contexts

### 1. Functions

A function *is* a named block of executable statements.

The program execution begins at the function `main(): int`. The return value of `main` determines the exit code of the program.

When a function does not specify a return type, it returns no value. The exception is `main`, which implicitly returns `int`.
A function without a return type *can* use the `return` statement to exit early.
A function with a return type *must* return a conformant value in all of its execution paths.

### 1.1 Fluent function invocation

A function with at least 1 parameter *can* be invoked *either* by function-style invocation *or* by method-style invocation.
- Function-style invocation has the form: `<name>(<arg1>, <arg2>, ...)`
- Method-style invocation has the form: `<arg1>.<name>(<arg2>, ...)`

Both forms are functionally equivalent.

This implies that the program *can* define a custom function and then call it fluently, using method-style invocation.
For example:
- Define function: `function f(x: number, y: number): number { ... }`
- Call with method-style invocation: `x.f(y)`
  - Or even with literal values: `0.f(1)` (equivalent to `f(0,1)`)

### 2. Types

A type *consists of* a value domain and a set of operations.

The available types *are*:
- `number` = `int | float`
- `int`
  - Domain: all integer numbers
  - Operations: mathematical + comparison
- `float`
  - Domain: all rational numbers
  - Operations: mathematical + comparison
- `boolean`
  - Domain: `true`, `false`
  - Operations: logical + comparison
- `string`
  - Domain: all UTF-8 character sequences
  - Operations: sequence-based + lexical + comparison
- `error`
  - Domain: error objects with `{ message: string }`
  - Operations: access `message`
- `null`
  - Domain: `null`
  - Operations: comparison
- Array (`<type>[]`)
  - Domain: all sequences of the given base type
  - Operations: sequence-based + comparison
- Matrix (`matrix(<type>)`)
  - Domain: all matrices of the given base type and dimensions
  - Operations: matrix-based + comparison

The program must not refer to an unknown type.

### 2.1 Type intersections

A type intersection *is* the exclusive selection between two or more distinct types. This means that a type intersection acts like the indeterminate subset of each of its members. This holds until some subsequent statement "unwraps" the type intersection to access a member explicitly.

The program must not access operations on a type intersection which are not provided by *all* of the member types.

### 2.2 Constraints

A constraint *consists of* a constraint name and a list of zero or more constraint parameters.
Whenever a constraint is applied to a type, a new type is created which constrains the domain or the behaviour of the original type.
A constraint applies only to a given set of types.

The built-in constraints are the following:
- `size(n: int)`
  - Applies to: string, array
  - Constrains the domain to types of length `n`
- `range(min: number, max: number)`
  - Applies to: number
  - Constrains the domain to `[min,max]` inclusively
- `positive`
  - Applies to: number
  - Constrains the domain to `n > 0`
- `negative`
  - Applies to: number
  - Constrains the domain to `n < 0`
- `wrap`
  - Applies to: number
  - Causes wrap-around behaviour when the value goes out of range
- `dim(n: int)`
  - Applies to: matrix
- `matrixSize(n: int[] with size(<dimensions>))`
  - Applies to: matrix

A type *cannot* have multiple occurrences of the same constraint.
For example:
- `number with range(0,100) + wrap` is valid
- `number with range(0,100) + range(20,30)` is invalid
- `string with size(2) + size(2)` is invalid

*Any* constraint can be partially specified by using constraint wildcards (using the `*` keyword). A constraint wildcard is equivalent to leaving the given constraint parameter undefined, therefore making the type unconstrained in this respect.
For example:
- `number with range(0,100)` is a number from 0 to 100
- `number with range(0,*)` is a number at least 0
- `string with size(*)` is a string with any size (equivalent to `string`)

The program must not apply constraints to a type which does not support the constraint.

### 2.3 Implicit type conversions

Implicit type conversion *can* occur in the following cases:
- supplying a function argument with a different type than specified in the parameter list
- defining a variable with a different type than the assigned-expression type
- reassigning a variable with a new type
- supplying operands with different types to an operation 

A type *can* be implicitly converted to another *either* if the types are effectively the same *or* if the new type is less constrained than the old type.
For example:
- `number with range(0,10)` can be implicitly converted to `number`
- `number with range(0,10)` can be implicitly converted to `number with range(1,10)`
- `number with range(0,10)` can be implicitly converted to `number with range(0,50)`
- `number with range(0,10) + wrap` cannot be implicitly converted to `number with range(0,10)`
- `number with wrap` cannot be implicitly converted to `number with range(0,10)`
- `number` cannot be implicitly converted to `number with range(0,10)`

### 2.4 Type entailment

Type entailment occurs when a statement implicitly constrains the domain of a type in a given scope. When such an entailment occurs, the type is implicitly converted to a new, more constrained type in that scope.

Type entailment *can* occur in the following constructs:
- Conditional statement:
  - `if n > 2 { ... }` entails that `n > 2` holds in this scope
  - `if n < 0 { return false } ...` entails that `n >= 0` holds in the subsequent statements
  - `for const i in seq(1,10) { ... }` entails `i: number with range(1,10)`

Type entailment can occur *either* for immutable variables *or* for mutable variables that are effectively unmodified in the respective scope.

### 3. Mutability

Variables are *either* mutable *or* immutable.

An immutable variable *cannot* be reassigned, nor *can* any of its inner properties (in the case of complex types) be modified.
A mutable variable *can* be reassigned and modified.

### 4. Fallibility

An expression *is* fallible if its type contains the error type. Otherwise, it *is* infallible.

There are two ways to handle fallible expressions:
- Error propagation (using `?` keyword): This *is* equivalent to returning the error from the enclosing function.
- Error catch handler (using `or` expression): This handles the error, using the supplied handler, *in the scope of the enclosing function*.

Error handling *cannot* be applied to an infallible expression.

The program must handle *all* fallible expressions.

The program must not use error propagation if the enclosing function has a non-`error` return type, except in the `main` function. In the `main` function, error propagation causes a non-zero exit code of the program.

### 5. Built-in operations

The program must not perform invalid operations, as *specified* in this section.

The program must not produce a runtime error for operations which are not explicitly marked as fallible by having an `error`-containing return type.

### 5.1 Comparison operations

A comparison operation *can* only occur between two operands which share at least one basic type. Two operands are equal if they contain exactly the same values. Otherwise, they are not equal.

### 5.2 Mathematical operations

When adding, subtracting or multiplying two numbers, the result type is determined by the operand types.
- Two `int` operands produce an `int` result.
- Two `float` operands produce a `float` result.
- Two `number` operands produce a `number` result.
- Any other combination is invalid.

When dividing two numbers, the behaviour is determined by the used operand.
- Floating-point division (using `/` operand): divides the numbers, producing a `float` result.
  - Signature: `/(float,float): float`
- Integer division (using `~/` operand): divides the numbers and drops the decimal fraction (if any), producing a `int` result.
  - Signature: `~/(int,int): int`

The program must:
- use only matching operand types for arithmetic operations
- use floating-point division where both operands are of type `float`
- use integer division where both operands are of type `int`
- not use division in any other case

### 5.3 Logical operations

A logical operation can only be applied to expressions of `boolean` type.

The evaluation order is from left to right. If an operand has been evaluated such that the other part of the logical operation is unreachable, the program must short-circuit and skip evaluation of the other part.

### 5.4 Sequence-based operations

The following operations are available on sequence-based types `S: <type>[] with size(<size>)`:
- `S[<index-expr: int>]: <type> [| error]`
  - Returns the element at `<index-expr>`.
  - Fallible: exactly if `S` has no constraint determining its size, therefore making `<index-expr>` possibly out of bounds.
- `<type>.index(): int with range(0,<size>-1)`
  - Returns the index of the element originating from a sequence.
  - This operation is not available if the value cannot be traced back to a source sequence.
- `S.size(): int with exact(<size>)`
  - Returns the number of elements in the sequence.
- `S.append(<arg: type | type[]>): <type>[] with size(<new-size>)`
  - Returns the sequence, with the given element(s) appended after the end.
- `S.prepend(<arg: type | type[]>): <type>[] with size(<new-size>)`
  - Returns the sequence, with the given element(s) prepended before the start.
- `S.head(): <type> [| error]`
  - Returns the first element of the sequence.
  - Fallible: exactly if `S` has no constraint ensuring `S.size() > 0`.
- `S.last(): <type> [| error]`
  - Returns the last element of the sequence.
  - Fallible: exactly if `S` has no constraint ensuring `S.size() > 0`.
- `S.map(<mapper>): S [| error]`
  - Returns the sequence, where each element `x` has been replaced by the result of `<mapper>(x)`.
  - Fallible: exactly if `<mapper>` is fallible.
- `S.filter(<filter>): S [| error]`
  - Returns the sequence, where an element `x` is dropped exactly if `<filter>(x) == false`.
  - Fallible: exactly if `<filter>` is fallible.
- `S.any(<predicate>): boolean [| error]`
  - Returns true exactly if any element satisfies `<predicate>`.
  - Fallible: exactly if `<predicate>` is fallible.
- `S.all(<predicate>): boolean [| error]`
  - Returns true exactly if all elements satisfy `<predicate>`.
  - Fallible: exactly if `<predicate>` is fallible.
- `S.reduce(<initial: type>, <reducer>): <result: type> [| error]`
  - Returns the result, obtained by applying `<reducer>` to each of the elements and accumulating them into a single value. The initial value is given by `<initial>`.
  - Fallible: exactly if `<reducer>` is fallible.
- `S.scan(<initial: type>, <scanner>): S [| error]`
  - Returns the sequence of results of successively applying `<scanner>` to the elements and accumulating them. The initial value is given by `<initial>`.
  - Fallible: exactly if `<scanner>` is fallible.
- `S.reverse(): S`
  - Returns the sequence in reverse order.
- `S.chunk(<size: number>): <type>[][]`
  - Returns the sequence, divided into chunks of size at most `size`. If the sequence cannot be split evenly, the last chunk contains the remaining elements.
- ...

### 5.5 Lexical operations

The following operations are available on character sequences `S: string`:
- `S.chars(): string[]`
  - Returns the UTF-8 characters of the string.
- `S.match(<regex>): string[] | error`
  - Returns the list of captured values of the matched Regular Expression. If no capture groups are given, returns a single-element list of the entire matched string.
  - Fallible: fails when the supplied RegEx is invalid.
- `S.split(<delimiter: string>): string[]`
  - Returns the parts of the string, obtained by splitting at `<delimiter>`.
- `S.isBlank(): boolean`
  - Returns true exactly if the string consists entirely of whitespace.

### 5.6 Matrix operations

The following operations are available on matrix types `M: matrix(<type>) with dim(<dim>) + matrixSize(<sizes>)`:
- `M.members(): <type>[] with size(<sum(sizes)>)`
  - Returns the members in sequential order, iterating over the highest dimension first, then incrementing the second-highest, and so on.
- `<type>.neighbours(): <type>[]`
  - Returns the neighbours of the given member.
  - This operation is not available if the member cannot be traced back to a source matrix.
- `<type>.index(): int[] with size(<dim>)`
  - Returns the coordinates of the member.
  - This operation is not available if the member cannot be traced back to a source matrix.
- `M.insert(<value: type>, <index: int[] with size(<dim>)>): M [| error]`
  - Inserts the value at the given index, modifying the matrix in place. Returns the matrix for chaining.
  - Fallible: exactly if `<sizes>` cannot be inferred, thus making the matrix unconstrained.
- `M.size(<n: int with range(0, <dim-1>)>): int [| error]`
  - Returns the actual size of the `<n>`th dimension of the matrix, starting with 0.
  - Fallible: exactly if `<dim>` cannot be inferred, thus making `<n>` possibly out of bounds.
