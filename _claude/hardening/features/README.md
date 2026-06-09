# Optional feature snippets

This directory ships with the hardening template and ends up at
`.claude/hardening/features/` in every consumer project. Each
`*.json` file describes one optional security layer that
`claude-sec configure` can merge into the project's
`.claude/settings.json`. Files are processed in alphabetical order
(the leading `NN-` prefix controls the order they're presented to
the user).

## File format

```json
{
  "title": "Short feature name shown in the prompt",
  "description": "One- or two-sentence explanation of what enabling adds.",
  "patch": { /* JSON fragment to merge into .claude/settings.json */ }
}
```

## Merge semantics

`claude-sec configure` recursively merges `patch` into the live
settings:

- **Objects** are deep-merged (keys in `patch` are added to the
  target; nested objects recurse).
- **Hook arrays** (`hooks.SessionStart`, `hooks.PreToolUse`, etc.)
  are **upserted by `matcher`** — if the target already has an
  entry with the same `matcher`, it is replaced; otherwise the new
  entry is appended.
- **Other arrays** are appended only if the new element is not
  already present (set-style merge).
- **Scalars** are replaced.

This makes `claude-sec configure` idempotent: running it again with
the same answers leaves `.claude/settings.json` unchanged.

## Adding a feature

1. Pick a leading number (`10`, `20`, `30`, …) for display order.
2. Drop a new `<NN>-<slug>.json` file in this directory.
3. Update the **Settings reference** section of root `README.md`
   to document what the feature adds.
