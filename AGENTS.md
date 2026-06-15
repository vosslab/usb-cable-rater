# AGENTS.md

Operational pointers for agents. Canonical rules live in the linked docs; do not restate them here.

## Build and run

- Swift package. Build with `bash build_debug.sh`; verify with `bash devel/verify.sh`.
- Helper Python scripts run via `source source_me.sh && python3 ...` (Python 3.12 only).
- Build and run details: see [docs/INSTALL.md](docs/INSTALL.md) and [docs/USAGE.md](docs/USAGE.md).

## Orientation

- System design and data flow: [docs/CODE_ARCHITECTURE.md](docs/CODE_ARCHITECTURE.md).
- Directory map and where files belong: [docs/FILE_STRUCTURE.md](docs/FILE_STRUCTURE.md).

## Style and conventions

- Repo organization and workflow: [docs/REPO_STYLE.md](docs/REPO_STYLE.md).
- Python style: [docs/PYTHON_STYLE.md](docs/PYTHON_STYLE.md).
- Markdown style: [docs/MARKDOWN_STYLE.md](docs/MARKDOWN_STYLE.md).

## Workflow constraints

- Record edits in [docs/CHANGELOG.md](docs/CHANGELOG.md) for human review.
- Only humans run `git commit`; agents stage changes and leave the commit to the user.
