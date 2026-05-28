# 107: Name a Value to Match the Method It Comes From

Name a variable, and a test, to mirror the method it derives from or asserts on, taking that method's own wording even when a more literal term exists. The value returned by `getStatus()` is `status`, not `statusCode`, because the method is `getStatus`; a test that checks `getStatus()` returns not found is `testStatusNotFound`, not `testNotFoundResponse`. Matching the method keeps one vocabulary from call to value to test.

**Rationale:** When the name of a value echoes the method that produced it, the reader connects the two without a second thought, and the whole path through the code uses one word for one thing. Switching to a different, even more precise, term for the same value forces the reader to bridge the two names and invites drift as the code grows.

A violation is a variable or test named with a synonym or a vaguer term than the method it comes from, such as `statusCode` for the result of `getStatus()` or `testNotFoundResponse` for a check on `getStatus()`, where the method's own word would match.

**Example:** commit `92700dd` renamed `testNotFoundResponse` and its helper to `testStatusNotFound` to match `getStatus`, and names the value `status` rather than `statusCode` for the same reason.
