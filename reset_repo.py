#!/usr/bin/env python3
"""
reset_repo.py - bootstrap a fresh clone of starter-repo-template.

Prompts (or accepts flags) for project type and SPDX licenses, writes the
REPO_TYPE marker, installs selected LICENSE files, calls repolib directly
to lay down type-dispatched files in bootstrap mode, truncates README +
CHANGELOG, and removes itself.
"""

import os
import sys
import argparse
import datetime
import subprocess
import tempfile

# local repo modules
import repolib.console
import repolib.process

# Try to import detect_repo_type from tools/; if not available, prediction is skipped.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tools'))
try:
	import detect_repo_type
except ImportError:
	detect_repo_type = None

CODE_LICENSES = ["MIT", "Apache-2.0", "LGPL-3.0", "GPL-3.0", "AGPL-3.0", "MPL-2.0"]
DOCS_LICENSES = ["CC-BY-4.0", "CC-BY-SA-4.0", "none"]

CODE_ALIASES = {
	"m": "MIT",
	"a": "Apache-2.0",
	"l": "LGPL-3.0",
	"g": "GPL-3.0",
	"ag": "AGPL-3.0",
	"mp": "MPL-2.0",
}

DOCS_ALIASES = {
	"cb": "CC-BY-4.0",
	"cs": "CC-BY-SA-4.0",
	"n": "none",
}

TYPE_TOKENS = ["python", "typescript", "rust", "other"]


def resolve_license(user_input: str, canonical: list, aliases: dict, default: str | None = None) -> str:
	"""Resolve license token via alias or unique prefix."""
	token = user_input.strip().lower()
	if token == "":
		if default is None:
			raise ValueError("empty license input; no default available")
		return default
	if token in aliases:
		return aliases[token]
	matches = [name for name in canonical if name.lower().startswith(token)]
	if len(matches) == 1:
		return matches[0]
	raise ValueError(f"ambiguous or unknown license: {user_input!r}")


def get_repo_root() -> str:
	"""Return the repository root path via git rev-parse."""
	try:
		result = subprocess.run(
			["git", "rev-parse", "--show-toplevel"],
			capture_output=True,
			text=True,
			check=True,
		)
		return result.stdout.strip()
	except subprocess.CalledProcessError:
		sys.exit("Error: not in a git repository")


def preflight_check(repo_root: str, code_license: str, docs_license: str) -> None:
	"""Verify that license files exist in LICENSES/ before proceeding."""
	code_path = os.path.join(repo_root, f"LICENSES/LICENSE.{code_license}.md")
	if not os.path.isfile(code_path):
		sys.exit(f"license file missing: {code_path}")
	if docs_license != "none":
		docs_path = os.path.join(repo_root, f"LICENSES/LICENSE.{docs_license}.md")
		if not os.path.isfile(docs_path):
			sys.exit(f"license file missing: {docs_path}")


def verify_license_copy(repo_root: str, license_type: str, spdx_id: str) -> bool:
	"""Check if license file was copied and contains recognizable license text."""
	target = os.path.join(repo_root, f"LICENSE.{spdx_id}.md")
	if not os.path.isfile(target):
		return False
	if os.path.getsize(target) == 0:
		return False
	with open(target, "r") as f:
		first_bytes = f.read(100)
	normalized_spdx = spdx_id.replace("-", " ")
	return spdx_id in first_bytes or normalized_spdx in first_bytes


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(
		description="Reset a cloned starter-repo-template to base configuration"
	)
	parser.add_argument(
		"--type",
		dest="project_type",
		choices=TYPE_TOKENS,
		help="Project type (python, typescript, rust, other)",
	)
	parser.add_argument(
		"--code-license",
		dest="code_license",
		help="Code license (SPDX id, alias, or unique prefix)",
	)
	parser.add_argument(
		"--docs-license",
		dest="docs_license",
		help="Docs license (SPDX id, alias, unique prefix, or 'none')",
	)
	parser.add_argument(
		"--non-interactive",
		dest="non_interactive",
		action="store_true",
		help="Non-interactive mode (requires all three content flags)",
	)
	parser.add_argument(
		"--yes",
		dest="skip_confirm",
		action="store_true",
		help="Skip final confirmation prompt",
	)
	parser.add_argument(
		"--dry-run",
		dest="dry_run",
		action="store_true",
		help="Print actions without executing",
	)
	parser.add_argument(
		"--commit",
		dest="commit",
		action="store_true",
		help="Create commit after staging changes",
	)
	parser.add_argument(
		"--no-stage",
		dest="no_stage",
		action="store_true",
		help="Leave changes in working tree, do not stage",
	)
	parser.add_argument(
		"--force",
		dest="force",
		action="store_true",
		help="Allow overwriting existing marker and package.json",
	)
	return parser.parse_args()


#============================================
# Module-level helpers (extracted from main)
#============================================

def dry_run_print(msg: str, dry_run: bool) -> None:
	"""Print DRY-RUN prefixed message if dry_run is True."""
	if dry_run:
		print(f"DRY-RUN: {msg}")


def write_marker(repo_root: str, project_type: str, dry_run: bool) -> int:
	"""Write REPO_TYPE marker atomically via temp + replace."""
	marker_path = os.path.join(repo_root, "REPO_TYPE")
	content = f"{project_type}\n"
	if dry_run:
		escaped_content = content.replace('"', '\\"').replace('\n', '\\n')
		dry_run_print(f'write REPO_TYPE ("{escaped_content}")', dry_run)
	else:
		with tempfile.NamedTemporaryFile(
			mode="w", dir=repo_root, delete=False
		) as tmp:
			tmp.write(content)
			tmp_name = tmp.name
		os.replace(tmp_name, marker_path)
	return 1


def copy_and_verify_license(repo_root: str, source_path: str, target_filename: str, spdx_id: str, dry_run: bool) -> int:
	"""Copy LICENSES/LICENSE.<spdx>.md to repo root and verify."""
	target_path = os.path.join(repo_root, target_filename)
	if dry_run:
		dry_run_print(f"copy {source_path} -> {target_path}", dry_run)
		dry_run_print(
			f"verify {target_filename}: file exists, non-zero, contains {spdx_id}", dry_run
		)
		return 2
	else:
		with open(source_path, "r") as src:
			content = src.read()
		with open(target_path, "w") as dst:
			dst.write(content)
		if not verify_license_copy(repo_root, "code", spdx_id):
			rollback_msg = "Rollback: run 'git restore --staged . && git restore .' to discard staged and working-tree changes."
			sys.exit(
				f"License copy verification failed: {target_filename}\n{rollback_msg}"
			)
		return 1


def git_rm(path: str, dry_run: bool) -> int:
	"""Remove tracked file via git rm."""
	if dry_run:
		dry_run_print(f"git rm {path}", dry_run)
	else:
		subprocess.run(["git", "rm", path], check=True, capture_output=True)
	return 1


def git_rm_recursive(path: str, dry_run: bool) -> int:
	"""Remove tracked directory recursively via git rm -r."""
	if dry_run:
		dry_run_print(f"git rm -r {path}", dry_run)
	else:
		subprocess.run(["git", "rm", "-r", path], check=True, capture_output=True)
	return 1


def substitute_typescript_package_json(repo_root: str, dry_run: bool) -> int:
	"""Substitute __REPO_NAME__ and __REPO_VERSION__ in package.json in-place."""
	package_json_path = os.path.join(repo_root, "package.json")
	if not os.path.isfile(package_json_path):
		return 0
	with open(package_json_path, "r") as f:
		content = f.read()
	# Guard: only substitute when placeholders are present, so an existing
	# consumer-customized package.json is left untouched (noexist bucket
	# already protects against overwrite at copy time; this is belt-and-braces).
	if "__REPO_NAME__" not in content:
		return 0
	repo_name = os.path.basename(repo_root)
	# CalVer: YYYY.M.0 (no leading zero on month per CalVer convention)
	now = datetime.datetime.now()
	repo_version = f"{now.year}.{now.month}.0"
	if dry_run:
		dry_run_print(
			f"substitute __REPO_NAME__ -> {repo_name}, __REPO_VERSION__ -> {repo_version} in {package_json_path}", dry_run
		)
		return 1
	content = content.replace("__REPO_NAME__", repo_name)
	content = content.replace("__REPO_VERSION__", repo_version)
	with open(package_json_path, "w") as f:
		f.write(content)
	return 1


def run_propagate(repo_root: str, dry_run: bool) -> int:
	"""Lay down type-dispatched template files into repo_root via repolib.

	In dry-run, process_repo previews actions without writing.

	Raises:
		RuntimeError: When process_repo returns None (propagation was skipped).
			This means initial-setup propagation silently no-opped, which must
			never happen during reset.
	"""
	# Build a initial-setup context and run the propagator directly.
	# process_repo honors context.dry_run: it logs planned actions and skips
	# all file mutations when dry_run is True.
	context = repolib.process.build_context_for_repo(
		repo_path=repo_root,
		dry_run=dry_run,
		initial_setup=True,
		auto_discover=False,
		write_marker=False,
	)
	counters = repolib.console.init_counters()
	result = repolib.process.process_repo(repo_root, context, counters, emit_per_repo_summary=False)
	# None return means process_repo intentionally skipped this repo (self-skip guard
	# or not a repo dir). During reset, propagation must always run to completion.
	if result is None:
		raise RuntimeError(
			f"initial-setup propagation was skipped for repo: {repo_root}\n"
			"process_repo returned None -- the self-skip guard may have fired. "
			"Ensure repolib is configured with initial_setup=True (initial-setup)."
		)
	return 1


# Template-owned root-level directories that must be absent after reset cleanup.
# Only the specific template convention locations for "meta" are checked:
# root meta/ and tests/meta/. Legitimate consumer meta/ elsewhere is not rejected.
# Note: root tools/ is intentionally NOT listed. The cleanup phase still runs
# `git rm -r tools/` to remove the template's own tracked root tools/ (e.g.
# tools/detect_repo_type.py), but typed overlays may now legitimately ship files
# into a consumer's tools/ (e.g. tools/sync_typescript_package_pins.py for
# typescript). Those freshly propagated, still-untracked files survive `git rm`
# and must not trip the end-state verifier, so tools/ is not an owned prefix.
TEMPLATE_OWNED_PREFIXES = [
	"templates/",
	"repolib/",
	"LICENSES/",
	"meta/",
	"tests/meta/",
]

# Sentinel scaffold paths that must exist after successful propagation, by project type.
# Each entry is (project_type, relative_path). Rust and other are skipped (no sentinel).
SCAFFOLD_SENTINELS: dict[str, str] = {
	"typescript": "eslint.config.js",
	"python": "docs/PYTHON_STYLE.md",
}


def verify_clean_end_state(repo_root: str, dry_run: bool) -> int:
	"""Verify no template-owned paths remain after cleanup.

	In dry-run, logs the check that would be performed.
	In live mode, checks (a) git ls-files and (b) disk for each TEMPLATE_OWNED_PREFIXES
	entry. Raises RuntimeError listing every leftover path found. Note that root
	tools/ is deliberately excluded from TEMPLATE_OWNED_PREFIXES: typed overlays may
	ship files into a consumer's tools/ (e.g. tools/sync_typescript_package_pins.py),
	so a tools/ directory remaining on disk after `git rm -r tools/` is expected and
	must not fail this verifier.

	Returns:
		int: 1 (action taken or announced).

	Raises:
		RuntimeError: When any template-owned path remains tracked or on disk.
	"""
	if dry_run:
		print("DRY-RUN: verify: would check for leftover template-owned paths")
		return 1

	# (a) Check git ls-files for any tracked path under template-owned prefixes
	ls_result = subprocess.run(
		["git", "ls-files"], check=True, capture_output=True, text=True, cwd=repo_root,
	)
	tracked_paths = ls_result.stdout.splitlines()
	leftover_tracked: list[str] = []
	for tracked_path in tracked_paths:
		for prefix in TEMPLATE_OWNED_PREFIXES:
			if tracked_path.startswith(prefix) or tracked_path == prefix.rstrip("/"):
				leftover_tracked.append(f"tracked: {tracked_path}")
				break

	# (b) Check that root-level template-owned directories are absent on disk.
	# For nested entries like tests/meta/, check the full path.
	leftover_disk: list[str] = []
	for prefix in TEMPLATE_OWNED_PREFIXES:
		# strip trailing slash for os.path.isdir check
		check_path = os.path.join(repo_root, prefix.rstrip("/"))
		if os.path.isdir(check_path):
			leftover_disk.append(f"on disk: {prefix}")

	all_leftovers = leftover_tracked + leftover_disk
	if all_leftovers:
		leftover_list = "\n  ".join(all_leftovers)
		raise RuntimeError(
			f"template-owned paths remain after cleanup:\n  {leftover_list}"
		)
	return 1


def verify_scaffold_sentinel(repo_root: str, project_type: str) -> None:
	"""Assert that at least one required scaffold path exists after propagation.

	This guards against a "successful but empty" propagation regression, where
	process_repo returns a dict but wrote nothing. Only checked for project types
	that have a known sentinel (typescript, python). Raises RuntimeError on failure.

	Args:
		repo_root (str): Repository root path.
		project_type (str): The project type token (e.g. 'typescript', 'python').

	Raises:
		RuntimeError: When the sentinel path is absent after propagation.
	"""
	sentinel = SCAFFOLD_SENTINELS.get(project_type)
	if sentinel is None:
		# rust and other have no sentinel defined; skip silently
		return
	sentinel_path = os.path.join(repo_root, sentinel)
	if not os.path.isfile(sentinel_path):
		raise RuntimeError(
			f"propagation completed but required scaffold path is missing: {sentinel}\n"
			f"Expected at: {sentinel_path}\n"
			"process_repo returned success but may have written nothing."
		)


def truncate_file(path: str, repo_root: str, dry_run: bool) -> int:
	"""Truncate file to zero bytes."""
	full_path = os.path.join(repo_root, path)
	if dry_run:
		dry_run_print(f"truncate {path}", dry_run)
	else:
		open(full_path, "w").close()
	return 1


#============================================
# Config resolution helpers
#============================================

def resolve_project_type(repo_root: str, project_type: str, force: bool, non_interactive: bool) -> str:
	"""Resolve project type via detection, existing marker, or user input."""
	marker_path = os.path.join(repo_root, "REPO_TYPE")
	existing_marker = None
	if os.path.isfile(marker_path):
		with open(marker_path, "r") as f:
			existing_marker = f.read().strip()

	if not project_type:
		if existing_marker and not force:
			default_type = existing_marker
		else:
			# Try to predict repo type (if detect_repo_type module is available)
			if detect_repo_type:
				token, confidence, _ = detect_repo_type.detect_repo_type(repo_root)
				if confidence == 'high' and token != 'ambiguous':
					default_type = token
					if not force:
						# Auto-select high confidence without prompting
						print(f"Detected: {token} (auto-selected; use --force to override)")
						project_type = token
				elif confidence == 'medium':
					default_type = token
				else:
					default_type = "python"
			else:
				default_type = "python"

		if project_type is None:
			if non_interactive:
				project_type = default_type
			else:
				user_input = input(
					f"Project type? [p]ython / [t]ypescript / [r]ust / [o]ther [{default_type[0]}]: "
				).strip()
				if user_input == "":
					project_type = default_type
				elif user_input.lower() == "p":
					project_type = "python"
				elif user_input.lower() == "t":
					project_type = "typescript"
				elif user_input.lower() == "r":
					project_type = "rust"
				elif user_input.lower() == "o":
					project_type = "other"
				else:
					sys.exit("Invalid project type")

	if existing_marker and existing_marker != project_type and not force:
		sys.exit(
			f"Marker already exists ({existing_marker}); use --force to change to {project_type}"
		)

	return project_type


def resolve_licenses(code_license: str, docs_license: str, non_interactive: bool) -> tuple:
	"""Resolve code and docs licenses via alias, prefix, or user input."""
	if not code_license:
		if non_interactive:
			sys.exit("--code-license required in non-interactive mode")
		while True:
			user_input = input(
				"Code license?\n  [m] MIT\n  [a] Apache-2.0\n  [l] LGPL-3.0\n  [g] GPL-3.0\n  [ag] AGPL-3.0\n  [mp] MPL-2.0\nChoice: "
			).strip()
			try:
				code_license = resolve_license(
					user_input, CODE_LICENSES, CODE_ALIASES, default=None
				)
				break
			except ValueError as e:
				print(f"Error: {e}. Please try again.")
	else:
		try:
			code_license = resolve_license(
				code_license, CODE_LICENSES, CODE_ALIASES, default=None
			)
		except ValueError as e:
			sys.exit(f"Invalid code license: {e}")

	if not docs_license:
		if non_interactive:
			docs_license = "CC-BY-4.0"
		else:
			user_input = input(
				"Docs license?\n  [cb] CC-BY-4.0\n  [cs] CC-BY-SA-4.0\n  [n] none\nChoice [cb]: "
			).strip()
			try:
				docs_license = resolve_license(
					user_input, DOCS_LICENSES, DOCS_ALIASES, default="CC-BY-4.0"
				)
			except ValueError as e:
				sys.exit(f"Invalid docs license: {e}")
	else:
		try:
			docs_license = resolve_license(
				docs_license, DOCS_LICENSES, DOCS_ALIASES, default=None
			)
		except ValueError as e:
			sys.exit(f"Invalid docs license: {e}")

	return code_license, docs_license


def confirm_plan(project_type: str, code_license: str, docs_license: str, stage: bool, commit: bool, dry_run: bool, skip_confirm: bool, non_interactive: bool) -> None:
	"""Print summary and prompt for confirmation."""
	if not skip_confirm and not non_interactive:
		mode = "DRY-RUN" if dry_run else "LIVE"
		print("")
		print("Summary:")
		print(f"  type:         {project_type}")
		print(f"  code license: {code_license}")
		print(f"  docs license: {docs_license}")
		print(f"  stage:        {'yes' if stage else 'no'}")
		print(f"  commit:       {'yes' if commit else 'no'}")
		print(f"  mode:         {mode}")
		confirm_input = input("Proceed? [y/N]: ").strip()
		if not confirm_input or confirm_input.lower() != "y":
			sys.exit("Aborted")


def main() -> None:
	args = parse_args()
	repo_root = get_repo_root()

	# === phase: arg validation ===
	if args.non_interactive:
		if not args.project_type or not args.code_license or not args.docs_license:
			sys.exit("--non-interactive requires --type, --code-license, and --docs-license")
		if not args.skip_confirm:
			sys.exit("--non-interactive requires --yes")

	if args.commit and args.no_stage:
		sys.exit("--commit and --no-stage conflict")

	# === phase: config resolution ===
	project_type = resolve_project_type(repo_root, args.project_type, args.force, args.non_interactive)
	code_license, docs_license = resolve_licenses(args.code_license, args.docs_license, args.non_interactive)
	preflight_check(repo_root, code_license, docs_license)

	# === phase: summary and confirmation ===
	stage = not args.no_stage
	confirm_plan(project_type, code_license, docs_license, stage, args.commit, args.dry_run, args.skip_confirm, args.non_interactive)

	action_count = 0

	# === phase: marker write ===
	action_count += write_marker(repo_root, project_type, args.dry_run)

	# === phase: license install ===
	code_source = os.path.join(repo_root, f"LICENSES/LICENSE.{code_license}.md")
	action_count += copy_and_verify_license(repo_root, code_source, f"LICENSE.{code_license}.md", code_license, args.dry_run)

	if docs_license != "none":
		docs_source = os.path.join(repo_root, f"LICENSES/LICENSE.{docs_license}.md")
		action_count += copy_and_verify_license(repo_root, docs_source, f"LICENSE.{docs_license}.md", docs_license, args.dry_run)

	# === phase: cleanup LICENSES/ ===
	action_count += git_rm_recursive("LICENSES/", args.dry_run)

	# === phase: propagate (direct repolib call) ===
	action_count += run_propagate(repo_root, args.dry_run)

	# === phase: scaffold sentinel check ===
	# After propagation completes (live only), assert that the required per-type
	# scaffold path exists. Guards against "successful but empty" propagation.
	if not args.dry_run:
		verify_scaffold_sentinel(repo_root, project_type)

	# === phase: typescript-specific work ===
	# Must run AFTER propagate so the noexist bucket has placed package.json at repo root.
	if project_type == "typescript":
		action_count += substitute_typescript_package_json(repo_root, args.dry_run)

	# === phase: truncate boilerplate ===
	action_count += truncate_file("README.md", repo_root, args.dry_run)
	action_count += truncate_file("docs/CHANGELOG.md", repo_root, args.dry_run)

	# === phase: remove templates/ ===
	# templates/ must be removed AFTER propagation has read from it and AFTER
	# gitignore merge completes. Untracked or absent templates/ is not an error
	# (supports partially repaired clones).
	templates_dir = os.path.join(repo_root, "templates")
	if args.dry_run:
		if os.path.isdir(templates_dir):
			dry_run_print("git rm -r templates/", args.dry_run)
			action_count += 1
		else:
			dry_run_print("templates/ absent -- skip removal", args.dry_run)
	else:
		ls_templates = subprocess.run(
			["git", "ls-files", "templates/"],
			check=True, capture_output=True, text=True, cwd=repo_root,
		)
		if ls_templates.stdout.strip():
			# templates/ has tracked files; remove them via git rm -r
			action_count += git_rm_recursive("templates/", args.dry_run)
		elif os.path.isdir(templates_dir):
			# untracked templates/ directory present; log and skip (no git state to touch)
			print("templates/ is untracked -- skipping git rm (directory left on disk)")
		else:
			# completely absent; nothing to do
			print("templates/ absent -- nothing to remove")

	# === phase: git rm cleanup ===
	# Remove the template-only propagation infrastructure from the consumer:
	# entry script and the repolib package (renamed from propagate/ in the template).
	action_count += git_rm("propagate_style_guides.py", args.dry_run)
	action_count += git_rm_recursive("repolib/", args.dry_run)
	# Remove the template's own tracked root tools/ (e.g. tools/detect_repo_type.py).
	# `git rm -r tools/` removes tracked entries only; freshly propagated untracked
	# files (e.g. tools/sync_typescript_package_pins.py for typescript consumers)
	# survive and stay on disk. Guard on tracked content so the case where tools/
	# holds only untracked propagated files (no tracked entry) is logged and skipped
	# instead of failing on a no-match pathspec, mirroring the templates/ handling.
	if args.dry_run:
		dry_run_print("git rm -r tools/", args.dry_run)
		action_count += 1
	else:
		ls_tools = subprocess.run(
			["git", "ls-files", "tools/"],
			check=True, capture_output=True, text=True, cwd=repo_root,
		)
		if ls_tools.stdout.strip():
			action_count += git_rm_recursive("tools/", args.dry_run)
		else:
			print("tools/ has no tracked files -- skipping git rm (any propagated files left on disk)")
	# Strip every directory named "meta/" anywhere in the tree (template-only
	# trees: top-level meta/, tests/meta/, any future subtree/meta/). Walk the
	# git index so only tracked dirs are touched; pick the shallowest "meta"
	# in each path so a nested case like a/meta/sub/meta/ collapses to a/meta/
	# and `git rm -r` is not asked to remove the same subtree twice.
	ls_result = subprocess.run(
		["git", "ls-files"], check=True, capture_output=True, text=True
	)
	tracked = ls_result.stdout.splitlines()
	meta_dirs: list[str] = []
	seen = set()
	for tracked_path in tracked:
		parts = tracked_path.split("/")
		for idx, part in enumerate(parts):
			if part == "meta":
				meta_dir = "/".join(parts[: idx + 1]) + "/"
				if meta_dir not in seen:
					seen.add(meta_dir)
					meta_dirs.append(meta_dir)
				break
	# Drop entries whose ancestor is already in the set (sibling dirs like
	# meta/ and tests/meta/ are not ancestor-nested and both survive).
	meta_dirs.sort(key=len)
	pruned: list[str] = []
	for candidate in meta_dirs:
		covered = any(candidate.startswith(ancestor) and candidate != ancestor for ancestor in pruned)
		if not covered:
			pruned.append(candidate)
	for meta_dir in pruned:
		action_count += git_rm_recursive(meta_dir, args.dry_run)

	if project_type != "python":
		action_count += git_rm("devel/submit_to_pypi.py", args.dry_run)

	action_count += git_rm("reset_repo.py", args.dry_run)

	# === phase: end-state verification ===
	# Verify no template-owned paths remain (git index + disk). In dry-run, logs
	# the check that would happen. In live mode, raises on any leftover.
	action_count += verify_clean_end_state(repo_root, args.dry_run)

	# === phase: stage changes ===
	if not args.no_stage:
		action_count += 1
		if args.dry_run:
			dry_run_print("git add -A", args.dry_run)
		else:
			subprocess.run(["git", "add", "-A"], check=True, capture_output=True)

	# === phase: commit ===
	if args.commit:
		action_count += 1
		commit_msg = f"initial commit: reset repo to base template ({project_type})"
		if args.dry_run:
			dry_run_print(f"git commit -m {repr(commit_msg)}", args.dry_run)
		else:
			subprocess.run(
				["git", "commit", "-m", commit_msg], check=True, capture_output=True
			)

	# === phase: summary print ===
	if args.dry_run:
		print(f"DRY-RUN: {action_count} actions planned. No files changed.")
	else:
		if args.commit:
			print("Committed.")
		elif args.no_stage:
			print("Working tree modified. Run 'git add -A && git commit' when ready.")
		else:
			print("Staged. Run 'git commit' when ready.")

		subprocess.run(["git", "status", "--short"], check=False)

	if project_type == "python":
		print("\nNext steps:")
		print("  pip install -r pip_requirements.txt && pip install -r pip_requirements-dev.txt")
	elif project_type == "typescript":
		print("\nNext steps:")
		print("  npm install && bash devel/setup_playwright.sh")
	elif project_type == "rust":
		print("\nNext steps:")
		print("  cargo build")


if __name__ == "__main__":
	main()
