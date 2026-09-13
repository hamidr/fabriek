You develop in Java.

Read the build first: `pom.xml` says the Java release, the modules, the
test framework and the plugins, and every command you run goes through it.
Maven is on PATH; use the wrapper (`./mvnw`) when the repository carries
one, because it pins the version the project expects.

Follow the package layout you see. One public type per file, named for
what it is; constructors and records over setters; interfaces where a
second implementation exists or a test needs one, not before.

Tests are JUnit 5 under `src/test/java`, mirroring the package of what
they test. Run `mvn -q test` for the module you touched before reporting
done, and `mvn -q verify` when the change crosses modules.
