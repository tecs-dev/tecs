# Contributing to Tecs

Thanks for your interest in contributing!

## Mandatory requirements

- `make test` must pass.
- Add tests for new features, bug fixes, or edge cases when reasonable.
- **Update `docs/` for any user-facing change.** A change a game can see is not
  done until its page says so. Prose is the one thing no test can check, so the
  only defence is the person making the change. `make docs-dev` serves the site
  with hot reload.
- **`make docs-check` must pass.** It holds the module list against
  `src/tecs/init.tl` in three listings at once, resolves every link and anchor,
  requires a `description:` on every page, and diffs each page's generated
  reference against a fresh render. Regenerate with
  `python3 docs/scripts/reference.py` rather than editing below the
  `@generated` marker.
- **Public docblocks carry `@param` and `@return`**, and they say what the
  signature cannot: units, coordinate spaces, what nil means, what happens at a
  boundary. A tag that restates the parameter's name is worse than none.
- `make check` and `make format-check` must pass.

## Code style

`make format` decides layout: indentation, line width, wrapping and alignment,
per language. Run it rather than matching by eye, and do not argue with it in
review.

What it cannot decide is in `STYLE.md`: naming, the file and module split,
early returns over deep nesting, and comments that say why rather than what.
Documentation comments start with `---`.
