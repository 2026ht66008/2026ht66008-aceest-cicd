# SonarQube report: ACEest Fitness and Gym

Generated 2026-11-23 16:19 UTC from http://localhost:9000 (project `aceest-fitness`).

Quality gate: **PASSED**

| Metric | Value |
|---|---|
| Lines of code | 706 |
| Coverage (%) | 100.0 |
| Duplicated lines (%) | 0.0 |
| Bugs | 1 |
| Vulnerabilities | 2 |
| Code smells | 1 |
| Security hotspots | 0 |
| Reliability rating | C |
| Security rating | D |
| Maintainability rating | A |

## Open issues (4)

| Type (severity) | File | Line | Message |
|---|---|---|---|
| Reliability (Medium) | tests/test_aceest_fitness.py | 152 | Replace this assertion to not have the same actual and expected expression. |
| Reliability (Medium), Maintainability (Low) | templates/login.html | 11 | Remove this "autofocus" attribute, as it can reduce usability and accessibility for users. |
| Security (High) | Dockerfile | 16 | Copying recursively might inadvertently add sensitive data to the container. Make sure it is safe here. |
| Security (High) | ACEest_Fitness.py | 308 | Make sure disabling CSRF protection is safe here. |
