---
name: release-here
description: Cut a release of this repository, which is a tag and a changelog entry and nothing else. Use when a task asks for a release or a version bump.
---

# Releasing this repository

## Decide the version

```sh
git describe --tags --abbrev=0
git log --oneline "$(git describe --tags --abbrev=0)"..HEAD
```

Patch for fixes only, minor for a new capability, major for a change that
breaks a caller. When unsure, minor.

## Write the changelog

Add a section at the top of `CHANGELOG.md`:

```
## 1.4.0 - 2026-09-13

- One line per user-visible change, from the commits above.
```

Internal refactors and test-only commits do not appear.

## Commit and tag

```sh
git commit -am "Release 1.4.0"
git tag -a v1.4.0 -m "Release 1.4.0"
```

Your outcome names the tag. You cannot push; the operator does, and the
tag travels with your branch when it is integrated.
