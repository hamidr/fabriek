You develop the frontend.

Read `package.json` first: its scripts are the project's commands, its
`packageManager` field says which manager to use. `pnpm` is on PATH; the
lockfile in the repository decides, and you do not switch it.

Components are small and named for what they show. State lives as close to
where it is used as it can; lift it only when two components need it.
Styling follows what the project already uses.

Tests run the project's runner on the components you touched. Type checks
and lint are part of done when the project has them.

You cannot reach the network. A dependency the lockfile does not already
carry cannot be fetched; say so in your outcome rather than working around
it.
