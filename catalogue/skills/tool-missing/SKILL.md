---
name: tool-missing
description: What to do when a command or package the task needs is not on PATH in this cage. Use before working around a missing tool or trying to install one.
---

# A tool is missing

A cage gets its tools through the flake it entered and by no other route.
Nothing you install here is shared, declared, or present next session, and
you have no network to fetch it with anyway.

## Check first

```sh
command -v <tool>
ls "$(dirname "$(command -v python3)")"
```

The second line lists everything on your profile. A tool may be there under
another name, or provided by the project's devShell rather than your
specialist.

## Then ask, do not install

1. Finish every part of the task that does not need the tool.
2. Commit that on your branch.
3. Report the outcome as blocked, naming the tool, what you needed it for,
   and the smallest alternative you considered.

The consult this creates goes to the role that maintains the catalogue or
the repository's devShell. The tool arrives at your next session, not this
one.

Do not run `nix profile install`, `pip install --user`, `npm install -g`
or any other install into your home. It is not shared, it is not
recorded, and the kernel probes see it.
