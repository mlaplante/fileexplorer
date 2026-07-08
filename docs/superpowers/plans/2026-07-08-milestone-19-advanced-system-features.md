# Milestone 19 — Advanced System Features

**Goal:** Add system-level tools for advanced users while preserving the app's
current direct, keyboard-driven workflow.

## Scope

- Permissions editor: owner/group, POSIX mode, ACL summary, locked flag,
  quarantine flag, and apply-to-enclosed-items.
- iCloud and cloud-file awareness: local/downloaded/evicted/conflict states,
  download, and remove-download commands.
- Advanced recursive diff: ignored patterns, checksum mode, text/image preview,
  and filtered sync.
- Richer drag/drop polish: operation badges, target previews, and conflict
  preview before drop.
- Accessibility pass: VoiceOver labels, keyboard-only context flows, focus
  restoration, and high-contrast checks.

## Implementation Notes

- Permissions and cloud state need conservative error handling and clear status
  messages; failures are often policy or provider controlled.
- Treat advanced diff as a reusable Core engine that compare/sync can consume.
- Accessibility fixes should be validated continuously as UI changes land.

## Test Focus

- Permission model parsing and command planning.
- Cloud-state parsing behind injectable resource-value readers.
- Diff engine fixtures for ignored paths and checksum modes.
- Keyboard focus and accessibility labels where automatable.

