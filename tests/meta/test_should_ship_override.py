"""
Tests for should_ship_override predicate routing logic.

Covers language-specific and requirement-based file routing rules.
"""

import os
import tempfile

import file_utils

repo_root = file_utils.get_repo_root()

from repolib.files import should_ship_override
from repolib.model import LANG_PYTHON, LANG_TYPESCRIPT, LANG_OTHER, LANG_UNKNOWN


class TestShouldShipOverridePythonRepo:
	"""Test cases for Python repository type."""

	def test_python_style_ships_to_python_repo(self) -> None:
		"""docs/PYTHON_STYLE.md ships to python repos."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('docs/PYTHON_STYLE.md', LANG_PYTHON, tmpdir)
			assert result is True

	def test_python_style_blocked_from_typescript_repo(self) -> None:
		"""docs/PYTHON_STYLE.md is blocked for typescript repos."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('docs/PYTHON_STYLE.md', LANG_TYPESCRIPT, tmpdir)
			assert result is False

	def test_pip_requirements_ships_to_python_repo(self) -> None:
		"""pip_requirements.txt ships to python repos (bucket: noexist)."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('pip_requirements.txt', LANG_PYTHON, tmpdir)
			assert result is True

	def test_pip_requirements_dev_ships_to_python_repo(self) -> None:
		"""pip_requirements-dev.txt ships to python repos (bucket: noexist)."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('pip_requirements-dev.txt', LANG_PYTHON, tmpdir)
			assert result is True

	def test_submit_to_pypi_requires_pyproject_toml(self) -> None:
		"""devel/submit_to_pypi.py requires pyproject.toml to exist."""
		# Case: pyproject.toml missing
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('devel/submit_to_pypi.py', LANG_PYTHON, tmpdir)
			assert result is False

		# Case: pyproject.toml present
		with tempfile.TemporaryDirectory() as tmpdir:
			pyproject_path = os.path.join(tmpdir, 'pyproject.toml')
			with open(pyproject_path, 'w') as f:
				f.write('[project]\nname = "test"\n')
			result = should_ship_override('devel/submit_to_pypi.py', LANG_PYTHON, tmpdir)
			assert result is True


class TestShouldShipOverrideOtherRepos:
	"""Test cases for 'other' and non-python repository types."""

	def test_python_style_blocked_from_other_repo(self) -> None:
		"""docs/PYTHON_STYLE.md is blocked for 'other' repos."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('docs/PYTHON_STYLE.md', LANG_OTHER, tmpdir)
			assert result is False

	def test_submit_to_pypi_blocked_from_other_repo(self) -> None:
		"""devel/submit_to_pypi.py is blocked for non-python repos."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('devel/submit_to_pypi.py', LANG_OTHER, tmpdir)
			assert result is False


class TestShouldShipOverrideUnknownRepos:
	"""Test cases for unknown/unmarked repository type."""

	def test_python_style_blocked_from_unknown_repo(self) -> None:
		"""docs/PYTHON_STYLE.md is blocked for unknown repos."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('docs/PYTHON_STYLE.md', LANG_UNKNOWN, tmpdir)
			assert result is False


class TestShouldShipOverrideNoOverride:
	"""Test cases where no override applies."""

	def test_no_override_for_unregistered_file(self) -> None:
		"""Unregistered files return None (no override)."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('docs/README.md', LANG_PYTHON, tmpdir)
			assert result is None

	def test_no_override_for_random_path(self) -> None:
		"""Random paths not in ROUTING_OVERRIDES return None."""
		with tempfile.TemporaryDirectory() as tmpdir:
			result = should_ship_override('src/app.py', LANG_TYPESCRIPT, tmpdir)
			assert result is None


class TestShouldShipOverrideExcludeRepos:
	"""Test cases for per-destination-repo exclusion."""

	def test_hook_guide_blocked_from_source_repo(self) -> None:
		"""docs/CLAUDE_HOOK_USAGE_GUIDE.md is blocked for claude-code-permissions-hook."""
		with tempfile.TemporaryDirectory() as tmpdir:
			dest = os.path.join(tmpdir, 'claude-code-permissions-hook')
			os.makedirs(dest)
			result = should_ship_override('docs/CLAUDE_HOOK_USAGE_GUIDE.md', LANG_PYTHON, dest)
			assert result is False

	def test_hook_guide_ships_to_other_repo(self) -> None:
		"""docs/CLAUDE_HOOK_USAGE_GUIDE.md ships to any other repo."""
		with tempfile.TemporaryDirectory() as tmpdir:
			dest = os.path.join(tmpdir, 'some-other-repo')
			os.makedirs(dest)
			result = should_ship_override('docs/CLAUDE_HOOK_USAGE_GUIDE.md', LANG_PYTHON, dest)
			assert result is True

	def test_hook_guide_exclusion_ignores_trailing_slash(self) -> None:
		"""Trailing slash on repo_dir does not defeat the exclusion."""
		with tempfile.TemporaryDirectory() as tmpdir:
			dest = os.path.join(tmpdir, 'claude-code-permissions-hook') + os.sep
			os.makedirs(dest)
			result = should_ship_override('docs/CLAUDE_HOOK_USAGE_GUIDE.md', LANG_PYTHON, dest)
			assert result is False


class TestShouldShipOverrideGuardrails:
	"""Guardrail tests: verify ROUTING_OVERRIDES table structure."""

	def test_all_override_keys_are_valid_paths(self) -> None:
		"""Every ROUTING_OVERRIDES key exists in the template."""
		from repolib.model import ROUTING_OVERRIDES

		# template_root is the repo root (tests/meta/../.. = repo root)
		template_root = repo_root

		# Each key must be a repo-root-relative path that exists in the template
		for file_rel in ROUTING_OVERRIDES.keys():
			full_path = os.path.join(template_root, file_rel)
			assert os.path.exists(full_path), (
				f"ROUTING_OVERRIDES key {file_rel!r} does not exist at {full_path}"
			)

	def test_all_override_values_have_valid_schema(self) -> None:
		"""Every ROUTING_OVERRIDES rule has valid schema."""
		from repolib.model import ROUTING_OVERRIDES

		valid_lang_values = {'universal', 'python', 'typescript', 'rust', 'other', 'unknown'}
		valid_bucket_values = {'overwrite_files', 'noexist_files', 'devel_files', 'test_files', 'noexist'}

		for file_rel, rule in ROUTING_OVERRIDES.items():
			# Rule must be a dict
			assert isinstance(rule, dict), f"Rule for {file_rel!r} is not a dict"

			# language: if present, must be valid
			if 'language' in rule:
				assert rule['language'] in valid_lang_values, (
					f"Invalid language {rule['language']!r} in rule for {file_rel!r}"
				)

			# bucket: if present, must be valid (shorthand 'noexist' or full 'noexist_files', etc.)
			if 'bucket' in rule:
				assert rule['bucket'] in valid_bucket_values, (
					f"Invalid bucket {rule['bucket']!r} in rule for {file_rel!r}"
				)

			# requires_repo_file: if present, must be a string (path fragment)
			if 'requires_repo_file' in rule:
				assert isinstance(rule['requires_repo_file'], str), (
					f"requires_repo_file {rule['requires_repo_file']!r} is not a string"
				)
				assert rule['requires_repo_file'], (
					f"requires_repo_file cannot be empty for {file_rel!r}"
				)

			# exclude_repos: if present, must be a non-empty collection of repo names
			if 'exclude_repos' in rule:
				assert isinstance(rule['exclude_repos'], (frozenset, set, tuple, list)), (
					f"exclude_repos for {file_rel!r} must be a set/frozenset/list/tuple"
				)
				assert rule['exclude_repos'], (
					f"exclude_repos cannot be empty for {file_rel!r}"
				)
