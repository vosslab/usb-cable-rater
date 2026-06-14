# starter_repo_template
Canonical bootstrap scaffolding for new Python repositories: ready-to-use repo policy docs, Python style rules, licensing boundaries, and pytest lint checks so projects start consistent before any project-specific code is added.

Only `README.md` and `docs/CHANGELOG.md` are intentionally repository-specific; every other file is designed to remain generic for downstream template users.

## Documentation

- [docs/REPO_STYLE.md](docs/REPO_STYLE.md): Repository structure, naming, versioning, dependency manifest, and licensing conventions.
- [docs/PYTHON_STYLE.md](docs/PYTHON_STYLE.md): Python implementation rules for formatting, structure, imports, argparse, and testing.
- [docs/PYTEST_STYLE.md](docs/PYTEST_STYLE.md): Pytest test-writing rules, commands, and failure triage.
- [templates/typescript/docs/PLAYWRIGHT_USAGE.md](templates/typescript/docs/PLAYWRIGHT_USAGE.md): Browser-driven tests using Playwright in `tests/playwright/`.
- [docs/E2E_TESTS.md](docs/E2E_TESTS.md): End-to-end test conventions; shell/Python E2E lives in `tests/e2e/`, browser E2E in `tests/playwright/`.
- [docs/MARKDOWN_STYLE.md](docs/MARKDOWN_STYLE.md): Markdown writing and formatting conventions for repository documentation.
- [docs/AUTHORS.md](docs/AUTHORS.md): Canonical authorship and attribution metadata for template maintenance.
- [docs/CHANGELOG.md](docs/CHANGELOG.md): Repository-specific history of updates to this template.

## Template layout

The starter template ships universal + Python files at the template root (their final consumer location) and type-specific overlays under `templates/<type>/`. Currently `templates/typescript/` and `templates/rust/` exist; `rust/` is a stub. The propagator resolves universal/python sources at template root and typescript/rust sources under `templates/<type>/`. Template-only tooling (e.g., `tools/detect_repo_type.py`) lives under `tools/`; it never propagates and is removed by `reset_repo.py` at consumer bootstrap.

- See [meta/docs/PROPAGATION_RULES.md](meta/docs/PROPAGATION_RULES.md) for the folder convention and manifest rules that route files to consumers.

## Quick start

Bootstrap a fresh clone (sets project type + licenses, installs canonical files):

```bash
python3 reset_repo.py
```

Type tokens: `python` (default), `typescript`, `rust`, `other`. Use `--non-interactive --type <token> --code-license <spdx> --docs-license <spdx>` for scripted runs. `--dry-run` prints planned actions without writing.

Run the fast test suite:

```bash
pytest tests/
```

Non-browser end-to-end tests live under `tests/e2e/` per [docs/E2E_TESTS.md](docs/E2E_TESTS.md) when present; this repo does not currently ship any. Each runner is self-contained -- invoke them individually with `bash tests/e2e/e2e_<name>.sh`.

Run browser-driven Playwright tests (see [templates/typescript/docs/PLAYWRIGHT_USAGE.md](templates/typescript/docs/PLAYWRIGHT_USAGE.md)):

```bash
node tests/playwright/test_example.mjs
```
