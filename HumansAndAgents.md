# Humans and AI Agents
1. See README.md, which is a description for users.
2. See https://gist.githubusercontent.com/chrisfcarroll/eee7257e4c301b8f9e5f6f6599f0f250/raw/541428073a4ac46884f431e677f889a01209121a/ChrisConventionalCommitStyle.md
3. If you are a human, you can ask an Agent to help with tests. If you are an Agent, tests are mandatory.

## Design Constraints

- These scripts must remain cross-platform, running on MacOs, Linux and Windows on both bash and PowerShell
- The Dockerfile is for Alpine linux, so everything must work on musl for x86_64 and aarch64
- Respect the native idioms of Powershell and bash where feasible

## Implementation

- Work to keep the scripts organised, understandable and readable

## Testability

- There are test suites, which must be maintained and kept organised for all platforms. New features should usually result in new tests.