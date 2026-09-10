# Codex-Arbeitsregeln für Uwuntu

Diese Datei gilt für das gesamte Repository `Davegage-byte/uwuntu`.

## Grundprinzip

Codex wird bei diesem Projekt vor allem für größere, riskantere oder mehrere Dateien betreffende Änderungen eingesetzt. Kleine Änderungen können außerhalb von Codex direkt manuell oder als vollständige Ersatzdatei vorbereitet werden. Wenn Codex einen Auftrag erhält, soll es den Auftrag vollständig, vorsichtig und nachvollziehbar umsetzen und keine zusätzlichen, nicht angeforderten Änderungen vornehmen.

## Immer vom aktuellen Stand arbeiten

- Vor jeder Aufgabe den aktuellen Stand von `main` einlesen.
- Keine alte Codex-Aufgabe oder einen veralteten Branch als Ausgangsbasis für eine neue Änderung verwenden.
- Wenn `main` sich seit Beginn der Aufgabe geändert hat, zuerst den aktuellen Stand berücksichtigen und Konflikte sauber auflösen.
- Bestehende funktionierende Änderungen nicht unbeabsichtigt zurückdrehen.

## Produktive Hauptdateien

Die produktiven Hauptdateien liegen im Repository-Root und müssen exakt so heißen:

- `Ubuntu Autostart Manager.sh`
- `Uwuntu Image Manager.sh`

Diese Namen und ihre Root-Position dürfen nicht geändert werden, weil die Online-Updatefunktionen davon abhängen.

## Pflicht: Backup vor jeder Änderung einer bestehenden Hauptdatei

Bevor eine bestehende produktive Hauptdatei verändert oder überschrieben wird, muss zuerst eine unveränderte 1:1-Kopie des aktuellen `main`-Stands angelegt werden.

Für `Ubuntu Autostart Manager.sh`:

`backups/ubuntu-autostart-manager/Ubuntu Autostart Manager_backup-YYYY-MM-DD-HH-MM.sh`

Für `Uwuntu Image Manager.sh`:

`backups/uwuntu-image-manager/Uwuntu Image Manager_backup-YYYY-MM-DD-HH-MM.sh`

Regeln für Backups:

- Immer die aktuelle Hauptdatei ohne `backup` im Namen sichern.
- Niemals ein vorhandenes Backup als Ausgangsbasis für eine neue Änderung verwenden.
- Vorhandene Backups niemals ändern, überschreiben oder löschen.
- Der Zeitstempel muss Jahr, Monat, Tag, Stunde und Minute enthalten.
- Bei einer komplett neuen Datei ist kein vorheriges Backup erforderlich.
- Wenn mehrere Hauptdateien geändert werden, jede betroffene Hauptdatei separat sichern.

## Versionsregeln

- Nur tatsächlich betroffene Komponenten-Versionen erhöhen.
- Keine fachlich unbeteiligten Komponenten-Versionen nur für einen Commit oder Test ändern.
- Build-/Versionsnummern monoton weiterführen; niemals versehentlich zurücksetzen.
- Bei Änderungen am Ubuntu Autostart Manager alle sichtbaren und internen Versionsangaben auf Konsistenz prüfen.
- Beim Uwuntu Image Manager alle zusammengehörigen Versionsstellen konsistent halten.
- Nach jeder Änderung klar ausgeben, welche Komponenten-Versionen sich tatsächlich geändert haben.

## Updatefunktion schützen

- Die Updatefunktion per `U` muss funktionsfähig bleiben.
- Für Online-Updates ist `Davegage-byte/uwuntu` die produktive Quelle.
- Raw-, GitHub-API-, Ref- und commitbasierte URLs bei relevanten Änderungen gemeinsam prüfen.
- Keine Pfade aus dem früheren Repository `Davegage-byte/voltune/uwuntu` wieder einführen, außer ein Auftrag verlangt ausdrücklich eine Migrations- oder Kompatibilitätsänderung.

## Änderungsumfang

- Nur angeforderte Änderungen durchführen.
- Keine kosmetischen Refactorings, Umbenennungen oder Aufräumarbeiten nebenbei, sofern sie nicht notwendig sind.
- Bestehende UI-, Tastatur-, Autostart- und Update-Verhaltensweisen unverändert lassen, wenn sie nicht Teil des Auftrags sind.
- Bei Unsicherheit lieber die kleinste sichere Änderung wählen.

## Tests vor Abschluss

Abhängig von der geänderten Datei mindestens:

- `bash -n 'Ubuntu Autostart Manager.sh'`
- `bash -n 'Uwuntu Image Manager.sh'`
- Eingebettete Shell-/Python-Helfer soweit praktikabel extrahieren und syntaktisch prüfen.
- `git diff --check`
- Prüfen, dass die Backup-Datei byte-identisch mit dem jeweiligen Ausgangsstand ist.
- Prüfen, dass keine unerwünschten alten Update-URLs oder Versionswerte zurückgeblieben sind.
- Arbeitsbaum am Ende sauber hinterlassen.

Wenn ein Test in der Laufzeitumgebung technisch nicht möglich ist, das ausdrücklich nennen und nicht als bestanden darstellen.

## GitHub-Workflow

- Änderungen in einem frischen Branch auf Basis des aktuellen `main` vorbereiten.
- Für abgeschlossene größere Änderungen einen Pull Request gegen `main` erstellen.
- Keine alten Codex-Branches für neue Aufgaben wiederverwenden.
- Vor dem Abschluss die tatsächlich geänderten Dateien zusammenfassen.

## Commit-Sprache und Format

Alle Commit-Texte und Pull-Request-Beschreibungen auf Deutsch verfassen.

Der kurze Commit-Text enthält bei Änderungen im Uwuntu-Projekt weiterhin die kompakte Versionsübersicht aller Hauptkomponenten, nicht nur der geänderten Komponenten. Beispiel:

`NC2.28-WA3.32-HC4.5.71-CA1.20-AU1.20`

Falls relevant, zusätzlich Image-Manager-Version und Manager-Build angeben, z. B.:

`IM1.10 · MB2026090905`

Der Extended Commit-Text beschreibt verständlich:

- was geändert wurde,
- warum es geändert wurde,
- welche Dateien betroffen sind,
- welche Versions-/Buildnummern geändert wurden,
- welche Tests durchgeführt wurden,
- ob es bekannte Einschränkungen gibt.

## Abschlussausgabe an den Benutzer

Nach einer Codex-Aufgabe immer kompakt ausgeben:

- geänderte Dateien,
- angelegte Backups,
- tatsächlich geänderte Komponenten-Versionen,
- Testergebnisse,
- vollständiger kurzer Commit-Text,
- vollständiger Extended Commit-Text,
- Pull-Request-Status bzw. ob noch ein Merge erforderlich ist.
