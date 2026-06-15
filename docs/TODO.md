# TODO

Deferred work captured at closeout. These are backlog items without timelines.
Source: [active_plans/reports/closeout_2026-06-15.md](active_plans/reports/closeout_2026-06-15.md)
and the backend audit. None of these block normal use on M1 hardware.

## Cleanup

- Remove the legacy parallel renderer and its tests. The unused
  `renderCableText*` / `verboseDetail` / `labelText` / `styledLabel` path is
  superseded by the two-line port-led output; drop it and the tests that cover
  only that path.

## Portability

- Make `usbCPortType` dynamic for non-M1 SoCs. It is currently hardcoded for the
  tested M1; other Apple Silicon controllers may use a different port-controller
  class.

## Correctness

- Complete JSON control-character escaping over the full `U+0000` through
  `U+001F` range. The current escaping is partial.

## Debug-only labels

- Fix the debug `backendSource` mislabel: `flushReady` always reports
  `source=portPoll`.
- Fix the debug `endpoint` mislabel: it always reports `SOP'` (`sopPrime`).
- These affect only `--debug` diagnostics, not the routine output or `--json`.

## Docs

- Consider a `RELATED_PROJECTS` pointer to whatcable (added; see
  [RELATED_PROJECTS.md](RELATED_PROJECTS.md)).

## Known gaps (from backend audit, not yet addressed)

- Debounce-window silent drop.
- Location-based `portNumber` recovery.
- SOP'' headline fallback.
