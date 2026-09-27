Tidy.

# 01 — Changes port handling

Catering to ports was nice idea but it's a problem.

1. Change the default behaviour to allocate no ports at all.
2. Ports can be specified but the parameter name becomes --port, not -p.
3. the parameter will take a single value.
4. the default value if none is specified will be 0
5. (Docker can continue to auto-allocate a random port using 0).
6. For Apple containers only, on macOs only, is there a way to *quickly* test whether a port is in use? If so, if port 0 is specified, test 3000. If 3000 is in use, then move up to 3001, 3002 etc until an unused port is found. If that isn't feasible, translate 0 into a randomly chosen port between 30000 and 39999


## Rename and aliases

- Where internal variables for tech or package use different naming, change them to be consistent with the public API.
- Where feasible, add short-form aliases to the bash scripts for the most wanted long parameter names. (-p for prompt, -t for toolchain, -b for build, -B for rebuild. Others as you think good.)
- Don't forget to add both sh and pwsh tests for parameter parsing.

Review the code base for consistency, clarity, redundancy.