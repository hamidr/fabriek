{ pkgs, specialists, ... }:
{
  extends = [ specialists.developer ];
  tools = with pkgs; [
    ruff
    uv
    python3Packages.pytest
  ];
  lsp = [
    {
      id = "basedpyright";
      include = [
        "**/*.py"
        "**/*.pyi"
      ];
      rootMarkers = [
        "pyproject.toml"
        "setup.py"
        "requirements.txt"
      ];
      bin = "${pkgs.basedpyright}/bin/basedpyright-langserver";
      args = [ "--stdio" ];
      languageIdByExtension = {
        ".py" = "python";
        ".pyi" = "python";
      };
    }
  ];
  prompt = ./PROMPT.md;
}
