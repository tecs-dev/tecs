# Contributing to Tecs

Thanks for your interest in contributing!

## Mandatory requirements

- `make test` must pass.
- Add tests for new features, bug fixes, or edge cases when reasonable.
- **Update `docs/` for any user-facing change.** A change a game can see is not
  done until its page says so. Prose is the one thing no test can check, so the
  only defence is the person making the change. `make docs-dev` serves the site
  with hot reload; `make docs-check` fails a page with no description.
- `make check` and `make format-check` must pass.

## Code style

`make format` decides layout: indentation, line width, wrapping and alignment,
per language. Run it rather than matching by eye, and do not argue with it in
review.

What it cannot decide is in `STYLE.md`: naming, the file and module split,
early returns over deep nesting, and comments that say why rather than what.
Documentation comments start with `---`.
