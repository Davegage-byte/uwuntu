# Codex-Arbeitsregeln für Uwuntu

Diese Datei gilt für das gesamte Repository `Davegage-byte/uwuntu`.

## Grundprinzip

Codex wird bei diesem Projekt vor allem für größere, riskantere oder mehrere Dateien betreffende Änderungen eingesetzt. Kleine Änderungen können außerhalb von Codex direkt manuell oder als vollständige Ersatzdatei vorbereitet werden. Wenn Codex einen Auftrag erhält, soll es den Auftrag vollständig, vorsichtig und nachvollziehbar umsetzen und keine zusätzlichen, nicht angeforderten Änderungen vornehmen.

Vor einer Änderung bestimmt Codex zuerst den kleinstmöglichen relevanten Dateibereich. Unbeteiligte Dateien und Verzeichnisse werden nicht vorsorglich analysiert.

## Immer vom aktuellen Stand arbeiten

- Vor jeder Aufgabe den aktuellen Stand von `main` einlesen.
- Einen frischen Branch direkt vom aktuellen `main` erstellen.
- Keine alte Codex-Aufgabe oder einen veralteten Branch als Ausgangsbasis für eine neue Änderung verwenden.
- Wenn `main` sich seit Beginn der Aufgabe geändert hat, zuerst den aktuellen Stand berücksichtigen und Konflikte sauber auflösen.
- Bestehende funktionierende Änderungen nicht unbeabsichtigt zurückdrehen.

## Modulare Repository-Struktur

Die produktiven Hauptdateien liegen im Repository-Root und müssen exakt so heißen:

- `Ubuntu Autostart Manager.sh`
- `Uwuntu Image Manager.sh`

Diese Namen und ihre Root-Position dürfen nicht geändert werden, weil die Online-Updatefunktionen davon abhängen.

Die Runtime-Module des Ubuntu Autostart Managers liegen unter:

- `modules/ubuntu-autostart-manager/apps/`
- `modules/ubuntu-autostart-manager/helpers/`

Die Archive der beiden Manager liegen getrennt unter:

- `backups/ubuntu-autostart-manager/`
- `backups/uwuntu-image-manager/`

Seit `MANAGER_BUILD 2026090910` werden die Runtime-Apps als eigenständige Module gepflegt. Der Ubuntu Autostart Manager ist primär Installer, Updater, Abhängigkeitsmanager, Autostart-/Desktop-Integration und Orchestrator. Fachliche Änderungen an einer einzelnen App erfolgen deshalb grundsätzlich direkt in deren Modul.

Zuordnung der Runtime-Apps:

- Audio: `modules/ubuntu-autostart-manager/apps/audio-test.sh`
- Hardware Check: `modules/ubuntu-autostart-manager/apps/hardware-check.sh`
- Kamera: `modules/ubuntu-autostart-manager/apps/camera-test.sh`
- Touch: `modules/ubuntu-autostart-manager/apps/touch-test.sh`
- Display: `modules/ubuntu-autostart-manager/apps/display-test.sh`
- Network: `modules/ubuntu-autostart-manager/apps/network-check.sh`
- Wipe: `modules/ubuntu-autostart-manager/apps/wipe-auto-app.sh`
- Gemeinsam verwendete Helfer: `modules/ubuntu-autostart-manager/helpers/`

## Striktes Analyseverbot für `backups/**`

`backups/**` ist für Codex grundsätzlich ein **Archiv und keine Implementierungsquelle**. Historische Dateien unter `backups/**` dürfen nicht:

- gelesen, geöffnet, analysiert oder durchsucht werden;
- mit `grep`, `rg`, `find`, `git grep`, `sed`, `head`, `tail`, `cat` oder vergleichbaren Werkzeugen als Codequelle erfasst werden;
- für Implementierungsentscheidungen oder als Referenz für alten Code verwendet werden;
- gegen aktuelle Runtime-Dateien verglichen werden.

Repository-weite Suchbefehle dürfen `backups/**` nicht erfassen. Suchen erfolgen bevorzugt nur in den relevanten produktiven Pfaden oder schließen das Archiv ausdrücklich aus, beispielsweise mit:

```bash
rg SUCHMUSTER --glob '!backups/**'
```

## Pflicht-Backup nur für produktive Root-Hauptdateien

Bevor eine bestehende produktive Root-Hauptdatei verändert oder überschrieben wird, muss eine unveränderte 1:1-Kopie des aktuellen `main`-Stands angelegt werden.

Für `Ubuntu Autostart Manager.sh`:

`backups/ubuntu-autostart-manager/Ubuntu Autostart Manager_backup-YYYY-MM-DD-HH-MM.sh`

Für `Uwuntu Image Manager.sh`:

`backups/uwuntu-image-manager/Uwuntu Image Manager_backup-YYYY-MM-DD-HH-MM.sh`

Dabei gelten folgende Regeln:

- Immer die aktuelle Root-Hauptdatei ohne `backup` im Namen sichern.
- Niemals ein vorhandenes Backup als Ausgangsbasis verwenden.
- Vorhandene Backups niemals ändern, überschreiben oder löschen.
- Der Zeitstempel muss Jahr, Monat, Tag, Stunde und Minute enthalten.
- Bei einer komplett neuen Root-Hauptdatei ist kein vorheriges Backup erforderlich.
- Wenn beide Root-Hauptdateien geändert werden, jede separat sichern.
- Das neu erzeugte Backup nicht inhaltlich analysieren, durchsuchen oder per vollständigem Diff untersuchen.
- Ausschließlich seine technische Identität mit der unveränderten Ausgangsdatei über `cmp -s ORIGINAL BACKUP` oder den Vergleich beider SHA256-Prüfsummen feststellen.
- Das Backup nach erfolgreicher Identitätsprüfung bei der weiteren Analyse ignorieren.

Änderungen ausschließlich unter `modules/**` erzeugen **kein** zusätzliches Repository-Backup unter `backups/**`; Git stellt die Versionshistorie der Module bereit. Ein Backup ist nur bei Änderung einer der beiden produktiven Root-Hauptdateien Pflicht, außer der Benutzer verlangt ausdrücklich ein zusätzliches Backup.

## Gezielte Analyse mit kleinstem Kontext

Bei einer Änderung an einem einzelnen Modul liest und prüft Codex standardmäßig nur dieses Modul. Bei einer Änderung ausschließlich an `modules/ubuntu-autostart-manager/apps/audio-test.sh` werden daher ohne konkrete technische Abhängigkeit nicht zusätzlich `hardware-check.sh`, `camera-test.sh`, `touch-test.sh`, `display-test.sh`, `network-check.sh`, `wipe-auto-app.sh`, der Uwuntu Image Manager oder der vollständige Ubuntu Autostart Manager analysiert. Das gleiche Prinzip gilt für jedes andere Modul.

Weitere Dateien dürfen nur gezielt einbezogen werden, wenn eine tatsächliche technische Abhängigkeit besteht. Das gesamte Repository wird nicht vorsorglich analysiert.

Zum Schutz unbeteiligter Bereiche bevorzugt verwenden:

```bash
git status
git diff --stat
git diff --check
git diff -- <relevante Dateien>
```

Nicht zur Sicherheit komplette unbeteiligte Dateien erneut studieren. Vor Abschluss prüfen, dass nur die erwarteten Dateien verändert wurden.

## Root-Manager nur bei technischer Notwendigkeit einbeziehen

Bei einer rein fachlichen Änderung eines bestehenden Runtime-Moduls wird `Ubuntu Autostart Manager.sh` nicht vollständig analysiert. Der Root-Manager muss nur gezielt gelesen oder geändert werden, wenn die Änderung insbesondere einen dieser Bereiche betrifft:

- Modul-Mapping;
- Installations- oder Update-Logik;
- Dependencies;
- Desktop-Einträge oder Autostart;
- Kiosk-Orchestrierung;
- Versions-/Buildlogik des Managers;
- neue oder entfernte Module;
- gemeinsame Installationsarchitektur.

Wenn eine Modulversion erhöht werden muss und der Root-Manager sichtbare Versionsangaben dazu enthält, nur die konkret notwendigen Versionsstellen suchen und ändern. Daraus keinen vollständigen Manager-Review machen.

## Versionsregeln nach der Modularisierung

- Nur tatsächlich betroffene Komponenten-Versionen erhöhen.
- Keine fachlich unbeteiligten Komponenten-Versionen für einen Commit oder Test ändern.
- Build-/Versionsnummern monoton weiterführen und niemals zurücksetzen.
- `MANAGER_BUILD` nur erhöhen, wenn eine produktive Änderung am Ubuntu-Autostart-Manager-/Update-System dies erfordert.
- Reine Änderungen an `AGENTS.md`, `README` oder anderer Dokumentation ändern weder eine Produktversion noch `MANAGER_BUILD`.
- Bei einer reinen Runtime-Moduländerung die Version der betroffenen Komponente erhöhen.
- Den Root-Manager nur ändern, wenn dort tatsächlich notwendige Versions- oder Installationsinformationen angepasst werden müssen.
- Bei Änderungen am Ubuntu Autostart Manager die tatsächlich betroffenen sichtbaren und internen Versionsangaben auf Konsistenz prüfen.
- Beim Uwuntu Image Manager alle zusammengehörigen Versionsstellen konsistent halten.
- Nach jeder Änderung klar ausgeben, welche Komponenten-Versionen sich tatsächlich geändert haben.

### Runtime-Build

- Jede produktive Änderung unter `modules/ubuntu-autostart-manager/apps/**` oder `modules/ubuntu-autostart-manager/helpers/**` muss im selben Commit `modules/ubuntu-autostart-manager/manifest.json` mit einer erhöhten `runtime_build` enthalten.
- Reine Dokumentationsänderungen lösen keine Erhöhung der `runtime_build` aus.
- Eine Komponenten-Version im Manifest wird nur geändert, wenn genau diese fachliche Komponente versioniert wird.
- Eine reine Moduländerung erfordert grundsätzlich weder eine Änderung an `Ubuntu Autostart Manager.sh` noch eine Erhöhung von `MANAGER_BUILD`.

## Updatefunktion schützen

- Die Updatefunktion per `U` muss funktionsfähig bleiben.
- Für Online-Updates ist `Davegage-byte/uwuntu` die produktive Quelle.
- Raw-, GitHub-API-, Ref- und commitbasierte URLs bei relevanten Änderungen gemeinsam prüfen.
- Keine Pfade aus dem früheren Repository `Davegage-byte/voltune/uwuntu` wieder einführen, außer ein Auftrag verlangt ausdrücklich eine Migrations- oder Kompatibilitätsänderung.

## Änderungsumfang

- Nur angeforderte Änderungen durchführen.
- Keine kosmetischen Refactorings, Umbenennungen oder Aufräumarbeiten nebenbei, sofern sie nicht notwendig sind.
- Bestehende UI-, Tastatur-, Autostart- und Update-Verhaltensweisen unverändert lassen, wenn sie nicht Teil des Auftrags sind.
- Bei Unsicherheit die kleinste sichere Änderung wählen.

## Tests: Fast Path für ein einzelnes Runtime-Modul

Für eine kleine Änderung an genau einem Runtime-Modul sind mindestens erforderlich:

1. `bash -n` nur für das geänderte Shell-Modul;
2. bei Python-Heredocs nur die Heredocs dieses Moduls extrahieren und mit `compile()` syntaktisch prüfen;
3. `git diff --check`;
4. Versionsangaben der betroffenen Komponente prüfen;
5. prüfen, dass keine unbeabsichtigten Dateien geändert wurden.

Nicht standardmäßig alle Module mit `bash -n` prüfen, alle Python-Heredocs des Repositories extrahieren, beide Root-Manager analysieren oder Backups analysieren.

## Tests des Ubuntu Autostart Managers

Wenn `Ubuntu Autostart Manager.sh` selbst geändert wurde, sind mindestens erforderlich:

- `bash -n 'Ubuntu Autostart Manager.sh'`;
- gezielte Tests des geänderten Manager-Bereichs;
- technische Identitätsprüfung des neuen Pflicht-Backups ausschließlich per `cmp` oder SHA256;
- `git diff --check`.

Die Runtime-Module nur dann zusätzlich vollständig testen, wenn die Änderung deren Installation, Mapping, Download, Update, Start oder gemeinsamen Vertrag betrifft.

## Tests des Uwuntu Image Managers

Wenn ausschließlich `Uwuntu Image Manager.sh` geändert wurde, nur dessen relevante Tests durchführen. Nicht automatisch den Ubuntu Autostart Manager, dessen Runtime-Module oder dessen Archive analysieren. Das neue Image-Manager-Pflicht-Backup ebenfalls nur technisch per `cmp` oder SHA256 prüfen.

## Full Path nur bei Risikoänderungen

Eine vollständige Testmatrix über alle betroffenen Module ist bei Änderungen mit entsprechendem technischen Risiko Pflicht, insbesondere bei:

- Modularisierungsänderungen;
- Update- oder Installer-Architektur;
- gemeinsam verwendeten Helpern;
- Modul-Mappings;
- Multi-Komponenten-Änderungen;
- Kiosk-Startarchitektur;
- Migrationen;
- größeren Refactorings;
- Änderungen, die mehrere Runtime-Komponenten gemeinsam betreffen.

Es gilt: kleiner Modulfix → **Fast Path**, große Architekturänderung → **Full Path**. Codex begründet kurz, wenn eine zunächst kleine Änderung wegen tatsächlicher Abhängigkeiten vom Fast Path auf den Full Path eskaliert.

Wenn ein erforderlicher Test in der Laufzeitumgebung technisch nicht möglich ist, dies ausdrücklich nennen und nicht als bestanden darstellen.

## GitHub-Workflow

- Änderungen in einem frischen Branch auf Basis des aktuellen `main` vorbereiten.
- Für abgeschlossene größere Änderungen einen Pull Request gegen `main` erstellen.
- Keine alten Codex-Branches für neue Aufgaben wiederverwenden.
- Vor dem Abschluss die tatsächlich geänderten Dateien zusammenfassen.
- Den Arbeitsbaum nach Commit und Pull-Request-Erstellung sauber hinterlassen.

## Commits von AUTO und IMAGE trennen

Wenn `Ubuntu Autostart Manager.sh` und `Uwuntu Image Manager.sh` in derselben Aufgabe aus unabhängigen Gründen geändert werden, sind zwei getrennte Commits zu erstellen:

- Der **AUTO-Commit** enthält `Ubuntu Autostart Manager.sh`, dessen neues Pflicht-Backup und gegebenenfalls die zugehörigen Module.
- Der **IMAGE-Commit** enthält `Uwuntu Image Manager.sh`, dessen neues Pflicht-Backup und gegebenenfalls dessen spätere Module.

Beide Hauptmanager nicht in einem generischen Commit vermischen. Technisch untrennbare Änderungen sind im Extended Commit-Text ausdrücklich zu begründen.

## Commit-Sprache und Format

Alle Commit-Texte und Pull-Request-Beschreibungen auf Deutsch verfassen.

Kurze Commit-Texte nennen nur die tatsächlich geänderte Komponente beziehungsweise die tatsächlich geänderten Komponenten. Bei einem Versionswechsel wird die Änderung bevorzugt mit einem Pfeil dargestellt, zum Beispiel:

- `NC2.28→NC2.29 · LAN-Erkennung verbessert`
- `HC4.5.74→HC4.5.75 · Keyboard-Shortcuts abgesichert`
- `AU1.21→AU1.22 · Waveform geglättet`
- `CA1.20→CA1.21 · Webcam-Erkennung verbessert`
- `WA3.32→WA3.33 · SSD-Erkennung verbessert`

Sind mehrere Komponenten Teil derselben fachlich zusammengehörigen Änderung, werden nur deren Versionen genannt, zum Beispiel:

`NC2.28→NC2.29 · WA3.32→WA3.33 · Gemeinsame Laufwerkserkennung angepasst`

Unveränderte NC-/WA-/HC-/CA-/AU-/IM-/MB-Werte gehören nicht in Modul-Kurzcommits.

Für Helper- oder Kiosk-Änderungen ohne eigene Fachversion wird ein passender Bereich verwendet, zum Beispiel `KIOSK · Welcome-Sound entfernt` oder `UPDATE · Runtime-Prüfung korrigiert`. Dafür wird keine künstliche Komponenten-Version erhöht. Die notwendige Erhöhung der `runtime_build` wird im Extended Commit erwähnt, muss aber nicht im Kurztitel stehen.

Wenn der Root-Manager selbst geändert wird, enthält der Kurztitel den Wechsel von `MANAGER_BUILD` und den Marker `· AUTO ·`, zum Beispiel `MB2026090910→MB2026090911 · AUTO · Runtime-Manifest für Modulupdates`. Der Extended Commit darf dafür zusätzlich eine kompakte Gesamtübersicht aller aktuellen Uwuntu-Versionen und des Runtime Builds enthalten.

Der Extended Commit eines einzelnen Runtime-Moduls beginnt mit dessen neuer Version, zum Beispiel `Network Check v2.29`, und behandelt ausschließlich dieses Modul sowie die zwingend zugehörige Manifest-Metadatenänderung. Unveränderte Komponenten werden nicht aufgelistet.

Ein reiner Image-Manager-Commit verwendet den Marker `· IMAGE ·`, zum Beispiel `IM1.11→IM1.12 · IMAGE · Restore verbessert`, und enthält keine vollständige NC-/WA-/HC-/CA-/AU-Kette.

Wenn ausschließlich `AGENTS.md` oder andere Dokumentation geändert wird, ist keine Komponenten-Versionsübersicht erforderlich.

Der Extended Commit-Text beschreibt verständlich:

- was und warum geändert wurde;
- welche Dateien betroffen sind;
- welche Versions-/Buildnummern geändert wurden;
- ob Fast Path oder Full Path verwendet wurde;
- welche Tests durchgeführt wurden;
- ob bekannte Einschränkungen bestehen.

## Abschlussausgabe an den Benutzer

Nach einer Codex-Aufgabe kompakt ausgeben:

- analysierte relevante Dateien;
- tatsächlich geänderte Dateien;
- verwendeter Fast Path oder Full Path;
- angelegte Hauptdatei-Backups, falls vorhanden;
- tatsächlich geänderte Komponenten-Versionen;
- Testergebnisse;
- vollständiger kurzer Commit-Text;
- vollständiger Extended Commit-Text;
- Pull-Request-Link und Merge-Status.

Nicht seitenlang auflisten, welche historischen Backups nicht gelesen wurden.
