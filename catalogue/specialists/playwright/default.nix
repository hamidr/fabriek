## Playwright on top of the frontend specialist. A cage has no network, so
## `playwright install` cannot fetch browsers: they come from the store, and
## the project's own @playwright/test, from its lockfile through the
## dependency cache (ADR-046), is pointed at them. Playwright resolves a
## browser by its revision, so the project's version has to match the
## driver's in nixpkgs.
{ pkgs, specialists, ... }:
let
  ## shortcut: Chromium only, headed and headless; add withFirefox or
  ## withWebkit when a project's config names those projects.
  browsers = pkgs.playwright-driver.selectBrowsers {
    withFirefox = false;
    withWebkit = false;
  };
  ## The project's CLI with the environment it needs, so nothing depends on
  ## the session exporting it first.
  playwright = pkgs.writeShellApplication {
    name = "playwright";
    text = ''
      export PLAYWRIGHT_BROWSERS_PATH=${browsers}
      export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
      exec npx --no-install playwright "$@"
    '';
  };
in
{
  extends = [ specialists.frontend ];
  tools = [ playwright ];
  tests = {
    files = [ "**/e2e/**" ];
    command = [
      "playwright test"
      "npx playwright test"
      "pnpm exec playwright test"
    ];
  };
  prompt = ./PROMPT.md;
}
