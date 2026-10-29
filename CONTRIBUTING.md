# Contributing to ShuttleSense

Team workflow for the 3-week build. Setup is in [docs/SETUP.md](docs/SETUP.md); what to work on is in [docs/PHASES.md](docs/PHASES.md).

## Picking up work

1. Every task in [PHASES.md](docs/PHASES.md) has an ID (e.g. `T2.3`). It also exists as a GitHub issue on the project board with the same ID in the title.
2. Assign yourself, move the card to **In progress**, and branch from the latest `main`.
3. If a task turns out bigger than a day, split it into sub-issues and tell the lead.

## Branches

```
<type>/<task-id>-<short-name>
```

Examples: `feat/T2.2-tracknet-wrapper`, `fix/T4.5-timeline-overflow`, `docs/T7.4-results-tables`.

`main` is protected: no direct pushes after Phase 0, at least one approving review, CI must pass.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/) with an optional scope:

```
feat(tracking): run TrackNetV3 on normalized frames
fix(app): stop timeline overflowing on 360 dp phones
test(court): cover homography with a synthetic court
docs: add results table for stroke classifier
```

| Type | Use for |
| --- | --- |
| `feat` | New behaviour |
| `fix` | Bug fix |
| `test` | Tests only |
| `docs` | Documentation only |
| `refactor` | Code change without behaviour change |
| `chore` | Tooling, deps, config |
| `ci` | GitHub Actions |

Scopes: `backend`, `api`, `tracking`, `pose`, `court`, `hits`, `strokes`, `feedback`, `analytics`, `referee`, `render`, `app`, `data`.

Keep commits small and focused; reference the task in the body (`Refs T2.2`).

## Pull requests

- Fill in the PR template (task ID, what changed, how it was tested, screenshots for UI on phone and laptop widths).
- Backend PRs: `ruff check . && ruff format --check . && pytest` pass locally.
- App PRs: `flutter analyze && flutter test` pass locally; check the screen at 360, 800 and 1280 dp wide.
- Changes to the clip record or API contract must update `schema.py`, the Dart models, [DATA_FORMAT.md](docs/DATA_FORMAT.md) / [API.md](docs/API.md) and tests in the same PR, and need the lead's approval.
- Squash-merge; the PR title becomes the commit message, so write it in Conventional Commit form.

## Code style

### Python (backend/)

- Formatting and linting by ruff (config in `backend/pyproject.toml`), line length 100.
- Type hints on public functions; stage entry points use the `run(record, ctx) -> record` signature.
- Import `torch`, `onnxruntime` and `rtmlib` inside functions, not at module top level, so CI and the API run without them.
- Thresholds and magic numbers go in `configs/pipeline.yaml`, not in code.
- Fixed seeds (`configs/stroke_cnn.yaml: seed`) for anything random.

### Dart (app/)

- `flutter_lints` rules, `dart format`.
- One feature per folder under `lib/features/`; widgets in `*_screen.dart` / `widgets/`, state in `*_controller.dart`.
- No network calls from widgets; go through repositories/providers.
- Use `Breakpoints` from `core/responsive/` instead of hard-coded widths.
- Colors from the theme (`Theme.of(context).colorScheme`, `PlayerColors`), never inline hex.

## Large files and data

Never commit videos, datasets or weights (`.gitignore` blocks the common extensions). Share them through the team Google Drive or the Hugging Face weights repo; see [docs/SETUP.md](docs/SETUP.md#5-weights).

## Definition of done

A task is done when:

1. Its "done when" criterion in PHASES.md is met.
2. Tests cover the logic that can be tested without a GPU.
3. Docs are updated if behaviour, config, schema or API changed.
4. It is merged to `main` with green CI, and the checkbox in PHASES.md is ticked in the same PR.
