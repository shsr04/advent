# MetaC Verified Normal-Form HIR spec (F-047)

## Purpose

This document specifies a single, high-level IR (`HIR`) that is still strict enough to be machine-verified before backend lowering.

Compiler split:
1. parser/AST -> verified normal-form HIR
2. HIR verification gates
3. HIR -> backend codegen

The backend must not read parser/AST structures directly.

## Verified Normal-Form HIR (VNF-HIR)

`VNF-HIR` is a structured HIR with explicit control/effect/ownership edges and flowing fact state.
It preserves high-level constructs (`if`, `for`, `while`, `or catch`, `?`) instead of flattening everything into low-level blocks.

Normalization rules:
- expression evaluation order is explicit
- fallible operations cannot remain implicit inside larger expressions
- control-transfer targets are explicit on all structured control nodes
- lifetime boundaries are explicit for every owned value
- node IDs and ordering are deterministic

## Phase contract

- AST lowering outputs `HIR + initial facts + provenance`.
- Verification gates consume only normalized HIR.
- Codegen accepts only HIR that passed all gates.

`provenance` fields:
- source span (`file`, `line`, `column`, optional end span)
- origin AST node id
- derived type/effect/constraint fact ids

## Core model

### Program

```text
Program := {
  functions: Function[],
  factLattice: FactLattice
}
```

### Function

```text
Function := {
  id: FnId,
  params: Param[],
  returnType: TypeIntersection | SingleType,
  regions: Region[],
  edges: Edge[],
  entryRegion: RegionId,
  entryFacts: FactSet
}
```

### Region

A region is a structured execution unit (not a raw basic block).

```text
Region := {
  id: RegionId,
  steps: Step[],
  exit: Exit,
  factsIn: FactSet,
  factsOutByExit: map<ExitTag, FactSet>
}
```

```text
Edge := {
  id: EdgeId,
  fromRegion: RegionId,
  exitTag: ExitTag,
  toRegion: RegionId
}
```

`exit` is exactly one of:
- `Goto(targetRegion)`
- `IfExit(condValue, thenRegion, elseRegion, joinRegion)`
- `TryExit(resultId, fallibleExpr, okRegion, errRegion, handler?)`
- `ForInExit(loopId, itemName, iterableExpr, bodyRegion, continueRegion, breakRegion, rewindRegion, errorRegion, endRegion)`
- `WhileExit(loopId, condValue, bodyRegion, continueRegion, breakRegion, rewindRegion, endRegion)`
- `Return(value?)`
- `PropagateError(errorValue)`

### Steps (high-level)

`Step` kinds:
- `Declare(name, mutability, type, initValue)`
- `Assign(target, value)`
- `Move(target, sourceValue)`
- `Copy(target, sourceValue)`
- `Borrow(target, sourceValue, borrowKind=shared|exclusive)`
- `EndBorrow(target)`
- `Eval(valueId, expr)` where `expr` can be call/field/index/op/literal/ref
- `Destructure(pattern, sourceValue)`
- `Drop(valueId)`

`CallExpr` is target-agnostic:
- `CallExpr(kind=user|builtin|intrinsic, target, args, resultType)`

Note: `TypeIntersection` remains the canonical project term.

Ownership-origin note:
- VNF-HIR does not attempt to infer which source-language expressions allocate/materialize owned resources.
- AST->HIR lowering must annotate resulting values with ownership class facts (`owned`, `borrowed`, `copyable`) according to language semantics.

## Fact flow semantics

Facts are flow state that travel through regions and edges.
Each region computes outgoing facts from incoming facts by applying step and exit transfer rules.
Gates validate both local facts and whole-program flow consistency.

```text
FactAtom := {
  id: FactId,
  kind: type | constraint | effect | ownership | cfg | trace,
  subject: NodeId | EdgeId | ValueId,
  predicate: Predicate,
  provenance: Provenance
}

FactSet := set<FactAtom>
```

Examples:
- `TypeOf(v12) == TypeIntersection(Number, Error)`
- `Narrow(v12, Number) valid on edge e7`
- `Constraint(range(0,99)+wrap) holds for dial in region r3`
- `Owns(v22) at r4` and `Dropped(v22) on all exits of loop L1`
- `Edge(r2 -> r5) is error-propagation edge`

Transfer rules:
- `Declare`/`Eval` can `gen` type/effect/ownership facts.
- `Assign` can `kill` prior narrowing/constraint facts for the target and `gen` new facts from RHS.
- `Move` transfers ownership: `Owns(source)` is killed and `Owns(target)` is generated.
- `Copy` requires copyable source facts; source ownership remains valid and target facts are generated.
- `Borrow` generates alias/borrow facts tying `target` to `source`; `EndBorrow` removes them.
- `Drop` kills ownership/live facts for the dropped value.
- `TryExit` emits distinct fact sets on `ok` and `err` edges.
- `IfExit` refines branch-specific facts from condition truth values.
- `ForInExit` evaluates `iterableExpr` on initial loop entry and whenever control reaches `rewindRegion`.
- Normal iteration progress (`continueRegion`) advances existing loop iteration state and does not reevaluate `iterableExpr`.
- If `iterableExpr` is fallible, its success/error split is recomputed on initial entry and on each rewind.
- `ForInExit` introduces an implicit owned iterable instance fact:
  - `Owns(loop_iterable(loopId, epoch))` on successful evaluation.
  - `epoch` changes on each reevaluation (initial entry and rewind).
  - `continueRegion` keeps ownership of the same `epoch`.
  - `breakRegion`, function exit, and rewind invalidation must establish `Dropped(loop_iterable(loopId, epoch))`.

Merge and loops:
- At join points, incoming edge fact sets merge via lattice meet/intersection (per fact kind policy).
- Loop-carried facts iterate to fixpoint.
- A function is verification-ready only when all region fact sets are stable under transfer+merge.

## Determinism requirements

- All IDs are deterministic for identical source + compiler mode.
- Function/region/step ordering is canonicalized by source order after parse normalization.
- Fact emission order is deterministic.
- Optional HIR text dumps must be byte-stable for snapshot tests.
- Given identical source and compiler mode, fixpoint iteration must converge to identical fact sets.

## Ownership and cleanup contract

- Each owned value has exactly one active owner at any reachable program point.
- `Assign`/`Eval` define ownership mode (`move`, `copy`, or `borrow`) via ownership facts.
- `Drop` closes the lifetime of an owned value.
- Implicit temporaries/materializations introduced by normalized exits (for example `ForInExit` iterable instances) are owned values in the same ownership model and must satisfy the same drop proofs.
- Ownership transfer for propagated values is explicit:
  - `PropagateError(v)` is a move of `v` to caller/handler control context.
  - `Return(v)` is a move of `v` to function result context unless a copy fact allows copy semantics.
- Borrow/alias invalidation rules:
  - shared borrow: source cannot be moved or dropped while borrow is active.
  - exclusive borrow: no other borrow or direct access to source is allowed while borrow is active.
  - assigning through source or alias must invalidate affected narrowing/constraint facts for all aliases in the borrow set.
  - violating alias/borrow rules fails `Gate-Ownership`.
- The ownership gate must prove each owned value introduced by lowering annotations has exactly one matched cleanup on every reachable exit:
  - normal fallthrough
  - branch alternatives
  - loop continue/break/rewind paths
  - early return paths
  - error-propagation and handler paths

## Verification gates

Before codegen, all gates are hard blockers:

- `Gate-CFG`: region/edge graph is structurally valid and all jump-like targets resolve.
- `Gate-Type`: type rules and narrowing facts are consistent.
- `Gate-Effect`: fallibility/effect facts match control-flow behavior (`?`, `or catch`, fail-fast).
- `Gate-Ownership`: no leak/double-free/use-after-free across any reachable path.
- `Gate-Lowering`: deterministic backend output for identical normalized HIR.
- `Gate-Traceability`: each accepted language guarantee links to check IDs + tests.

## Backend freedom contract

Backends are free to lower VNF-HIR differently as long as they preserve:
- region/control semantics
- type/effect/ownership facts validated at HIR level
- observable language behavior

Example: a backend may lower `ForInExit` into iterator form, index form, or callback form, provided verified facts remain true.

## Example

Representative source:

```metac
function main() {
  printf("Result: %d\n", countNumbers() or catch(e) {
    printf("Error! %s\n", e.message)
    return 1
  })
}

function countNumbers(): number | error {
  let dial: number with range(0,99) + wrap = 50
  let zeroHits: number = 0

  for const line in lines(STDIN)? {
    const [direction, amount] = match(line, /(L|R)([0-9]+)/)?
    if direction == "L" {
      dial = dial - amount
    } else {
      dial = dial + amount
    }
    if dial == 0 {
      zeroHits = zeroHits + 1
    }
  }
  return zeroHits
}
```

VNF-HIR sketch:

```text
Program
  Function main returnType=Number entryRegion=r0
    entryFacts: { TypeOf(countNumbers()) == TypeIntersection(Number, Error) }
    Region r0
      factsIn:  { TypeOf(countNumbers()) == TypeIntersection(Number, Error) }
      exit: TryExit(t0, CallExpr(user, countNumbers, []), okRegion=r1, errRegion=r2)
      factsOutByExit:
        ok  -> { TypeOf(t0) == Number, Owns(t0) }
        err -> { TypeOf(t0) == Error, Owns(t0) }
    Region r1
      factsIn:  { TypeOf(t0) == Number, Owns(t0) }
      s1: Eval(v1, Narrow(t0, Number))
      s2: Eval(_, CallExpr(builtin, printf, ["Result: %d\n", v1]))
      s3: Drop(t0)
      exit: Return(0)
      factsOutByExit:
        return -> { Dropped(t0) }
    Region r2
      factsIn:  { TypeOf(t0) == Error, Owns(t0) }
      s4: Eval(e0, Narrow(t0, Error))
      s5: Eval(m0, FieldRead(e0, message))
      s6: Eval(_, CallExpr(builtin, printf, ["Error! %s\n", m0]))
      s7: Drop(e0)
      s8: Drop(t0)
      exit: Return(1)
      factsOutByExit:
        return -> { Dropped(e0), Dropped(t0) }

  Function countNumbers returnType=TypeIntersection(Number, Error) entryRegion=r0
    entryFacts: { }
    Region r0
      factsIn:  { }
      s0: Declare(dial, let, Constrain(Number,[Range(0,99),Wrap]), 50)
      s1: Declare(zeroHits, let, Number, 0)
      exit: Goto(r_loop)
    Region r_loop
      factsIn:  { TypeOf(dial) == Number, TypeOf(zeroHits) == Number }
      exit: ForInExit(L1, line, CallExpr(builtin, lines, [STDIN]),
                      bodyRegion=r_body, continueRegion=r_step,
                      breakRegion=r_end, rewindRegion=r_loop, errorRegion=r_err, endRegion=r_end)
      factsOutByExit:
        body   -> { TypeOf(line) == String, Constraint(dial, range(0,99)+wrap), Owns(loop_iterable(L1, eN)) }
        error  -> { TypeOf(loop_error(L1)) == Error }
        break  -> { LoopExited(L1), Dropped(loop_iterable(L1, eN)) }
    Region r_err
      factsIn:  { TypeOf(loop_error(L1)) == Error }
      exit: PropagateError(loop_error(L1))
    Region r_body
      factsIn:  { TypeOf(line) == String, Constraint(dial, range(0,99)+wrap) }
      exit: TryExit(m0, CallExpr(builtin, match, [line, /(L|R)([0-9]+)/]), okRegion=r_after_match, errRegion=r_match_err)
    Region r_match_err
      factsIn:  { TypeOf(m0) == Error }
      exit: PropagateError(Narrow(m0, Error))
    Region r_after_match
      factsIn:  { TypeOf(m0) == Array(String) }
      s5: Destructure([direction, amount], Narrow(m0, Array(String)))
      exit: IfExit(Equals(direction, "L"), thenRegion=r_left, elseRegion=r_right, joinRegion=r_zero_check)
      factsOutByExit:
        then -> { direction == "L" }
        else -> { direction != "L" }
    Region r_left
      factsIn:  { direction == "L", Constraint(dial, range(0,99)+wrap) }
      s7: Assign(dial, Sub(dial, amount))
      exit: Goto(r_zero_check)
    Region r_right
      factsIn:  { direction != "L", Constraint(dial, range(0,99)+wrap) }
      s8: Assign(dial, Add(dial, amount))
      exit: Goto(r_zero_check)
    Region r_zero_check
      factsIn:  merge(r_left, r_right)
      exit: IfExit(Equals(dial, 0), thenRegion=r_inc, elseRegion=r_step, joinRegion=r_step)
    Region r_inc
      factsIn:  { dial == 0 }
      s10: Assign(zeroHits, Add(zeroHits, 1))
      exit: Goto(r_step)
    Region r_step
      factsIn:  fixpoint(L1) + { Owns(loop_iterable(L1, eN)) }
      exit: Goto(r_loop)
    Region r_end
      factsIn:  loop_exit(L1) + { Dropped(loop_iterable(L1, *)) }
      s11: Drop(dial)
      exit: Return(zeroHits)
```
