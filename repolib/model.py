"""Data models and propagation spec/plan logic."""

import os
from dataclasses import dataclass

#============================================
# Orchestration context dataclass
#============================================

@dataclass
class PropagateContext:
	"""
	Context object passed to orchestration helpers.
	Mirrors all args fields that downstream helpers need. Treat as read-only after construction.
	"""
	source_dir: str
	template_root: str
	repo_name: str | None
	dry_run: bool
	initial_setup: bool
	# auto_discover: source-template test discovery for ONE repo. When True, the
	# source template's tests/ is scanned for test_*.py/test_*.mjs files absent
	# from the static spec, and those are added to the files copied INTO the
	# target repo. It never walks other repos; the meaning is single-repo only.
	auto_discover: bool
	write_marker: bool

#============================================
# Default skip list for repo discovery
#============================================
DEFAULT_REPO_SKIP_NAMES = frozenset({
	'starter-repo-template',
	'vosslab-skills',
})

#============================================
# Propagation manifests: folder convention + thin rules
#============================================

# Root-level files that repolib propagates (ships) to every consumer repo's root.
# Relationship with UNIVERSAL_NOEXIST: ROOT_PROPAGATE_ALLOWLIST says a root file
# MAY ship; UNIVERSAL_NOEXIST then refines HOW it ships (overwrite vs noexist-only).
# Overlap is expected: AGENTS.md and source_me.sh appear in both -- allowlisted
# to ship, then routed noexist-only so they don't clobber consumer customizations.
# CLAUDE.md is allowlisted and routed via MERGE_FILES (set-union @-import merge), not overwrite.
ROOT_PROPAGATE_ALLOWLIST = frozenset({
	'CLAUDE.md',
	'AGENTS.md',
	'source_me.sh',
	'dist_clean.sh',
})

# Language type constants
LANG_UNIVERSAL = 'universal'
LANG_PYTHON = 'python'
LANG_TYPESCRIPT = 'typescript'
LANG_RUST = 'rust'
LANG_OTHER = 'other'
LANG_UNKNOWN = 'unknown'

# Routing overrides: files with language-specific or requirement-based routing rules.
# Maps file_rel -> {language: ..., requires_repo_file: ..., exclude_repos: ..., bucket: ...}
# language: blocks file unless repo_lang matches
# requires_repo_file: blocks file unless repo_file exists at repo_dir
# exclude_repos: blocks file when the destination repo basename is in this set/list
#   (used for docs that are sourced FROM a specific repo and must never ship back to it)
# bucket: optional shorthand ('noexist', 'overwrite', ...) appended with '_files' at dispatch;
#   read by the caller after should_ship_override returns True (not by the predicate itself)
ROUTING_OVERRIDES = {
	'docs/PYTHON_STYLE.md': {'language': LANG_PYTHON},
	'pip_requirements.txt': {'language': LANG_PYTHON, 'bucket': 'noexist'},
	'pip_requirements-dev.txt': {'language': LANG_PYTHON, 'bucket': 'noexist'},
	'devel/submit_to_pypi.py': {'language': LANG_PYTHON, 'requires_repo_file': 'pyproject.toml'},
	# CLAUDE_HOOK_USAGE_GUIDE.md is sourced from claude-code-permissions-hook;
	# never copy the mirror back over that repo's source of truth.
	'docs/CLAUDE_HOOK_USAGE_GUIDE.md': {'exclude_repos': frozenset({'claude-code-permissions-hook'})},
}

# Files routed to the MERGE bucket (set-union @-import merge). Template
# @-imports are union-added to the consumer file; any consumer line listed in
# meta/propagation/deprecated_claude_md.txt is stripped. Consumer-local
# @-imports and non-@ content are preserved. See meta/docs/MERGE_BUCKET_SPEC.md.
MERGE_FILES = frozenset({
	'CLAUDE.md',
})


# Files that ship only when absent at consumer (universal noexist).
# Overrides the docs/ universal-overwrite default. Example: docs/AUTHORS.md is universal but ships noexist-only.
# Path is repo-root-relative.
# Relationship with ROOT_PROPAGATE_ALLOWLIST: allowlist gates ship/don't-ship at root;
# this set refines kept files to noexist-only. Membership in both is intentional.
UNIVERSAL_NOEXIST = frozenset({
	'AGENTS.md',
	'source_me.sh',
	'docs/AUTHORS.md',
	# Consumer-owned test-suite README; template seed exists but must not clobber consumer edits.
	'tests/TESTS_README.md',
})


# Files that NEVER ship (template-meta).
META_FILES = frozenset({
	'propagate_style_guides.py',
	'reset_repo.py',
	'README.md',
	'VERSION',
	'.gitignore',
	'REPO_TYPE',
	'Brewfile',
	'pip_extras.txt',
	'docs/CHANGELOG.md',
})

# Dirs that NEVER ship. Walked but never produce routing entries.
# 'meta' is defense-in-depth: SKIP_WALK_DIRS already trims it during os.walk,
# but is_in_meta_dir() also checks META_DIRS so any future code path that
# reaches that check for a meta/... rel-path is still excluded.
META_DIRS = frozenset({
	'LICENSES',
	'templates',
	'meta',
	'repolib',
	'tools',
	'docs/active_plans',
	'docs/archive',
	'experiment_reports',
	'__pycache__',
	'.git',
})

SKIP_WALK_DIRS = frozenset({
	'.git',
	'.mypy_cache',
	'.pytest_cache',
	'old_shell_folder',
	'.venv',
	'.system',
	'__pycache__',
	'build',
	'dist',
	'node_modules',
	'venv',
	'meta',  # tests/meta/ contains template-meta tests only; excluded from propagation
	# 'tools' (dir-form) replaces the prior per-file 'tools/detect_repo_type.py' entry in META_FILES,
	# applying the three-tier principle: directory convention when possible (see meta/docs/PROPAGATION_RULES.md).
	'tools',
})

AUTO_DISCOVER_DOCS_EXCLUDE = frozenset({
	'AUTHORS.md',
	'CHANGELOG.md',
})

# Template-meta tests: validate the template's own infrastructure
# (propagate_style_guides, reset_repo, detect_repo_type).
# These must NOT propagate to consumers because the imported modules
# are git rm'd at consumer bootstrap, causing ImportError at pytest collection.
# Meta tests use these prefixes to distinguish from regular repo tests.
META_TEST_PREFIXES = (
	'test_repolib_',
	'test_reset_repo_',
	'test_detect_repo_type',
)




#============================================
# Source/target path resolution
#============================================

def source_path_for_bucket(template_root: str, bucket: str, file_rel: str, repo_type: str = 'universal') -> str:
	"""
	Resolve canonical source path for a file in a bucket.
	Handles universal files at template root and typed files under templates/<repo_type>/.
	For noexist_files, looks under templates/<repo_type>/noexist/ as well as root.
	"""
	# Normalize repo_type alias
	if repo_type == 'universal':
		repo_type = 'python'

	# Determine candidate paths based on bucket.
	if bucket == 'devel_files':
		# devel files: template_root/devel/<name>
		candidate = os.path.join(template_root, 'devel', file_rel)
		if os.path.isfile(candidate):
			return candidate
		# Also check typed overlay
		candidate = os.path.join(template_root, 'templates', repo_type, 'devel', file_rel)
		if os.path.isfile(candidate):
			return candidate

	elif bucket == 'test_files':
		# test files: file_rel already includes tests/ prefix, so just join directly
		candidate = os.path.join(template_root, file_rel)
		if os.path.isfile(candidate):
			return candidate
		candidate = os.path.join(template_root, 'templates', repo_type, file_rel)
		if os.path.isfile(candidate):
			return candidate

	elif bucket == 'noexist_files':
		# noexist files: could be at template root (universal) or under templates/<type>/noexist/<path>
		candidate = os.path.join(template_root, file_rel)
		if os.path.isfile(candidate):
			return candidate
		# Check typed noexist
		candidate = os.path.join(template_root, 'templates', repo_type, 'noexist', file_rel)
		if os.path.isfile(candidate):
			return candidate

	else:
		# overwrite_files (or default): typed under templates/<type>/ shadows universal at root
		candidate = os.path.join(template_root, 'templates', repo_type, file_rel)
		if os.path.isfile(candidate):
			return candidate
		candidate = os.path.join(template_root, file_rel)
		if os.path.isfile(candidate):
			return candidate

	raise FileNotFoundError(f"canonical source missing for {bucket} entry {file_rel!r}")


def find_source_for_bucket(template_root: str, bucket: str, file_rel: str, repo_type: str = 'universal') -> str | None:
	"""
	Resolve canonical source path for a file in a bucket, or return None if not found.

	Non-raising variant of source_path_for_bucket() for cleaner predicate-based control flow.

	Args:
		template_root (str): Template root directory.
		bucket (str): Bucket name (overwrite_files, noexist_files, devel_files, test_files).
		file_rel (str): Relative path of the file.
		repo_type (str): Repository type (python, typescript, rust, other). Defaults to 'universal'.

	Returns:
		str | None: Canonical source path if found, None otherwise.
	"""
	# Normalize repo_type alias
	if repo_type == 'universal':
		repo_type = 'python'

	# Determine candidate paths based on bucket.
	if bucket == 'devel_files':
		# devel files: template_root/devel/<name>
		candidate = os.path.join(template_root, 'devel', file_rel)
		if os.path.isfile(candidate):
			return candidate
		# Also check typed overlay
		candidate = os.path.join(template_root, 'templates', repo_type, 'devel', file_rel)
		if os.path.isfile(candidate):
			return candidate

	elif bucket == 'test_files':
		# test files: file_rel already includes tests/ prefix, so just join directly
		candidate = os.path.join(template_root, file_rel)
		if os.path.isfile(candidate):
			return candidate
		candidate = os.path.join(template_root, 'templates', repo_type, file_rel)
		if os.path.isfile(candidate):
			return candidate

	elif bucket == 'noexist_files':
		# noexist files: could be at template root (universal) or under templates/<type>/noexist/<path>
		candidate = os.path.join(template_root, file_rel)
		if os.path.isfile(candidate):
			return candidate
		# Check typed noexist
		candidate = os.path.join(template_root, 'templates', repo_type, 'noexist', file_rel)
		if os.path.isfile(candidate):
			return candidate

	else:
		# overwrite_files (or default): typed under templates/<type>/ shadows universal at root
		candidate = os.path.join(template_root, 'templates', repo_type, file_rel)
		if os.path.isfile(candidate):
			return candidate
		candidate = os.path.join(template_root, file_rel)
		if os.path.isfile(candidate):
			return candidate

	return None


def target_path_for_bucket(repo_dir: str, bucket: str, file_rel: str) -> str:
	"""
	Resolve target path at consumer repo.
	Note: for test_files, file_rel includes 'tests/' prefix (e.g., 'tests/test_foo.py').
	For devel_files, file_rel is a bare name (e.g., 'submit_to_pypi.py').
	"""
	if bucket == 'devel_files':
		return os.path.join(repo_dir, 'devel', file_rel)
	# test_files: file_rel already includes 'tests/' prefix; other buckets are repo-root-relative.
	return os.path.join(repo_dir, file_rel)


def format_path_pair(source_file: str, dest_file: str, repo_dir: str, context: 'PropagateContext') -> str:
	"""
	Format a source-dest file pair for logging using repo-relative paths.

	  - If src relative path == dst relative path, show only the dst relative path
	  - Otherwise, show both as "src_rel -> dst_rel"

	Args:
		source_file (str): Absolute source file path.
		dest_file (str): Absolute destination file path.
		repo_dir (str): Repository directory path.
		context (PropagateContext): Context with source_dir.

	Returns:
		str: Formatted path string for logging.
	"""
	# Compute relative paths
	src_relative = os.path.relpath(source_file, context.source_dir)
	dst_relative = os.path.relpath(dest_file, repo_dir)

	# If relative paths are the same, show only one
	if src_relative == dst_relative:
		return dst_relative

	# Otherwise show both
	return f"{src_relative} -> {dst_relative}"
