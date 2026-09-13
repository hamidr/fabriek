---
name: jvm-profile
description: Profile a running JVM with async-profiler and read the flame graph to see where time goes. Use for a performance task on Java code.
---

# Profiling a JVM

## Attach

```sh
jps
asprof -d 30 -e cpu -f /tmp/profile.html <pid>
```

Thirty seconds of CPU samples, written as an HTML flame graph. Use
`-e alloc` for allocation and `-e wall` when the process waits more than
it computes.

## Read it

The widest frames at the top are where time goes. Follow one down to the
first frame in the project's own package; that is the method to look at.
A wide frame in a library under a narrow project frame is a call pattern
problem, not a library problem.

## Report

State the event type, the duration, the top three project frames with
their share, and what you changed. Give the HTML file's path in your
outcome; do not paste the graph.

## When it cannot attach

`perf_event` may be unavailable in a cage. Fall back to `-e itimer`, which
needs no kernel support and is coarser.
