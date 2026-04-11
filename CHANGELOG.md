# Changelog

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
