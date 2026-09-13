{
  pkgs,
  specialists,
  skills,
  ...
}:
{
  extends = [ specialists.developer ];
  tools = with pkgs; [
    jdk21
    maven
  ];
  skills = [ skills.jvm-profile ];
  ## Eclipse JDT's server (ADR-043). Its workspace goes where the wrapper
  ## puts it, under the role's home.
  lsp = [
    {
      id = "jdtls";
      include = [ "**/*.java" ];
      rootMarkers = [
        "pom.xml"
        "build.gradle"
        "build.gradle.kts"
        "mvnw"
      ];
      bin = "${pkgs.jdt-language-server}/bin/jdtls";
      languageIdByExtension = {
        ".java" = "java";
      };
      startupTimeoutMs = 90000;
    }
  ];
  tests = {
    files = [ "**/src/test/**" ];
    source = [ "**/src/main/**" ];
    command = [
      "mvn test"
      "mvn verify"
      "mvn -q test"
      "mvn -q verify"
      "./mvnw test"
      "./mvnw verify"
      "./mvnw -q test"
      "./mvnw -q verify"
      "gradle test"
      "./gradlew test"
    ];
  };
  prompt = ./PROMPT.md;
}
