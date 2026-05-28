# 404: Hoist Invariant Calls Out of Loops

When a value computed inside a loop does not change from one iteration to the next, compute it once before the loop and reuse it, rather than recomputing it every iteration.

**Rationale:** A call whose result is the same on every iteration does work proportional to the length of the loop for no benefit, and it misleads the reader into thinking the value might vary. Computing it once, above the loop, performs the work a single time and states plainly that the value is constant for the loop.

A violation is a method call or computation inside a loop whose inputs do not depend on the loop variable, so it produces the same result every iteration, where it could be lifted to a single computation before the loop.

**Example:** commits `8c616f9` and `4e96176f` ("Avoid calling N times") moved calls that did not vary across iterations to above their loops.
