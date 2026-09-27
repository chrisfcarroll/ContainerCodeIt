# 03 — Add Python (with uv) as a toolchain

See 00-conventions.md. Depends on 01.

## Goal
`code-it-build --stack python` gives a working Python toolchain: `python3`, `uv`, `uvx`.

## Notes
- Prefer Alpine packages (`python3`, `uv`) over curl installers. Fold the `uv` stack from 01 into `python`; keep `uv` as an alias so old invocations still work.
- Don't use pip to install into the system Python (Alpine marks it externally managed). Use `uv venv` / `uv tool`.
- `uv python install` must work on musl for x86_64 and aarch64; verify.
- Set `UV_CACHE_DIR` inside the container's home. Don't mount the host uv cache (uv needs to write to it).
- Add `doas` permits only if needed.

## Done when
- In a built image (headless run): `python3 --version`, `uv --version`, `uv run --with requests python -c "import requests"` succeed.
- Tests cover `--stack python`, the `uv` alias, and the default image still having `uv`.
