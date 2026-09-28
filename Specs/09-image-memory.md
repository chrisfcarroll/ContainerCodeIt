# 09 — Remember recent images and default the tool chains from them

See 00-conventions.md.

Keep a file in `--save-dir` (`image-history`) holding the most recent 15 invocations,
one `yyyymmdd image-name` per line, newest last. Appending the 16th drops the oldest.

When `code-it` is invoked with no `--tool-chains` and no `--image`, choose the
most-recently used remembered image whose tool chains cover at least 70% of weighted
usage. Weight the remembered invocations linearly: the most recent has weight 15 and
the oldest of the 15 has weight 1. A tool chain's usage is the sum of the weights of
the invocations whose image contains it, as a percentage of the total weight; an
image's coverage is the sum of those percentages over its tool chains. Pick the most
recent (still existing) image whose coverage is at least 70%.

Example: 50% of weighted usage includes `dotnet`, 40% `node`, 30% `python`; the image
to use is the most recent one whose tool chains add up to at least 70%.

If nothing is remembered, or no remembered image covers 70%, keep today's default
tool chains. Record the image actually used at the end of every non-dry-run
invocation. Explicit `--tool-chains` or `--image` bypasses the memory.
