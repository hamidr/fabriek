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
  prompt = ./PROMPT.md;
}
