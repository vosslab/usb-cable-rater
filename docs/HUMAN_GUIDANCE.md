# Human guidance log

Durable record of the human's requests and guidance for usb-cable-rater. Append
new guidance here as it arrives so the project does not drift across sessions.
Newest guidance goes at the bottom of the matching section.

## Product and use case

- usb-cable-rater is a live identifier, not a sorter. The user has a bin of 10+
  unlabeled USB-C cables and 3 ports; they plug cables one at a time, read the
  live per-plug line, and physically sort the cables themselves.
- Live WATCH mode is the primary mode. It runs until Ctrl+C. `--once` is a
  snapshot convenience.
- Watch-mode startup must print the current visible cables (same initial result
  as `--once`), then keep watching for later insert/remove changes. A cable
  already plugged in at launch must produce a line, not silence.
- The tool does not produce sorted, batched, or grouped output. Live output only.

## Backend correctness

- Above all else, the backend must work. Detection is the make-or-break outcome.
- whatcable works because it uses every avenue to detect cables. Port whatcable's
  proven backend; use AT MINIMUM every data source whatcable uses. whatcable is
  the floor, not the ceiling -- additional sources are allowed when evidence
  (fixture, probe, or behavior test) shows they improve detection.
- Stop reinventing the wheel. The implementation is in front of us in a tested
  project (whatcable). Port the code; do not expect a better way of doing things.
- Backend/frontend split: the backend is ported closely from whatcable; the
  frontend (output format, labels, debounce, poll cadence, JSON) is our own.
- A bare, non-e-marked, open-ended cable is electrically invisible to macOS. Rate
  those via a far-end USB3+ device (hub or dock joined with a female-female
  coupler) -- the connected-device speed check (milestone M5).

## Output and CLI

- Use calm, readable, title-case labels (Unknown, Potentially fast?). All caps is
  too shouty.
- Do not print verbose "thinking out loud" output. Give a clear result line.
- This is an advanced-user-friendly CLI, not a grandma-friendly GUI; printing
  more detail (for example rawCableVDO + productID) is fine.
- Color the speed value; keep the details in normal color (like Python's rich).
- Keep `--debug` as raw diagnostics, not a `--verbose` alias.
- Keep the flag set minimal: none, `--once`, `--json`, `--debug`, `--help`,
  `--version`. The defaults should be good.
- Drop the `--with-device-floor` idea and that term. Use "connected-device speed
  check" for the far-end-device workflow.
- build_debug.sh should echo the location of the compiled binary so the user can
  run it.

## Git and version control

- Git and GitHub belong to the human: commits, branches, pull requests, and all
  GitHub operations. Assume the human commits when the plan is finished.
- The only git the manager touches is `git mv` for history-preserving moves.
- Git inspection (git status, git diff, git ls-files) is outside manager scope.
- Coder subagents edit files only and run no git.
- Do not change the user's git config.

## Workflow and delegation

- The manager dispatches all file changes to subagents and runs no commands
  itself.
- Subagents run Swift only through repo bash scripts (for example
  `bash devel/verify.sh`, `bash build_debug.sh`).
- Plan milestones must complete with the manager and subagents alone, with no
  human-interaction gates. Use captured fixtures, synthetic transitions, injected
  snapshots, and subagent probes. Real-hardware testing by the user is optional
  extra confidence, outside the milestone path.
- Treat external LLM reviewer feedback as a source of questions and risks, not as
  truth. Do our own research.
- Decompose hard problems into atomic single-owner tasks. Be efficient with wall
  time by running independent tasks in parallel. Give each task a fresh subagent.
  Finish the obvious follow-on work.
- Document edits in docs/CHANGELOG.md.

## Prompting style

- Prioritize positive prompting. Phrase instructions as "Do X" or "Use Y", not
  "Do not do W". Small language models can flip negative instructions into
  positive actions. Even "leave git to the manager" is a negative prompt in
  disguise; prefer omitting the topic and stating only the action to take.

## Environment notes

- The macOS hard drive is case-insensitive (git core.ignorecase is true). Avoid
  case-only ignore rules that could wrongly match a tracked path.
- This is a Swift package; build and test through the repo bash scripts.
