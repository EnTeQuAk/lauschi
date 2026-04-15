---
name: release
description: Prepare and tag a new dev release. Updates changelog, whatsnew, runs tests, bumps version. Use when asked to "release", "tag a release", "new dev release", or "ship it".
---

Prepare and publish a new dev release of lauschi.

## Step-by-Step Process

### 1. Determine what changed

Find the baseline version and gather commits:

```bash
BASELINE=$(git describe --tags --abbrev=0)
echo "Baseline: $BASELINE"
git log "$BASELINE"..HEAD --oneline
```

Identify user-facing changes (features, fixes, UX improvements). Skip internal refactoring, test-only changes, documentation, and dependency updates unless they affect something visible.

### 2. Update CHANGELOG.md

Run `/update-changelog` to draft the new changelog entry, OR write it manually.

Rules:
- Add a new section at the top. NEVER remove or overwrite previous entries.
- Use calver: `## vYYYY.MM.INC (Monat YYYY)`
- German language, parent-facing, friendly tone.
- Bold headings are labels, not sentences (no trailing period).
- See existing entries in CHANGELOG.md for style reference.

### 3. Update whatsnew files

The `distribution/whatsnew/` directory contains Google Play "What's New" text. Files must be named `whatsnew-{locale}` (e.g. `whatsnew-de-DE`, `whatsnew-en-US`) — this is required by the `r0adkll/upload-google-play` action.

**Max 500 characters per file** (hard limit from Google Play).

Write a draft, then verify the size:

```bash
wc -c distribution/whatsnew/whatsnew-de-DE
```

Rules:
- Replace the entire file content (this is NOT append-only).
- Update both `whatsnew-de-DE` and `whatsnew-en-US`.
- Summarize the 2-4 most important user-facing changes.
- Same tone as CHANGELOG.md but condensed to one line per change.
- German for de-DE, English for en-US. No jargon, kid-aware.

### 4. STOP: Review with Chris

**Do not proceed past this step without explicit approval.**

Show Chris:
1. The CHANGELOG.md diff (new section only)
2. The full `distribution/whatsnew/de-DE` content
3. The character count

Ask: "Sieht das gut aus? Soll ich weiterfahren?" (or in whatever language the conversation is in).

Wait for Chris to approve or request changes. Iterate until approved.

### 5. Run tests

```bash
mise run check
```

This runs formatting, analysis (`--fatal-infos`), and all unit/widget tests. Do not proceed if anything fails.

### 6. Commit changelog and whatsnew

```bash
git add CHANGELOG.md distribution/whatsnew/
git commit -m "docs: changelog for vX.Y.Z"
```

Use the actual version number that bumpver will assign. Check with `bumpver update --dry` if unsure.

### 7. Tag and push the release

```bash
mise run tag-release
```

This runs `bumpver update` which:
- Bumps the version in `pubspec.yaml`
- Creates a commit ("release vX.Y.Z")
- Creates an annotated git tag
- Pushes the tag and commits to origin

### 8. Verify CI

Check that CI passes on the new commit:

```bash
gh run list --limit 3
```

The tag push triggers:
- **GitHub Actions** `android-release.yml`: APK to Firebase App Distribution
- **Codemagic** `ios-release`: IPA to TestFlight

Report the CI status to Chris.

## Notes

- This skill is for **dev releases** (tester builds via Firebase/TestFlight). Store releases use `gh release create` and have a separate workflow.
- If CI fails, diagnose and fix before retrying. Don't re-tag; push a fix commit and run `mise run tag-release` again (bumpver increments from the latest tag).
- The whatsnew file is critical: it's the first thing testers and eventually store users see. Take the review step seriously.
