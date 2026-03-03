# lauschi Userbrain Tests

5 focused usability tests for the lauschi kids audio player.
Each test covers one user journey, 8-10 minutes.

## Screening (all tests)

### Screening questions

1. **Hast du ein Android-Handy oder -Tablet?**
   - Ja → weiter
   - Nein → raus

2. **Sprichst du Deutsch?**
   - Ja → weiter
   - Nein → raus

3. **Hast du Kinder im Alter von 3-10 Jahren?**
   - Ja → weiter
   - Nein → raus (nice to have, not hard filter if pool too small)

### Tester demographics
- **Device**: Android
- **Language**: German
- **Location**: DACH preferred
- **Age**: 25-45

### Install
Provide APK or Play Store beta link. Testers install before starting.

---

## Test 1: Erster Eindruck und Einrichtung

**Duration**: 10 minutes
**Goal**: First impression, onboarding clarity, PIN setup

### Intro
```
Jemand hat dir diese App empfohlen. Du hast sie gerade
installiert und öffnest sie zum ersten Mal.

Denk laut mit, sag alles, was dir auffällt oder durch den Kopf geht.
```

### Task 1: App öffnen und erkunden
```
Öffne die App.

Schau dich auf dem ersten Bildschirm um, ohne etwas zu tippen.
Was glaubst du, was diese App macht? Für wen ist sie gedacht?
```

### Task 2: Einrichtung durchführen
```
Richte die App so ein, dass du sie benutzen kannst.
```

### Task 3: Schutz einrichten
```
Die App hat einen Bereich, der nur für Erwachsene gedacht ist.
Finde ihn und richte ihn ein.
```

### Abschlussfrage (offen)
```
Was war dein erster Eindruck? Erzähl kurz,
was dir aufgefallen ist und was dich verwirrt hat.
```

---

## Test 2: Inhalte für dein Kind zusammenstellen

**Duration**: 10 minutes
**Goal**: Can parents find and add content without hand-holding?

### Intro
```
Stell dir vor, die App ist frisch eingerichtet. Dein Kind
(5 Jahre) hört gerne Geschichten und Hörspiele. Der Bildschirm
ist noch leer: es gibt noch keine Inhalte.

Finde heraus, wie du Inhalte für dein Kind bereitstellen kannst.

Denk laut mit.
```

### Task 1: Inhalte finden und hinzufügen
```
Finde einen Weg, Inhalte für dein Kind bereitzustellen.
Such dir etwas aus, das deinem Kind gefallen könnte.
```

### Task 2: Ergebnis überprüfen
```
Überprüfe, ob die Inhalte, die du gerade ausgewählt hast,
jetzt für dein Kind sichtbar sind.
```

### Task 3: Noch etwas hinzufügen
```
Füge noch eine weitere Serie hinzu. Diesmal etwas
für ein anderes Alter oder Interesse.
```

### Abschlussfrage (offen)
```
Hast du etwas vermisst? Gab es Hörspiele oder Sendungen,
die du erwartet hättest, aber nicht gefunden hast?
```

---

## Test 3: Dein Kind benutzt die App

**Duration**: 8 minutes
**Goal**: Is the kid-facing UI intuitive enough for a child?

### Intro
```
Stell dir vor, du gibst deinem Kind (5 Jahre alt, kann noch
nicht lesen) dein Handy mit dieser App.

Auf dem Bildschirm sind bereits ein paar Bildkarten zu sehen.
Tu so, als wärst du das Kind: Tippe einfach drauflos und schau,
was passiert.

Denk laut mit. Was würde ein Kind hier tun? Was könnte verwirrend sein?
```

### Task 1: Etwas zum Anhören starten
```
Starte etwas zum Anhören. Tippe auf das, was dich anspricht.
```

### Task 2: Etwas anderes auswählen
```
Du möchtest jetzt etwas anderes hören. Finde einen Weg,
zu den anderen Bildern zurückzukommen und etwas Neues zu starten.
```

### Task 3: Den geschützten Bereich finden
```
Stell dir vor, du bist wieder der Erwachsene.
Finde den Bereich, der vor Kinderhänden geschützt ist.
```

### Abschlussfrage (offen)
```
Was war einfach, was war schwierig?
Wo wäre ein Kind ohne Hilfe nicht weitergekommen?
```

---

## Test 4: Wiedergabe und Steuerung

**Duration**: 8 minutes
**Goal**: Is playback intuitive? Can kids and parents control what's playing?

### Intro
```
Auf dem Bildschirm sind ein paar Hörspiele für dein Kind
vorbereitet. Du möchtest jetzt zusammen mit deinem Kind
etwas anhören.

Denk laut mit.
```

### Task 1: Hörspiel abspielen
```
Wähle ein Hörspiel aus und starte die Wiedergabe.
Schau dich um: Was zeigt dir die App, während etwas abgespielt wird?
```

### Task 2: Steuerung benutzen
```
Pausiere die Wiedergabe.

Starte sie danach wieder.

Versuche, eine Stelle zu überspringen oder
zum nächsten Teil zu wechseln.
```

### Task 3: Zurück zur Übersicht
```
Geh zurück zur Übersicht mit allen Bildern.
Fällt dir auf, dass noch etwas abgespielt wird?
```

### Abschlussfrage (offen)
```
Was ist dir beim Bedienen aufgefallen?
Gab es etwas, das du gesucht hast?
```

---

## Test 5: Inhalte verwalten und anpassen

**Duration**: 8 minutes
**Goal**: Can parents customize what their kid sees?

### Intro
```
Dein Kind benutzt die App jetzt seit ein paar Wochen.
Es gibt mehrere Serien auf dem Bildschirm. Manche davon
interessieren dein Kind nicht mehr, bei anderen fehlt ein Bild.

Du möchtest aufräumen und die Ansicht anpassen.

Denk laut mit.
```

### Task 1: Reihenfolge ändern
```
Bringe die Lieblingsserie deines Kindes an die erste Stelle.
```

### Task 2: Aussehen anpassen
```
Eine der Serien hat kein richtiges Bild. Finde heraus,
ob du das ändern kannst.
```

### Task 3: Etwas entfernen
```
Entferne eine Serie, die dein Kind nicht mehr hört.
```

### Abschlussfrage (offen)
```
Beschreibe kurz, wie viel Einfluss du als Elternteil
auf das hast, was dein Kind in der App sieht und hört.
Was hat dir beim Verwalten gefehlt?
```

---

## Design decisions (not shown to testers)

### What we learned from tuneloop Userbrain rounds

1. **German content = German testers**: All task descriptions in German,
   screening confirms language.

2. **Pre-populated content for kid tests**: Tests 3, 4, and 5 need tiles
   already set up. Either provide an APK with pre-loaded DB, or add a
   setup step ("go to the parent area, add 3-4 series") as a warm-up
   before the actual test.

### Userbrain best practices applied

- **No interface words in tasks**: "Finde einen Weg, Inhalte bereitzustellen"
  instead of "Tippe auf Hörspiel hinzufügen". We want to see if testers
  find the UI elements on their own.

- **Context-first scenarios**: Each test starts with a realistic situation
  (child who likes stories, app just installed, etc.) instead of
  mechanical instructions.

- **No rating scales**: Open-ended questions only. We observe behavior,
  not collect opinions. The video recordings show us where people struggle.

- **No future questions**: "Was war dein erster Eindruck?" instead of
  "Würdest du die App nutzen?" Past/present behavior over hypothetical
  futures.

- **Don't reveal the app's purpose**: Test 1 starts with "Was glaubst du,
  was diese App macht?" before any explanation. First impressions are
  the most valuable data point.

- **Short, focused tests**: One journey per test (8-10 min) keeps tester
  attention and produces cleaner data than one 25-minute marathon.

- **Actionable tasks**: "Starte etwas zum Anhören" not "Wie würdest du
  ein Hörspiel abspielen?"

### Changes from previous version

This version reflects the ARD Audiothek-only launch (Spotify flagged off):

- **Screening**: Dropped Spotify account requirement. All content is free,
  no account needed.
- **Test 1**: Onboarding is now 2 steps (Welcome → PIN). No Spotify
  connection step. Intro no longer spoils the app's purpose before
  Task 1 asks "what does this app do?" (Userbrain Mistake #1).
- **Test 2**: Dropped "Musik statt Hörspiele" task — ARD Audiothek is
  all spoken-word content. Replaced with age/interest variation.
- **Test 3**: Closing question reworded to ask about observed difficulty
  instead of hypothetical future (Userbrain Mistake #4).
- **Test 4** (new): Replaces the old "free vs. paid" test (irrelevant
  when everything is free). Focuses on playback and controls — the core
  kid experience we haven't explicitly tested. "Folge" replaced with
  "Teil" to avoid UI word leak (Userbrain Mistake #3). Closing question
  observes behavior instead of asking for opinion (Userbrain Mistake #2).
- **Test 5**: Unchanged — tile management is provider-agnostic.
