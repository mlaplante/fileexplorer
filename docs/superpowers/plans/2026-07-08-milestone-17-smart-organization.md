# Milestone 17 — Smart Organization

**Goal:** Add higher-level organization tools that help users find, clean, and
reshape file collections.

## Scope

- Smart folders / saved searches combining name, content, type, tag, date, size,
  and path rules.
- Duplicate finder by name, size, hash, and later image similarity.
- Bulk metadata tools: tags, comments, dates, quarantine, and extensions.
- File activity timeline for recently created, modified, moved, trashed, and
  restored items.
- Rules/automation: folder rules that move, rename, tag, compress, or notify
  when matching files appear.

## Implementation Notes

- Smart folders should reuse `FilterState` where possible, then extend it with
  recursive and name/path/content predicates.
- Duplicate detection should stage work: cheap grouping first, hashes only for
  candidate groups.
- Automation must be opt-in per folder and visibly auditable.

## Test Focus

- Query serialization and matching.
- Duplicate grouping avoids unnecessary hashes.
- Bulk metadata planning handles mixed success.
- Rule matching is pure and deterministic.

