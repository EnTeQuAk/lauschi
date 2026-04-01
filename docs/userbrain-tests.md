# lauschi Userbrain Tests

6 tests for the lauschi kids audio player. Each test is one Userbrain
"Mobile App" test with a Play Store link, a scenario, and 3-4 tasks.

Tests build on each other: testers keep the app installed between sessions
so content accumulates naturally.

## Screening (all tests)

1. **Hast du ein Android-Handy?** Ja / Nein (filter)
2. **Sprichst du fliessend Deutsch?** Ja / Nein (filter)
3. **Hast du Kinder im Alter von 3-10 Jahren?** Ja / Nein (filter)

---

## Test 1: Erster Eindruck

**Type**: Mobile App
**URL**: Play Store link
**Duration**: ~8 min

### Scenario

Jemand hat dir diese App empfohlen. Du hast sie gerade installiert
und öffnest sie zum ersten Mal. Denk laut mit.

### Tasks

**Task 1** (task completed)
Öffne die App und schau dich um, ohne etwas zu tippen. Was glaubst
du, was diese App macht?

**Task 2** (task completed)
Richte die App so ein, dass du sie benutzen kannst.

**Task 3** (task completed)
Die App hat einen geschützten Bereich für Erwachsene. Finde ihn.

**Task 4** (answer)
Was war dein erster Eindruck? Was hat dich verwirrt?

---

## Test 2: Inhalte zusammenstellen

**Type**: Mobile App
**URL**: Play Store link
**Prerequisite**: Test 1 abgeschlossen
**Duration**: ~10 min

### Scenario

Du hast die App eingerichtet. Der Bildschirm ist noch leer.
Dein Kind (5 Jahre) hört gerne Geschichten. Denk laut mit.

### Tasks

**Task 1** (task completed)
Finde einen Weg, etwas zum Anhören für dein Kind bereitzustellen.

**Task 2** (task completed)
Überprüfe, ob die Inhalte jetzt für dein Kind sichtbar sind.

**Task 3** (task completed)
Füge noch mindestens vier weitere Sendungen hinzu. Gerne ganz
verschiedene Sachen.

**Task 4** (answer)
Hast du etwas vermisst? Welche Sendungen hast du erwartet,
aber nicht gefunden?

---

## Test 3: Das Kind benutzt die App

**Type**: Mobile App
**URL**: Play Store link
**Prerequisite**: Test 2 abgeschlossen (Inhalte vorhanden)
**Duration**: ~8 min

### Scenario

Du gibst deinem Kind (5 Jahre, kann noch nicht lesen) dein Handy
mit dieser App. Tu so, als wärst du das Kind. Tippe einfach
drauflos. Denk laut mit.

### Tasks

**Task 1** (task completed)
Starte etwas zum Anhören.

**Task 2** (task completed)
Du willst etwas anderes hören. Finde einen Weg zurück und starte
etwas Neues.

**Task 3** (task completed)
Du bist wieder der Erwachsene. Finde den geschützten Bereich.

**Task 4** (answer)
Was war einfach, was schwierig? Wo bräuchte ein Kind Hilfe?

---

## Test 4: Wiedergabe und Steuerung

**Type**: Mobile App
**URL**: Play Store link
**Prerequisite**: Test 2 abgeschlossen (Inhalte vorhanden)
**Duration**: ~8 min

### Scenario

Du möchtest zusammen mit deinem Kind etwas anhören. Denk laut mit.

### Tasks

**Task 1** (task completed)
Starte ein Hörspiel. Was zeigt dir die App, während es läuft?

**Task 2** (task completed)
Pausiere die Wiedergabe. Starte sie wieder. Versuche, eine Stelle
zu überspringen oder zum nächsten Teil zu wechseln.

**Task 3** (task completed)
Geh zurück zur Übersicht. Fällt dir auf, dass noch etwas läuft?

**Task 4** (answer)
Was ist dir beim Bedienen aufgefallen? Was hast du gesucht?

---

## Test 5: Inhalte verwalten

**Type**: Mobile App
**URL**: Play Store link
**Prerequisite**: Test 2 abgeschlossen (Inhalte vorhanden)
**Duration**: ~8 min

### Scenario

Dein Kind benutzt die App seit ein paar Wochen. Manche Sendungen
interessieren es nicht mehr. Du willst aufräumen. Denk laut mit.

### Tasks

**Task 1** (task completed)
Bringe die Lieblingsserie deines Kindes an die erste Stelle.

**Task 2** (task completed)
Eine Sendung hat einen Namen, der dir nicht passt. Ändere ihn.

**Task 3** (task completed)
Entferne eine Sendung, die dein Kind nicht mehr hört.

**Task 4** (answer)
Wie viel Einfluss hast du auf das, was dein Kind sieht und hört?
Was hat dir gefehlt?

---

## Test 6: Kacheln gruppieren

**Type**: Mobile App
**URL**: Play Store link
**Prerequisite**: Mindestens 5 Sendungen auf dem Startbildschirm
**Duration**: ~10 min

### Scenario

Auf dem Startbildschirm deines Kindes liegen jetzt einige Kacheln.
Es wird unübersichtlich. Du willst Ordnung schaffen. Denk laut mit.

### Tasks

**Task 1** (task completed)
Sortiere die Kacheln in eine Reihenfolge, die für dein Kind
Sinn ergibt.

**Task 2** (task completed)
Manche Kacheln gehören zusammen. Versuche, zusammengehörige
Kacheln in einer Gruppe zusammenzufassen.

**Task 3** (task completed)
Wechsle in die Kinderansicht. Finde die Sendungen, die du gerade
gruppiert hast, und starte eine Folge.

**Task 4** (answer)
War das Sortieren und Gruppieren so, wie du es erwartet hättest?
Was hat dich überrascht?

---

## Design decisions (not shown to testers)

### Userbrain format

Each test maps to one Userbrain "Mobile App" test:
- **Scenario**: the context block at the top
- **Tasks**: individual entries, marked as "task completed" or "answer"
- **Answer tasks**: open-ended closing question, tester types a response

Tasks are kept to 1-2 sentences max. Context is in the scenario, not
repeated in each task. No interface words in tasks (no "tippe auf",
"klicke", "scrolle").

### Test sequencing

Tests build on each other. Test 1 installs and sets up. Test 2 adds
content. Tests 3-6 use that content.

If budget allows only a subset:
1. **Test 2** (add content): most critical, first real interaction
2. **Test 3** (kid uses app): core value prop
3. **Test 1** (first impression): onboarding clarity
4. **Test 6** (folders): discoverability of drag-to-nest
5. **Test 4** (playback): controls and feedback
6. **Test 5** (manage): power-user, least critical

Tests 1+2 run as a pair. Tests 3-5 each need Test 2 as prerequisite
but are independent of each other. Test 6 additionally requires 5+
shows on the home screen.

### Content accumulation

Test 2 Task 3 asks for "mindestens vier weitere Sendungen, gerne ganz
verschiedene Sachen." This builds the tile count to 5+ for later tests,
satisfying Test 6's prerequisite without a warm-up step.

### Key rules applied

- **No interface words**: "Finde einen Weg" not "Tippe auf den Button."
  Testers scan for exact words; avoiding them tests real discoverability.
- **Context in scenario, not tasks**: The scenario sets the situation once.
  Tasks are action-oriented. No re-explaining in every task.
- **Don't reveal purpose first**: Test 1 Task 1 asks "Was glaubst du,
  was diese App macht?" before any explanation.
- **Don't ask about future**: "Was hat dich verwirrt?" (past) not
  "Würdest du die App nutzen?" (hypothetical).
- **Don't ask about usability directly**: "Was war schwierig?" observes
  behavior, not "Ist die App benutzerfreundlich?" which gets polite lies.
- **Short tasks**: 1-2 sentences. The Userbrain templates (Mailchimp,
  Netflix, Shopify) all use concise tasks. Our previous version was
  too verbose.

### Version history

**v1 (March 2026)**: 5 tests, verified on device.
**v2 (late March 2026)**: Added Test 6 (folders). Restructured as
sequential journey. Removed expired content test (untestable). Rewrote
all tests to match Userbrain's actual task format (shorter, scenario
at top, task-completed/answer types).
