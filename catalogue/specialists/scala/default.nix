## The Scala toolchain as the operator's own machines carry it: coursier,
## sbt and Metals from nixpkgs beside a JDK, with Metals configured the way
## the operator's editor configures it. Metals brings its own JRE; sbt and
## scalac run on the JDK here.
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
    sbt
    coursier
    scalafmt
  ];
  skills = [ skills.sbt-build ];
  lsp = [
    {
      id = "metals";
      include = [
        "**/*.scala"
        "**/*.sbt"
        "**/*.sc"
      ];
      rootMarkers = [
        "build.sbt"
        "build.sc"
        "project/build.properties"
      ];
      bin = "${pkgs.metals}/bin/metals";
      languageIdByExtension = {
        ".scala" = "scala";
        ".sbt" = "scala";
        ".sc" = "scala";
      };
      ## Metals imports the build before it answers, which is minutes on a
      ## cold workspace.
      startupTimeoutMs = 180000;
      diagnosticsWaitMs = 4000;
      initializationOptions = {
        statusBarProvider = "off";
        isHttpEnabled = false;
      };
      settings.metals = {
        fallbackScalaVersion = "3.3.4";
        showImplicitArguments = true;
        showImplicitConversionsAndClasses = true;
        showInferredType = true;
        superMethodLensesEnabled = true;
      };
    }
  ];
  prompt = ./PROMPT.md;
}
