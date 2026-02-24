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
- TypeName := (-> see 2.)
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
- Statement := Definition | Assignment | Conditional | Loop | LoopControl | Return
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
- ChainSeqOpt := nil | ChainPart ErrorHandler? ChainSeqOpt
- ChainPart := `.` Name ArgList | `[` Expr `]`
- AtomExpr := literal | `[` ArgSeq? `]` | Name CallOpt | `(` Expr `)`
- CallOpt := nil | ArgList ErrorHandler?
- ErrorHandler := `?` | `or` (Expr | ErrorHandlerBlock)
- ErrorHandlerBlock := `catch` `(` LambdaArgSeq? `)` Scope
- Lambda := `(` LambdaArgSeq? `)` `=>` (Scope | Expr)
- LambdaArgSeq := Name | Name `,` LambdaArgSeq

## Semantic contexts

### 1. Functions

A function *is* a named block of executable statements.

The program execution begins at the function `main(): number`. The return value of `main` determines the exit code of the program.

When a function does not specify a return type, it returns no value. The exception is `main`, which implicitly returns `number`.
A function without a return type *can* use the `return` statement to exit early.
A function with a return type *must* return a conformant value in all of its execution paths.

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
  - Operations: sequence-based + character-specific + comparison
- `error`
  - Domain: error objects with `{ message: string }`
  - Operations: access `message`
- `null`
  - Domain: `null`
  - Operations: comparison
- Array (`<type>[]`)
  - Domain: all sequences of the given base type
  - Operations: sequence-based + comparison
- Matrix (`matrix(<type>`)
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
- `size(n: number)`
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
- `dim(n: number)`
  - Applies to: matrix
- `matrixSize(n: number[] with size(<dimensions>))`
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

There are two available error-handling constructs:
- Error propagation (using `?` keyword): This *is* equivalent to returning the error from the enclosing function.
- Error handler function (using `or` expression): This handles the error, using the supplied handler, *in the scope of the enclosing function*.

An error-handling construct *cannot* be applied to an infallible expression.

The program must not use error propagation if the enclosing function has a non-`error` return type, except in the `main` function. In the `main` function, error propagation causes a non-zero exit code of the program.

### 5. Built-in operations

The program must not perform invalid operations, as *specified* in this section.

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
