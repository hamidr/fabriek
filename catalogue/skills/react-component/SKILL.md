---
name: react-component
description: Add or change a React component with its test, following the project's own conventions for placement, props, state and rendering tests. Use when a task adds a component, a hook or a page.
---

# A React component and its test

## Locate the pattern

```sh
rg -n "export (default )?function [A-Z]" --type tsx -l | head
rg -n "from '@testing-library/react'|from \"@testing-library/react\"" -l | head -3
jq '.scripts, .dependencies | keys' package.json
```

Copy the placement, the file naming and the test naming of the nearest
existing component. A project with `components/Button/Button.tsx` and
`Button.test.tsx` gets the same shape from you.

## The component

```tsx
type InvoiceRowProps = {
  invoice: Invoice;
  onOpen: (id: string) => void;
};

export function InvoiceRow({ invoice, onOpen }: InvoiceRowProps) {
  return (
    <li>
      <button type="button" onClick={() => onOpen(invoice.id)}>
        {invoice.number}
      </button>
      <span>{formatMoney(invoice.total)}</span>
    </li>
  );
}
```

Props typed and named; no `any`; no state that a parent already holds;
handlers named `onX` in props and `handleX` inside.

## The test

```tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

test("opens the invoice when its number is clicked", async () => {
  const onOpen = vi.fn();
  render(<InvoiceRow invoice={invoice({ number: "INV-7" })} onOpen={onOpen} />);
  await userEvent.click(screen.getByRole("button", { name: "INV-7" }));
  expect(onOpen).toHaveBeenCalledWith(invoice.id);
});
```

Query by role and accessible name; `getByTestId` only when the project
already does. One behaviour per test. `vi` or `jest` is whichever the
project runs.

## Done

```sh
pnpm vitest run InvoiceRow
pnpm tsc --noEmit
pnpm lint
```

Use the project's script names from `package.json` when they differ.
