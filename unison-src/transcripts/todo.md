# Test the `todo` command

## Simple type-changing update.

```ucm:hide
.simple> builtins.merge
```

```unison:hide
x = 1
useX = x + 10

type MyType = MyType Nat
useMyType = match MyType 1 with
  MyType a -> a + 10
```

```ucm:hide
.simple> add
```

Perform a type-changing update so dependents are added to our update frontier.

```unison:hide
x = -1

type MyType = MyType Text
```

```ucm:error
.simple> update.old
.simple> todo
```

## A merge with conflicting updates.

```ucm:hide
.mergeA> builtins.merge
```

```unison:hide
x = 1
type MyType = MyType
```

Set up two branches with the same starting point.

```ucm:hide
.mergeA> add
.> fork .mergeA .mergeB
```

Update `x` to a different term in each branch.

```unison:hide
x = 2
type MyType = MyType Nat
```

```ucm:hide
.mergeA> update.old
```

```unison:hide
x = 3
type MyType = MyType Int
```

```ucm:hide
.mergeB> update.old
```

```ucm:error
.mergeA> merge .mergeB
.mergeA> todo
```

## A named value that appears on the LHS of a patch isn't shown

```ucm:hide
.lhs> builtins.merge
```

```unison
foo = 801
```

```ucm
.lhs> add
```

```unison
foo = 802
```

```ucm
.lhs> update.old
```

```unison
oldfoo = 801
```

```ucm
.lhs> add
.lhs> view.patch patch
.lhs> todo
```

## A type-changing update to one element of a cycle, which doesn't propagate to the other

```ucm:hide
.cycle2> builtins.merge
```

```unison
even = cases
  0 -> true
  n -> odd (drop 1 n)

odd = cases
  0 -> false
  n -> even (drop 1 n)
```

```ucm
.cycle2> add
```

```unison
even = 17
```

```ucm
.cycle2> update.old
```

```ucm:error
.cycle2> todo
```
