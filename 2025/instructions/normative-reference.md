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
  - *either ... or ... [or ...]*: Indicates that a valid implementation must allow only the given alternatives.

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
- Type := `(` Type `)` | TypeUnion
- TypeUnion := SingleType | SingleType `|` Type
- SingleType := TypeName TypeConstraintList?
- TypeName := `number` | `string` | `error` | ...
- TypeConstraintList := `with` TypeConstraintSeq
- TypeConstraintSeq := TypeConstraint | TypeConstraint `+` TypeConstraintSeq
- TypeConstraint := Name ArgList?
- ArgList := `(` ArgSeq? `)`
- ArgSeq := Expr | Expr `,` ArgSeq
- Scope := `{` StatementSeq `}`
- StatementSeq := nil | Statement StatementSeqRest
- StatementSeqRest := nil | whitespace Statement StatementSeqRest
- Statement := Definition | Assignment | Conditional | Loop | Return
- Definition := (`let` | `const`) Name TypeSpecOpt `=` Expr
- Assignment := Name TypeSpecOpt `=` Expr
- Conditional := `if` Expr Scope CondElse?
- CondElse := `else` (Conditional | Scope)
- Loop := ForLoop | WhileLoop
- ForLoop := `for` LoopIterator `in` Expr Scope
- LoopIterator := `const` Name TypeSpecOpt
- WhileLoop := `while` Expr Scope
- Return := `return` Expr
- Expr := OrExpr
- OrExpr := AndExpr (`||` AndExpr)*
- AndExpr := EqExpr (`&&` EqExpr)*
- EqExpr := CmpExpr ((`==` | `!=`) CmpExpr)*
- CmpExpr := AddExpr ((`<` | `>` | `<=` | `>=`) AddExpr)*
- AddExpr := MulExpr ((`+` | `-`) MulExpr)*
- MulExpr := UnaryExpr ((`*` | `/` | `~/` | `%`) UnaryExpr)*
- UnaryExpr := `-` UnaryExpr | PrimaryExpr
- PrimaryExpr := AtomExpr ChainSeqOpt
- ChainSeqOpt := nil | ChainPart ErrorHandler? ChainSeqOpt
- ChainPart := `.` Name ArgList | `[` Expr `]`
- AtomExpr := literal | `[` ArgSeq? `]` | Name CallOpt | `(` Expr `)`
- CallOpt := nil | ArgList ErrorHandler?
- ErrorHandler := `?` | `or` Lambda
- Lambda := `(` LambdaArgSeq? `)` `=>` (Scope | Expr)
- LambdaArgSeq := Name | Name `,` LambdaArgSeq
- ...

## Semantic contexts

### Function

A function *is* a named block of executable statements.

The program execution begins at the function `main(): number`. The return type of `main` determines the exit code of the program.

### Types

The available types *are*: number, float, int, string, error, null, array, matrix.

*Each* type has *a* value domain and *a* set of operations.
- Number: `int | float`
- Int
  - Domain: all integer numbers
  - Operations: mathematical + comparison
- Float
  - Domain: all rational numbers
  - Operations: mathematical + comparison
- String
  - Domain: all UTF-8 character sequences
  - Operations: sequence-based + character-specific + comparison
- Error
  - Domain: error objects with `{ message: string }`
  - Operations: access `message`
- Null
  - Domain: `null`
  - Operations: comparison
- Array
  - Domain: all sequences of the given base type
  - Operations: sequence-based + comparison
- Matrix
  - Domain: all matrices of the given base type and dimensions
  - Operations: matrix-based + comparison

*A* type union *is* the exclusive selection between two or more distinct types. This means that a type union acts like the indeterminate subset of each of its members. This holds until some subsequent statement "unwraps" the union to access a member explicitly.

### Type conversions

Type conversion *can* occur in the following cases:
- supplying a function argument with a different type than specified in the parameter list
- defining a variable with a different type than the assigned-expression type
- reassigning a variable with a new type

A type *can* be converted to another *only if* the new type is more constrained than the old type.
For example:
- `number` can be converted to `number with range(0,100)`
- `number with range(0,100)` can be converted to `number with range(1,10)`
- `number with range(0,100)` cannot be converted to `number with range(0,500)`
- `number with wrap` cannot be converted to `number with range(0,100)`
- `number with range(0,100) + wrap` cannot be converted to `number with range(0,100)`

### Constraints

Whenever a constraint is applied to a type, a new type *is* created which constrains the domain or the behaviour of the original type.
*Each* constraint has given types to which it can apply.

The built-in constrains are the following:
- `size(n: number)`
  - Applies to: string, array
  - Constrains the domain to types of length `n`
- `range(min: number, max: number)`
  - Applies to: number
  - Constrains the domain to `[min,max]` inclusively
- `wrap`
  - Applies to: number
  - Causes wrap-around behaviour when the value goes out of range
- `dim(n: number)`
  - Applies to: matrix
- `matrixSize(n: number[] with size(<dimensions>))`
  - Applies to: matrix

### Mutability

Variables are *either* mutable *or* immutable.

An immutable variable *cannot* be reassigned, nor *can* any of its inner properties (in the case of complex types) be modified.
A mutable variable *can* be reassigned and modified.

### Fallibility

An expression *is* fallible if its type contains the error type. Otherwise, it *is* infallible.

A fallible construct is handled in two ways:
- Error propagation (using `?` keyword): This *is* equivalent to returning the error from the enclosing function.
- Error handler (using `or` expression): This handles the error, using the supplied handler, *in the scope of the enclosing function*.

Error propagation *can* only be used if the enclosing function has a `error`-containing return type, or in the `main` function. In the `main` function, it causes a non-zero exit code of the program.

### Arithmetics

When dividing two numbers, the behaviour is determined by the used operand.
- Floating-point division (using `/` operand): divides the numbers, producing a `float` result.
- Integer division (using `~/` operand): divides the numbers and drops the decimal fraction (if any), producing a `int` result.
