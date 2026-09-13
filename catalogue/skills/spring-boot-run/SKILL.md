---
name: spring-boot-run
description: Start a Spring Boot application from Maven, pick a profile, and check it is up through the actuator. Use when a task needs the application running.
---

# Running a Spring Boot application

## Start

```sh
./mvnw -q spring-boot:run -Dspring-boot.run.profiles=local
```

Use `mvn` only when the repository has no wrapper. The profile names an
`application-<profile>.yml`; read it before choosing one.

## Check it is up

```sh
curl -s localhost:8080/actuator/health
```

`{"status":"UP"}` or the application is not ready. If the actuator is not
on the classpath, the project does not expose health and you check the
log for `Started <Application> in`.

## Stop

Stop the process you started before reporting your outcome; a session
ends with its processes.

## Common failures

- Port in use: another run you started; list it with `ss -ltnp`.
- Datasource failure at start: the profile expects a database this cage
  does not have; use the profile the tests use, usually H2.
