---
name: update-changelog
description: Update CHANGELOG.md for lauschi with user-facing changes since the last release. German language, friendly tone, emoji headers.
---

Update the `CHANGELOG.md` for lauschi with changes between the last release and the current version (`main`) that haven't been incorporated yet.

## Step-by-Step Process

### 1. Determine baseline version

Find the most recent release version:
```bash
git describe --tags --abbrev=0
```

This gives you the baseline (e.g., `v2026.4.1`).

### 2. Gather commits since the last release

```bash
git log <baseline-version>..HEAD --oneline
```

Example:
```bash
git log v2026.4.1..HEAD --oneline
```

### 3. Read the existing CHANGELOG.md

Check if there's already an "Unreleased" or draft section at the top. If so, append to it. If not, create a new section.

### 4. Write the changelog entry

**Format:**
```markdown
## vYYYY.MM.INC (Monat YYYY)

🎯 **Hauptfeature-Titel**
Was ändert sich konkret für Eltern und Kinder? In 1-2 Sätzen erklären.

✨ **Weitere Verbesserungen**
- Punkt 1: Konkrete Verbesserung
- Punkt 2: Konkrete Verbesserung

🐛 **Behoben**
- Was war das Problem, jetzt funktioniert es wieder
```

## Writing Guidelines (Todoist-Inspired Style)

### Tone & Voice
- **Friendly and conversational** — like explaining to a parent over coffee
- **Active and present** — "Spotify funktioniert wieder" not "Spotify-Wiedergabe wurde repariert"
- **Concrete, not abstract** — specific examples over general statements
- **Empathetic** — acknowledge when something was frustrating before

### Language
- **German only** (lauschi is DACH-focused)
- **Parent-facing, not technical** — avoid jargon
- **Kid-aware** — remember the app is for children, descriptions should reflect that

### Content Guidelines

**DO include:**
- New features parents/kids will notice
- Bug fixes that affected daily use
- Performance improvements that feel faster
- Reliability improvements (fewer crashes, smoother playback)
- Privacy/security improvements (explained simply)
- Changes to content availability or catalog

**DON'T include:**
- Internal refactoring
- Dependency updates (unless they fix something visible)
- Minor UI tweaks that don't change workflow
- Test-only changes
- Documentation updates
- Code cleanup without user impact

### Emoji Conventions

| Emoji | Use for | Example |
|-------|---------|---------|
| 🎯 | Main feature of the release | 🎯 **Spotify funktioniert wieder** |
| ✨ | New features | ✨ **Musik für Kinder** |
| 🔧 | Bug fixes | 🔧 **Wiedergabe unterbrochen** |
| 🚫 | Feature removal (explain why) | 🚫 **Kein Auto-Play mehr** |
| ⏳ | Content/availability changes | ⏳ **Nicht verfügbare Inhalte** |
| 🗄️ | Data/storage changes | 🗄️ **Ablauf-Badges entfernt** |
| 🍏 | Apple Music specific | 🍏 **Apple Music** |
| 🎵 | Music/audio related | 🎵 **Musik für Kinder** |
| 📂 | Organization/folders | 📂 **Ordner per Drag & Drop** |
| 🔍 | Search improvements | 🔍 **Bessere Suche** |
| 🧹 | Cleanup | 🧹 **Aufgeräumt** |
| 🧪 | Testing infrastructure | 🧪 **Mehr Tests** |
| 🛠️ | Minor fixes | 🛠️ **Kleinigkeiten** |
| 🐛 | Bug fix section header | 🐛 **Behoben** |

### App Store Limits (Hard Constraints)

**Google Play (Android):**
- Changelog: 500 characters per release
- Full description: 4000 characters
- Short description: 80 characters

**App Store (iOS):**
- "What's New": 4000 characters (but shorter is better)
- Best practice: Keep under 300-400 characters for visibility

**For lauschi:**
- Keep each release section under 500 characters (Google Play limit)
- Focus on the 2-3 most important changes
- Use short, scannable lines
- Emoji headers help with visual parsing

### Good vs. Bad Examples

**Good (Todoist-style, concrete):**
```
🔧 **Spotify funktioniert wieder**
Ein Fehler hat verhindert, dass Spotify-Inhalte abgespielt 
werden konnten. Ist behoben, sollte jetzt wieder zuverlässig 
funktionieren.
```

**Bad (too vague, technical):**
```
🔧 **Spotify playback fixed**
Fixed null pointer exception in SpotifyWebViewBridge 
state handling during auth refresh.
```

**Good (explains user benefit):**
```
🚫 **Kein Auto-Play mehr**
Wenn eine Folge zu Ende ist, startet nicht mehr automatisch 
die nächste. Kinder gehen zurück und tippen selbst auf 
"Weiter". Bewusste Entscheidung: kein endloses Abspielen 
ohne aktives Zutun.
```

**Bad (just states what changed):**
```
🚫 **Removed auto-advance**
Disabled automatic playback of next episode. Added 
completion guard to PlayerNotifier.
```

**Good (concrete and kid-aware):**
```
⏳ **Nicht verfügbare Inhalte**
Wenn ein Inhalt nicht mehr abrufbar ist, wird die Kachel 
ausgegraut statt versteckt. Kinder sehen, dass die Folge 
noch da ist, aber gerade nicht geht. Beim Antippen erklärt 
der verwirrte Fuchs, was los ist.
```

### Version Format

Use calver: `vYYYY.MM.INC1`
- `YYYY` — year
- `MM` — month
- `INC1` — increment within month (starts at 1)

Month names in German:
- January → Januar
- February → Februar
- March → März
- April → April
- May → Mai
- June → Juni
- July → Juli
- August → August
- September → September
- October → Oktober
- November → November
- December → Dezember

### Structure

1. **Main feature** (🎯) — The headline change
2. **Other improvements** (✨ 🍏 📂 🔍 etc.) — Grouped by category
3. **Bug fixes** (🔧 🐛) — What was broken, now works
4. **Cleanup/minor** (🧹 🛠️) — Only if they affect users

Order by impact: Most noticeable changes first.

## Also update `distribution/whatsnew/de-DE`

This file is the Google Play "What's New" text. Update it alongside the changelog.

- Max 500 characters (verify with `wc -c distribution/whatsnew/de-DE`)
- Summarize the 3-4 most important user-facing changes
- Same tone as CHANGELOG.md but condensed to one line per change
- This file is NOT append-only; replace the content with the current release

## Notes

- Preserve existing changelog style and formatting
- Always ADD a new section; never overwrite or remove previous release entries
- Bold headings are labels, not sentences (no trailing period)
- When in doubt about significance: if a parent would mention it to another parent, include it
- If the CHANGELOG.md already has a draft section at the top, append to it
- Keep the tone warm and friendly — this is a kids app, after all
- Short is better than comprehensive — app store limits are real
