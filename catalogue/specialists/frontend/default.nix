{ pkgs, specialists, ... }:
{
  extends = [ specialists.developer ];
  tools = with pkgs; [
    nodejs_22
    pnpm
  ];
  lsp = [
    {
      id = "tsserver";
      include = [
        "**/*.ts"
        "**/*.tsx"
        "**/*.js"
        "**/*.jsx"
      ];
      rootMarkers = [
        "tsconfig.json"
        "package.json"
      ];
      bin = "${pkgs.typescript-language-server}/bin/typescript-language-server";
      args = [ "--stdio" ];
      languageIdByExtension = {
        ".ts" = "typescript";
        ".tsx" = "typescriptreact";
        ".js" = "javascript";
        ".jsx" = "javascriptreact";
      };
    }
  ];
  tests = {
    files = [
      "**/*.test.ts"
      "**/*.test.tsx"
      "**/*.spec.ts"
      "**/*.spec.tsx"
      "**/__tests__/**"
    ];
    source = [
      "**/*.ts"
      "**/*.tsx"
    ];
    command = [
      "pnpm test"
      "pnpm vitest"
      "pnpm jest"
      "npx vitest"
      "npx jest"
    ];
  };
  prompt = ./PROMPT.md;
}
