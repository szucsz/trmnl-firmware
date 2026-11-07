# Zectrix firmware and upstream conflict guidance

This fork tracks `usetrmnl/trmnl-firmware` while maintaining ZecTrix Note 4 and
Note 4C support. Keep upstream history intact: upstream commits must retain
their original commit IDs. Only Zectrix-specific commits may be rebased or
rewritten.

## Weekly sync behavior

The scheduled workflow first tries to rebase `zectrix` onto `upstream/main`.
If that succeeds and the Note 4C build passes, the workflow updates `zectrix`
with a lease-protected force push. If the rebase conflicts, automation leaves
`zectrix` untouched and creates a draft PR from a fallback branch. That branch
merges `upstream/main` while taking the upstream version for each conflicted
path. The PR body lists those paths and the original `zectrix` commit, so the
Zectrix side of those files can be restored and reconciled locally.

Do not mark that fallback PR ready or merge it until every listed conflict has
been reviewed. If a fallback PR is already open, do not replace its branch or
discard local resolution work. Resolve the existing PR first; the next weekly
run can then sync later upstream commits.

## Resolving a fallback PR

1. Read the PR body for the upstream SHA, pre-sync Zectrix SHA, and conflict
   paths. Fetch both the PR head and `upstream/main` before editing.
2. For every listed path, compare the upstream version in the PR with the
   pre-sync Zectrix version and the common base. Recover the latter with
   `git show <pre-sync-zectrix-sha>:<path>`; inspect the upstream version with
   `git show <upstream-sha>:<path>`. Do not blindly choose one whole side when
   both contain needed behavior.
3. Preserve Note 4/4C board isolation. In particular, GPIO17 must remain
   asserted across deep sleep; Note 4C uses the native four-color SSD2683
   profile. Keep upstream behavior unchanged for non-Zectrix boards.
4. Commit resolutions as new, focused Zectrix commits on the PR branch. Do not
   amend, squash, or recreate upstream commits. Keep the merge commit that
   records the upstream integration.
5. Build at least `pio run -e zectrix_note4c`. Also build
   `pio run -e zectrix_note4` when shared board, power, display, or driver code
   changed; run the relevant native tests for shared logic.
6. Put each resolution in the narrowest appropriate commit. For recurring
   conflicts, it is acceptable to refactor/rewrite only Zectrix-specific
   commits into smaller, hardware-scoped changes that minimize edits to common
   upstream files. Preserve the resulting behavior and document any necessary
   common-code hooks. Never rewrite commits already present in upstream.

## Release behavior

The weekly workflow checks the latest published stable upstream release
separately from `upstream/main`. A new release is built from that exact tag
with the non-merge Zectrix-specific commits replayed on top. The release tag
in this repository is `<upstream-tag>-zectrix4c` (for example,
`v1.8.20-zectrix4c`). Do not substitute `upstream/main` if replaying the
Zectrix changes onto the release tag conflicts or the Note 4C build fails; let
the workflow report the problem and resolve it explicitly.

When adding future Zectrix changes, keep them in clearly scoped commits on
`zectrix`; avoid merging upstream branches into it except for the documented
conflict fallback PR. This makes the patch series identifiable for both
weekly rebases and release-tag builds.
