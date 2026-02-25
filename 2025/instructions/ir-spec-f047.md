# MetaC Intermediate Representation spec (F-047)

The introduction of an IR into the compiler serves the following purposes:
1. clean architectural split
2. offloading of the entire correctness logic into the IR generation
3. straightforward code generation from IR to backend C code
4. more flexible for backend changes, or introduction of different code generator backends

## Example design

The following program:

```
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

should produce an IR similar to the following (pseudo-representation):

```
BeginProgram
BeginFunction(name=main, params=[], ret=Number)
Call(target=printf, args=[Literal("Result: %d\n"), HandleError(AnonVar(v::1, value=Call(target=countNumbers, args=[]), type=TypeIntersection(l=Number, r=Error)), handler=h::1)]))
BeginHandler(h::1, params=[e])
  TrackType(e, type=Error)
  Call(target=printf, args=[Literal("Error! %s\n"), Chain(Ref(e), message)])
  Drop(e)
  Drop(v::1)
  Return(Literal(1))
EndHandler
Drop(v::1)
EndFunction
EndProgram
```