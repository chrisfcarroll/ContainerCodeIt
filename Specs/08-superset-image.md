# 08 — Choose an existing image that contains the requested tool chain

See 00-conventions.md.

When `code-it` needs an image and the exact `code-it-alpine-<chains>` image does not
exist, and the user did not pass `--image`, pick the most-recently built existing image
whose `code-it.tool-chains` label contains every requested tool chain, and say which
image was chosen. If none contains it, keep today's "image does not exist" error.

An explicit `--image` is honoured as-is (still an error if it is missing). When
building, build the exact requested tool chains, as today.
