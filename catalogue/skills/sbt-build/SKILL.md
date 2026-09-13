---
name: sbt-build
description: Compile, test and format a Scala project with sbt from a cage that has no network, using the coursier cache the project carries. Use for any sbt command, and when sbt or Metals stalls on a download.
---

# sbt in a cage

## One sbt session, not many

sbt starts a JVM and loads the build each time; batch what you need:

```sh
sbt -Dsbt.server.forcestart=false "compile; Test/compile; testOnly *InvoiceSpec"
sbt "scalafmtCheckAll; test"
```

## No network

sbt and Metals resolve through coursier. Point them at the cache the
project's environment provides and stop them from reaching out:

```sh
export COURSIER_CACHE="${COURSIER_CACHE:-$HOME/.cache/coursier/v1}"
sbt -Dsbt.offline=true -Dsbt.ci=true "compile"
```

A message like `not found: https://repo1.maven.org/...` means a
dependency, a compiler bridge or the sbt version in
`project/build.properties` is not in the cache. That is not yours to fix
here: finish what compiles, report blocked, name the artifact. The
tool-missing skill says the rest.

## Which sbt

The launcher on PATH runs the sbt version `project/build.properties`
names, from the cache. A project with no such file runs the launcher's
own version; add the file rather than relying on that.

## Format

```sh
sbt scalafmtAll          # rewrite, when the project has sbt-scalafmt
scalafmt --check .       # the standalone binary, same .scalafmt.conf
```

## Metals and the build

Metals imports the build through sbt's BSP the first time it starts on a
project; a `.bsp/` directory appears. Slow once, then cached. If Metals
reports `Import build` failed, the same offline cause applies: read
`.metals/metals.log` for the artifact it wanted.
