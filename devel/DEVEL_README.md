# devel scripts

Developer-facing maintenance scripts for this repo: version bumping, PyPI
release, changelog management, and build cleanup. These are run by maintainers,
not shipped to consumers and not part of the fast pytest lane.

| Script | Purpose |
| --- | --- |
| [bump_version.py](bump_version.py) | Bump or set the version across all version files |
| [changelog_lib.py](changelog_lib.py) | Shared changelog parser, serializer, git and console helpers |
| [commit_changelog.py](commit_changelog.py) | Draft a commit message from new changelog entries |
| [query_changelog.py](query_changelog.py) | Search the changelog corpus by date, category, keyword |
| [rotate_changelog.py](rotate_changelog.py) | Archive old changelog day blocks per repo policy |
| [flatten_broken_md_links.py](flatten_broken_md_links.py) | Repair or delink broken Markdown links in docs |
| [dist_clean.sh](dist_clean.sh) | Remove build artifacts, caches, and dependency installs |

The three changelog scripts share [changelog_lib.py](changelog_lib.py).
Rotation, archive naming, and category rules are defined in
[../docs/REPO_STYLE.md](../docs/REPO_STYLE.md).

## bump_version.py

Bump a semantic version (major, minor, patch, alpha, beta, rc) or set an
explicit CalVer version, then sync every version file in the repo
(`pyproject.toml`, `VERSION`, `version.py`, and similar). Dry-run by default;
pass `--apply` to write.

| Function | Does |
| --- | --- |
| `parse_args` | Parse CLI args for bump mode, output, and repo discovery |
| `advanced_help` | Show or suppress advanced help text |
| `current_calver_month` | Return current month as `YY.MM` |
| `is_version_candidate` | Test whether a string looks like a version |
| `normalize_base_dir` | Resolve and validate the base directory |
| `normalize_base_version_override` | Normalize a base-version override (`YY.MM` to `YY.MM.0`) |
| `iter_candidate_files` | Find candidate version files up to a max depth |
| `parse_pyproject` | Read version from `pyproject.toml` project/poetry sections |
| `parse_simple_version_file` | Read a plain `VERSION`/`version.txt` file |
| `build_version_file_entry` | Build a VERSION-file entry dict |
| `parse_version_py` | Read version assignments from `version.py` |
| `parse_versions` | Scan the repo for all version sources |
| `ensure_version_file_entry` | Ensure the root VERSION file is represented |
| `resolve_source_entry` | Resolve a source entry by path |
| `choose_base_version` | Choose the base version (single or via `--source`) |
| `bump_version` | Bump a semantic version by mode |
| `parse_version_details` | Split a version string into parts (PEP 440, CalVer, dash) |
| `validate_yy_mm_patch` | Validate `YY.MM.PATCH` with optional prerelease |
| `format_version` | Build a version string from parts |
| `format_number` | Format a number with optional zero padding |
| `bump_prerelease` | Add or bump a prerelease suffix |
| `update_pyproject` | Rewrite version lines in `pyproject.toml` text |
| `normalize_target_version` | Normalize target for patch-optional entries |
| `update_simple_version` | Rewrite a plain version file |
| `update_version_py` | Rewrite version assignments in `version.py` |
| `update_entry` | Read, transform, and optionally write one entry |
| `main` | Discover, bump, and update version files |

## changelog_lib.py

Shared library for the three changelog scripts: parser, serializer, git
helpers, and console primitives. No CLI.

Dataclasses: `DayBlock` (one `## YYYY-MM-DD` block), `Entry` (one bullet under
a block).

| Function | Does |
| --- | --- |
| `read_changelog` | Read a changelog file to a string |
| `write_changelog` | Write a changelog from preamble and day blocks |
| `parse_day_blocks` | Parse text into preamble and day blocks |
| `split_day_block` | Split a day block into `Entry` records by category |
| `parse_text` | Parse a changelog string |
| `parse_file` | Read and parse a changelog file |
| `newest_date` | Return the first block's date, or `None` |
| `find_duplicate_dates` | Return dates that appear more than once |
| `run_git` | Run a git command and return the result |
| `get_git_root` | Return the repo root path |
| `ensure_in_git_repo` | Raise if not inside a git work tree |
| `build_choice_prompt` | Add a colored `[y/N]` suffix to a prompt |
| `confirm` | Prompt for a y/N response |
| `print_warning` | Print a yellow warning |
| `print_error` | Print a red error to stderr |

## commit_changelog.py

Draft a commit message from newly ADDED changelog bullets (detected via
`git diff HEAD`), open it in the editor for review, then commit via
`git commit -a -F`. Edited old bullets are excluded silently; a
consecutive-heading-run filter is applied as a safety boundary.
Interactive; no argparse.

| Function | Does |
| --- | --- |
| `read_version_file` | Read and strip the VERSION file |
| `current_calver_month` | Return current month as `YY.MM` |
| `check_version_freshness` | Warn and prompt if VERSION is not the current month |
| `get_git_status_lines` | Return `git status --porcelain=1` lines |
| `get_untracked_files` | Extract untracked files from status |
| `get_unmerged_paths` | Return paths with merge conflicts |
| `format_status_entry` | Format one git status entry |
| `build_git_status_block` | Build the git-status comment block |
| `get_editor_cmd` | Return the editor argv (`GIT_EDITOR`/`EDITOR`/`nano`) |
| `edit_file_in_editor` | Open a file in the editor |
| `build_action_prompt` | Add a colored `[yes/no/commit]` suffix |
| `prompt_message_action` | Prompt for yes/no/commit |
| `strip_git_style_comments` | Remove `#` comment lines |
| `get_diff` | Get the unstaged diff for a path |
| `get_cached_diff` | Get the staged diff for a path |
| `get_diff_vs_head` | Working-tree diff vs HEAD for a path (no-color, unified=0) |
| `parse_added_bullet_lines` | Set of new-side line numbers for added top-level bullets in a unified=0 diff |
| `added_changelog_bullet_lines` | Thin wrapper: added bullet lines in the changelog vs HEAD |
| `keep_recent_heading_run` | Filter candidates to the most recent consecutive heading run |
| `select_new_entries` | Return added-bullet entries and parse warnings |
| `strip_markdown_links` | Convert `[label](url)` to `label` |
| `strip_markdown_bold` | Convert bold markup to plain text |
| `collapse_whitespace` | Collapse whitespace runs to one space |
| `truncate_text` | Truncate and append `...` |
| `clean_entry_text` | Strip markup, collapse, and truncate |
| `make_seed_message_from_entries` | Build the commit message from entries |
| `write_message_file` | Write the message to a temp file |
| `edit_message` | Edit the message in the editor |
| `commit_with_message_file` | Run `git commit -a -F` |
| `main` | Orchestrate the full draft-and-commit flow |

## query_changelog.py

Read-only search over the active `docs/CHANGELOG.md` and archives, filtered by
date range, category, and keyword. Outputs text, JSON, or CSV.

Key flags: `--from`/`--since`/`--to` (dates), `-c/--category`, `-k/--keyword`,
`--any-keyword`, `--case-sensitive`, `--archives/--all`, `--format`, `--count`.

| Function | Does |
| --- | --- |
| `today_or` | Return the supplied date or today (test seam) |
| `parse_iso_date` | Parse `YYYY-MM-DD` or exit with an error |
| `resolve_categories` | Map aliases to canonical category headings |
| `collect_files` | Return changelog files newest-first, optionally filtered |
| `apply_filters` | Filter entries by date, category, and keyword |
| `category_sort_key` | Return the canonical sort index for a category |
| `format_text` | Render entries as grouped text |
| `format_json` | Render entries as a JSON array |
| `format_csv` | Render entries as CSV |
| `parse_args` | Parse CLI arguments |
| `main` | Resolve corpus, filter, and emit output |

## rotate_changelog.py

Keep the two most recent day blocks in `docs/CHANGELOG.md` and archive the rest
into `docs/CHANGELOG-YYYY-MM[a-z].md`, refusing to clobber a boundary date.
Interactive with dry-run and force.

Flags: `-n/--dry-run`, `-f/--force`, `-t/--threshold`, `-y/--yes`.

| Function | Does |
| --- | --- |
| `split_active_archive` | Split into the two active blocks and the archive rest |
| `compute_archive_path` | Compute the next-unused archive filename |
| `find_boundary_conflict` | Detect an active date already living in an archive |
| `print_loud_warning` | Print a boundary-conflict banner |
| `print_duplicate_error` | Print a duplicate-date error |
| `print_plan` | Print the rotation plan |
| `parse_args` | Parse CLI arguments |
| `main` | Validate, plan, confirm, and write the rotation |

## flatten_broken_md_links.py

Rewrite broken Markdown links by matching broken URLs to tracked files via
basename, delink unmatched links, and normalize path-like text. Dry-run by
default; `--apply` writes.

Flags: `-a/--apply`, `-v/--verbose`, `-c/--include-changelog`,
`-p/--include-active-plans`, `-e/--include-experiments`,
`-C/--include-canonical`.

| Function | Does |
| --- | --- |
| `get_repo_root` | Get the repo root via `git rev-parse` |
| `build_tracked_set` | Return relative paths of all tracked files |
| `build_basename_index` | Build basename to relpath indexes (canonical + archive) |
| `split_anchor` | Split a URL into path and `#anchor` |
| `is_local_file_link` | True if a URL looks like a local file |
| `link_target_tracked` | True if a link resolves to a tracked file |
| `find_basename_match` | Look up a basename, preferring canonical |
| `process_file` | Rewrite broken links in one file; return counts |
| `parse_args` | Parse CLI arguments |
| `main` | Walk source files and rewrite broken links |

## dist_clean.sh

Remove build outputs, tool caches, and dependency installs across Python,
TypeScript, and Rust repos. No flags; missing patterns are silent no-ops via
`nullglob`. Cleans: generic build dirs (`dist`, `build`, `_site`, `out`),
TypeScript/JS artifacts and `node_modules`, JS/TS tool caches, test outputs,
Python caches (`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`),
and the Rust `target` dir; prints a count of deleted paths.
