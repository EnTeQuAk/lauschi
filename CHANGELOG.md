# Changelog

## v2026.6.3 (Juni 2026)

🐛 **Weiter-Badge springt zuverlässig zur nächsten Folge**
Wenn eine Folge zu Ende gespielt wurde, hat der Weiter-Badge manchmal nicht zur nächsten Folge gewechselt. Ursache war, dass Spotify im Hintergrund automatisch Empfehlungen abspielt und die App das Ende des Albums nicht erkennen konnte. Jetzt werden nur noch Folgen desselben Albums berücksichtigt, und die Wiedergabeposition wird laufend interpoliert statt nur bei Statuswechseln abgefragt.

🔧 **Fortschrittsbalken springt nicht mehr beim Vorspulen**
Beim Loslassen des Wiedergabe-Schiebereglers sprang die Position kurz zurück, bevor sie zum gewählten Punkt gesprungen ist. Das ist behoben.

🛠️ **Unter der Haube**
- Der Fortschrittsbalken nutzt jetzt Flutters eingebauten AnimationController statt manueller Berechnung
- Zeitberechnung im Player ist jetzt unabhängig von der Systemuhr (NTP-Sprünge, Zeitumstellung)

## v2026.6.1 (Juni 2026)

🎯 **Ein Raster für alles**
"Kacheln verwalten" zeigt jetzt Ordner und einzelne Folgen in einem einzigen Raster. Ein Strich mit "N einzelne Folgen" trennt die beiden Bereiche. Folgen lassen sich per Drag & Drop in Ordner ziehen, oder aufeinander ziehen um einen neuen Ordner zu erzeugen. Antippen öffnet den Folgen-Editor. "Karten verwalten" gibt es nicht mehr; alles passiert jetzt an einem Ort.

✨ **Einzelne Folgen bearbeiten**
Jede einzelne Folge kann jetzt angetippt werden, um Titel oder Cover zu ändern, sie in einen anderen Ordner zu verschieben, oder zu löschen.

⏳ **Deutlich mehr Inhalte**
Der Katalog ist kräftig gewachsen: mehr Serien, mehr Unterserien (z.B. "Bibi und Tina BFF Talk", "TKKG Junior: Adventskalender", verschiedene Pumuckl-Reihen), und jede davon taucht im Katalog-Browser separat auf.

🍏 **Apple Music gleichauf mit Spotify**
Die allermeisten Serien sind jetzt auf beiden Anbietern verfügbar. Apple-Music-Nutzer sehen praktisch das gleiche Angebot. Ein paar wenige Serien (z.B. Detektivbüro LasseMaja, Liliane Susewind) gibt es nur auf Spotify, weil die Hörspiele dort nicht als Streaming verfügbar sind.

🔍 **Zuverlässigere Serien-Erkennung**
Im Katalog-Browser erkennt lauschi Alben jetzt an ihrer eindeutigen ID statt an Schlüsselwörtern im Titel. Das verhindert Fehlzuordnungen; zum Beispiel wurde Blaze fälschlicherweise als Encanto erkannt. Jede Serie wird mit anschließendem menschlichen Review geprüft, sodass Kompilationen, Karaoke-Versionen und falsch zugeordnete Alben zuverlässiger aussortiert werden.

✨ **Weiter-Badge zeigt den Weg**
Die "Weiter"-Markierung scrollt jetzt automatisch zur nächsten ungehörten Folge. Der Leuchteffekt atmet sanft statt statisch zu leuchten, und beim Wechsel zur nächsten Folge gibt es eine kurze Puls-Animation.

🛠️ **Kleinigkeiten**
- Drag & Drop zeigt jetzt einen Hinweis zwischen Ordnern und einzelnen Folgen
- Zieltreffer beim Verschieben ist präziser, besonders in gemischten Listen
- Sentry-Erklärung in den Einstellungen ist deutlicher formuliert
- GitHub-Button nennt sich jetzt "lauschi ist Open Source" mit Erklärung darunter
- Spotify erneuert abgelaufene Anmeldungen automatisch (bisher war nach 6 Monaten eine Neuanmeldung nötig)
- Apple Music zeigt Wiedergabefehler jetzt direkt in der App an, statt still zu scheitern

## v2026.4.6 (April 2026)

🎯 **Erst anschauen, dann hinzufügen**
Die "Hörspiel-Schätze" funktionieren jetzt wie der Rest der App: Antippen öffnet die Sendungsseite, wo man einzelne Folgen auswählen kann. Kein versehentliches Hinzufügen mehr.

✨ **Einheitliche Kachel-Darstellung**
Alle Übersichten (Kacheln verwalten, ARD Entdecken, Spotify/Apple Music Katalog) zeigen Titel und Folgenanzahl jetzt identisch an. Bei Ordnern steht "X Kacheln", bei einzelnen Kacheln "X Folgen".

🔧 **Folgen entfernen**
Bereits hinzugefügte Folgen können jetzt direkt aus der Sendungsansicht entfernt werden.

🛠️ **Kleinigkeiten**
- Vor/Zurück-Buttons sind ausgegraut, wenn es keine vorherige oder nächste Folge gibt
- Diverse Verbesserungen bei Überschriften und Untertiteln
- Android 15 Edge-to-Edge und Android 16 Großbild-Unterstützung

## v2026.4.5 (April 2026)

🛠️ **Release-Notizen im Play Store**
Die "Was ist neu"-Texte werden jetzt korrekt an Google Play übermittelt.

## v2026.4.4 (April 2026)

🚀 **Erster offener Beta-Test**
lauschi ist jetzt im Google Play Store als offene Beta verfügbar. Alle bisherigen Verbesserungen aus v2026.4.2 und v2026.4.3 sind dabei.

## v2026.4.3 (April 2026)

🎯 **"Weiter" zeigt jetzt immer die richtige Folge**
Jede Kachel verhält sich wie ein CD-Player: Es gibt immer nur eine aktive Folge. Wer eine andere Folge antippt, setzt die alte zurück. Wenn eine Folge zu Ende gehört wurde, beginnt die nächste von vorn. Kein Durcheinander mehr mit mehreren halb gehörten Folgen.

## v2026.4.2 (April 2026)

🎵 **Spotify-Alben enden jetzt zuverlässig**
Wenn das letzte Lied eines Spotify-Albums fertig war, hat die App das manchmal nicht mitbekommen. Jetzt erkennt lauschi das Ende auch dann, wenn Spotify im Hintergrund schon zum nächsten Titel springt.

🔒 **Mehr Privatsphäre**
NFC-Tag-Kennungen werden nicht mehr vollständig an die Fehlerüberwachung gesendet. Die PIN muss jetzt mindestens 4 Zeichen lang sein.

🐛 **Behoben**
- "Kacheln verwalten" war leer, wenn lose Folgen existierten.
- Die Anbieter-Hinweise in den Einstellungen zeigen jetzt alle aktiven Anbieter.
- Der Eltern-Bereich bleibt länger aktiv, wenn man darin navigiert.

🛠️ **Unter der Haube**
- Datenbank-Abfragen bei vielen Folgen sind schneller dank neuer Indexe.
- Bessere Fehlerüberwachung für alle Anbieter.

## v2026.3.47 (März 2026)

⏳ **Nicht verfügbare Inhalte**
Wenn ein Inhalt nicht mehr abrufbar ist, wird die Kachel ausgegraut statt versteckt. Kinder sehen, dass die Folge noch da ist, aber gerade nicht geht. Beim Antippen erklärt der verwirrte Fuchs, was los ist.

🗄️ **Ablauf-Badges entfernt**
Die "Noch X Tage" Anzeige war unzuverlässig (ARD-Sender verwenden das Feld unterschiedlich). Stattdessen erkennt die App jetzt zur Laufzeit, ob ein Inhalt wirklich weg ist.

🧹 **Aufgeräumt**
Nicht mehr benötigte Expiry-Widgets und toten Code entfernt.

## v2026.3.44 (März 2026)

🔧 **Spotify-Wiedergabe repariert**
Ein Fehler hat verhindert, dass Spotify-Inhalte abgespielt werden konnten. Ist behoben, sollte jetzt wieder zuverlässig funktionieren.

🚫 **Kein Auto-Play mehr**
Wenn eine Folge zu Ende ist, startet nicht mehr automatisch die nächste. Kinder gehen zurück und tippen selbst auf "Weiter". Bewusste Entscheidung: kein endloses Abspielen ohne aktives Zutun.

✨ **Weiter-Kachel leuchtet**
Die nächste ungehörte Folge hat jetzt einen dezenten Leuchteffekt, damit sie auch bei bunten Covers gut sichtbar ist.

🧪 **Mehr Tests**
45 Integrationstests auf echten Geräten, darunter neu: Onboarding, PIN-Eingabe, Inhalte hinzufügen, Ordner-Lebenszyklus.

## v2026.3.39 (März 2026)

🎵 **Musik für Kinder**
Neben Hörspielen gibts jetzt auch Kinderlieder! 13 Künstler sind schon dabei, darunter Stephen Janetzko, Detlev Jöcker, Reinhard Horn und viele mehr. Der neue "Musik" Tab im Katalog zeigt Alben und Playlists.

🍏 **Apple Music**
Apple Music funktioniert jetzt als vollwertiger Anbieter. Einloggen, Hörspiele und Musik durchsuchen, abspielen. Auf iOS nutzt lauschi den nativen MusicKit Player, auf Android läuft DRM-geschütztes Streaming über ExoPlayer.

📂 **Ordner per Drag & Drop**
Kacheln lassen sich jetzt wie auf dem Handy-Homescreen organisieren: einfach eine Kachel auf eine andere ziehen, schon entsteht ein Ordner. Der Ordner zeigt automatisch ein Mosaik aus den Covers der enthaltenen Kacheln. Zum Auflösen: Kachel auf "Auf Startseite" ziehen.

🗑️ **Kacheln löschen per Drag & Drop**
Beim Verschieben erscheint unten ein "Löschen" Bereich. Kachel drauf ziehen, fertig.

🔍 **Bessere Suche**
Suchergebnisse die zu einer bekannten Serie passen, erscheinen jetzt zuerst. Musik-Suche zeigt Alben und Playlists getrennt.

🛠️ **Kleinigkeiten**
- Fortschrittsanzeige beim Importieren von Folgen (vorher sprang der Balken von 0 auf fertig)
- Spotify erholt sich jetzt automatisch wenn die Verbindung unterbrochen wird
- Playlist-Kacheln zeigen die richtige Anzahl Titel
- Onboarding-Seite scrollt jetzt auf kleinen Bildschirmen
- Diverse Stabilitäts-Verbesserungen und Bugfixes
