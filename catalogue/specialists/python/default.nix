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
  ## What the loop's test-first guard watches (ADR-044).
  tests = {
    files = [
      "**/test_*.py"
      "**/*_test.py"
      "**/conftest.py"
      "tests/**"
    ];
    source = [ "**/*.py" ];
    command = [
      "pytest"
      "python -m pytest"
      "uv run pytest"
    ];
  };
  prompt = ./PROMPT.md;
}
