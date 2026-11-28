# Humans and AI Agents
1. See README.md, which is a description for users.
2. See https://bit.ly/ccccagentsmd#file-commentandcommitstyle-md
3. If you are a human, you can ask an Agent to help with tests. If you are an Agent, tests are mandatory.

## Design Constraints

- These scripts must remain cross-platform, running on MacOs, Linux and Windows on both bash and PowerShell
- Respect the native idioms of Powershell and bash where feasible
- The only exception is that scripts in the news/ directory are pwsh only.
- Configure agents in the container to run anything with full permissions without approval. This is the point of the project.
- Strive for an excellent developer/user experience. Without this, it's pointless.
- The Dockerfile is for Alpine linux, so everything must work on musl for x86_64 and aarch64

## Implementation

- Work to keep the scripts organised, understandable and readable

## Testability

- There are test suites, which must be maintained and kept organised for all platforms. New features should usually result in new tests.
