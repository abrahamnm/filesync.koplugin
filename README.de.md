# FileSync - Kabelloser Dateimanager für KOReader

[English](README.md) | [Español](README.es.md) | [Português](README.pt_BR.md) | [中文](README.zh_CN.md) | [العربية](README.ar.md) | [Français](README.fr.md) | **Deutsch** | [Русский](README.ru.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

Ein KOReader-Plugin, das einen lokalen Webserver auf Ihrem E-Reader startet und einen QR-Code auf dem Bildschirm anzeigt. Scannen Sie den Code mit Ihrem Smartphone, um eine ansprechende Weboberfläche zur kabellosen Verwaltung Ihrer Bücher und Dateien zu öffnen — keine Kabel, keine Apps, nur Ihr Browser.

Funktioniert auf Geräten mit KOReader (entwickelt für **Kindle** und **Kobo**).

<p align="center">
  <img src="screenshots/qr-screen.png" alt="QR-Code-Anzeige auf dem E-Reader" width="500">
</p>
<p align="center">
  <img src="screenshots/web-home.png" alt="Weboberfläche - Startseite" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Weboberfläche - Verzeichnis" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Weboberfläche - Dateidetails" width="250">
</p>

## Funktionen

- **QR-Code-Zugang** — Scannen und sofort verbinden, ohne URLs einzugeben
- **Dateibrowser** — Navigieren Sie durch Ihre Bibliothek mit Breadcrumb-Navigation
- **Dateien hochladen** — Per Drag-and-Drop oder Antippen Bücher von Ihrem Smartphone hochladen
- **Dateien herunterladen** — Jede Datei mit einem Fingertipp auf Ihr Smartphone speichern
- **Ordner erstellen** — Organisieren Sie Ihre Bibliothek in Verzeichnissen
- **Umbenennen und Löschen** — Einfache Dateiverwaltung mit Bestätigungsdialogen
- **Suchen und Sortieren** — Nach Name filtern, nach Name/Größe/Datum/Typ sortieren
- **Dunkles und helles Design** — Automatisch erkannt oder manuell umschaltbar
- **Mehrere Ansichtsmodi** — Listen-, Raster- und Großrasteransicht
- **Mehrsprachige Unterstützung** — Verfügbar in 10 Sprachen (Englisch, Spanisch, Portugiesisch, Chinesisch, Arabisch, Französisch, Deutsch, Russisch, Japanisch, Koreanisch)
- **RTL-Layout-Unterstützung** — Vollständiges Rechts-nach-Links-Layout für Arabisch
- **Schlafsperre** — Hält das Gerät wach und die WiFi-Verbindung aktiv, solange der Server läuft
- **Sicherer Modus** — Zeigt nur Bücher und Bilder an, Systemdateien werden ausgeblendet
- **Responsive Oberfläche** — Für Smartphones gestaltet, funktioniert auf jedem Bildschirm

## So funktioniert es

1. Verbinden Sie Ihren E-Reader mit dem WiFi
2. Öffnen Sie das FileSync-Plugin über das Netzwerk-Menü in KOReader
3. Ein QR-Code erscheint auf dem Bildschirm des E-Readers
4. Scannen Sie ihn mit Ihrem Smartphone (im selben WiFi-Netzwerk)
5. Verwalten Sie Ihre Bücher über die Weboberfläche im Browser Ihres Smartphones

## Installation

### Voraussetzungen

- Ein Gerät mit installiertem [KOReader](https://github.com/koreader/koreader)
- E-Reader und Smartphone im selben WiFi-Netzwerk

### Option 1: Aus dem Release-Archiv (empfohlen)

1. Laden Sie die neueste `.zip`-Datei von der [Releases](../../releases)-Seite herunter
2. Entpacken Sie das Archiv
3. Kopieren Sie den Ordner `filesync.koplugin` in das KOReader-Plugin-Verzeichnis Ihres Geräts (siehe Pfade unten)
4. Starten Sie KOReader neu

### Option 2: Direktes Kopieren

1. Verbinden Sie Ihren E-Reader per USB mit Ihrem Computer

2. Suchen Sie das KOReader-Plugin-Verzeichnis:
   - **Kindle:** `/mnt/us/koreader/plugins/`
   - **Kobo:** `.adds/koreader/plugins/` (im Stammverzeichnis der SD-Karte)

3. Kopieren Sie den gesamten Ordner `filesync.koplugin` in das Plugin-Verzeichnis:
   ```
   plugins/
   ├── filesync.koplugin/
   │   ├── _meta.lua
   │   ├── main.lua
   │   └── filesync/
   │       ├── filesyncmanager.lua
   │       ├── httpserver.lua
   │       ├── fileops.lua
   │       ├── filesync_i18n.lua
   │       ├── json.lua
   │       ├── mobi.lua
   │       ├── utils.lua
   │       ├── static/
   │       │   └── index.html
   │       └── i18n/
   │           ├── en.po
   │           ├── es.po
   │           ├── pt_BR.po
   │           ├── zh_CN.po
   │           ├── ar.po
   │           ├── fr.po
   │           └── ...
   ├── other.koplugin/
   └── ...
   ```

4. Werfen Sie das Gerät sicher aus und starten Sie KOReader neu

### Installation überprüfen

Öffnen Sie nach dem Neustart von KOReader das obere Menü und navigieren Sie zu:

**Network → FileSync**

Wenn der Menüeintrag angezeigt wird, ist das Plugin korrekt installiert.

## Verwendung

### Server starten

0. Stellen Sie sicher, dass Ihr Gerät mit dem WiFi verbunden ist
1. Öffnen Sie das obere Menü von KOReader
2. Navigieren Sie zu **Network → FileSync**
3. Tippen Sie auf **Start file server**
4. Ein QR-Code erscheint auf dem Bildschirm mit der Verbindungs-URL

<p align="center">
  <img src="screenshots/menu.png" alt="FileSync-Menü in KOReader" width="350">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/qr-screen.png" alt="QR-Code-Anzeige" width="350">
</p>

### Verbindung vom Smartphone herstellen

1. Stellen Sie sicher, dass sich Ihr Smartphone im **selben WiFi-Netzwerk** wie der E-Reader befindet
2. Öffnen Sie die Kamera Ihres Smartphones und scannen Sie den QR-Code
3. Tippen Sie auf den Link, um die Weboberfläche in Ihrem Browser zu öffnen
4. Alternativ können Sie die unter dem QR-Code angezeigte URL manuell eingeben

### Dateien verwalten

Nach der Verbindung können Sie über die Weboberfläche:

- **Durchsuchen** — Tippen Sie auf Ordner, um durch Ihre Bibliothek zu navigieren. Verwenden Sie die Breadcrumb-Leiste oben, um zu einem übergeordneten Verzeichnis zurückzuspringen.
- **Hochladen** — Tippen Sie auf die Schaltfläche **Upload** in der Kopfzeile, wählen Sie dann Dateien aus oder ziehen Sie sie in den Ablagebereich. Mehrere Dateien können gleichzeitig hochgeladen werden.
- **Dateidetails** — Tippen Sie auf eine beliebige Datei, um die Detailansicht zu öffnen, in der Sie die Datei **herunterladen**, **umbenennen** oder **löschen** können.
- **Ordner erstellen** — Tippen Sie auf die Schaltfläche **Folder** in der Kopfzeile und geben Sie einen Namen ein.
- **Suchen** — Verwenden Sie die Suchleiste, um das aktuelle Verzeichnis nach Dateinamen zu filtern.
- **Sortieren** — Verwenden Sie das Dropdown-Menü, um nach Name, Datum, Größe oder Typ in auf- oder absteigender Reihenfolge zu sortieren.

<p align="center">
  <img src="screenshots/web-home.png" alt="Dateibrowser - Startseite" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Dateibrowser - Verzeichnis mit Upload" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Dateidetailansicht" width="250">
</p>

### Schlafsperre

Während der Dateiserver läuft, verhindert das Plugin automatisch, dass Ihr Gerät in den Ruhezustand oder Standby-Modus wechselt. Dadurch bleibt der Server erreichbar und die WiFi-Verbindung ohne Unterbrechung bestehen. Im Einzelnen:

- **Standby** und **Ruhezustand** werden blockiert, damit das Gerät aktiv bleibt
- Die Timer für **automatischen Ruhezustand** und **automatischen Standby** werden vorübergehend deaktiviert
- Die **WiFi-Verbindungserhaltung** wird aktiviert, um die Netzwerkverbindung aufrechtzuerhalten

Alle Einstellungen werden auf ihre vorherigen Werte zurückgesetzt, wenn der Server gestoppt wird. Falls das Gerät dennoch in den Ruhezustand wechselt (z. B. bei kritisch niedrigem Akkustand), wird der Server beim Aufwachen des Geräts automatisch neu gestartet.

### Server stoppen

- Tippen Sie im Plugin-Menü auf **Stop file server**, oder
- Der Server stoppt automatisch, wenn Sie KOReader beenden

### Port ändern

1. Öffnen Sie das Plugin-Menü
2. Tippen Sie auf **Server port**
3. Geben Sie eine Portnummer zwischen 1024 und 65535 ein (Standard: 8080)
4. Starten Sie den Server neu, damit die Änderung wirksam wird

### Sicherer Modus

Der sichere Modus ist **standardmäßig aktiviert** und beschränkt die Weboberfläche auf die Anzeige von Dateien, die für Ihre Lesebibliothek relevant sind. Wenn aktiviert:

- Es werden nur **E-Books** (EPUB, PDF, MOBI, AZW3, FB2, DJVU, CBZ usw.), **Dokumente** (TXT, DOC, RTF, HTML usw.) und **Bilder** (JPG, PNG, GIF, WebP) angezeigt
- Systemdateien, Konfigurationsdateien und andere nicht buchbezogene Dateien werden ausgeblendet
- KOReader-Metadatenverzeichnisse (`.sdr`-Ordner) werden ausgeblendet und beim Löschen eines Buches automatisch bereinigt

Um den sicheren Modus umzuschalten, öffnen Sie das Plugin-Menü und tippen Sie auf **Safe mode**. Durch Deaktivierung werden alle Dateien auf dem Gerät angezeigt.

## Fehlerbehebung

**Plugin erscheint nicht im Menü**
- Stellen Sie sicher, dass der Ordner exakt `filesync.koplugin` heißt (Groß-/Kleinschreibung beachten)
- Überprüfen Sie, ob sich `_meta.lua` und `main.lua` direkt im Ordner befinden (nicht in einem Unterordner)
- Starten Sie KOReader vollständig neu

**Fehler „WiFi is not enabled"**
- Verbinden Sie Ihren E-Reader mit einem WiFi-Netzwerk, bevor Sie den Server starten
- Einige Geräte erfordern, dass WiFi in den Netzwerkeinstellungen von KOReader explizit aktiviert wird

**Smartphone kann keine Verbindung herstellen**
- Überprüfen Sie, ob sich beide Geräte im selben WiFi-Netzwerk befinden
- Versuchen Sie, die URL manuell einzugeben, anstatt den QR-Code zu scannen
- Prüfen Sie, ob auf Ihrem Router die Client-Isolation aktiviert ist (verhindert, dass Geräte sich gegenseitig sehen)
- Auf Kindle: Das Plugin verwaltet die Firewall-Regeln automatisch, aber ein Neustart kann helfen, wenn die Regeln hängen

**Upload schlägt fehl**
- Überprüfen Sie den verfügbaren Speicherplatz auf dem Gerät
- Sehr große Dateien können ein Zeitlimit überschreiten — versuchen Sie, kleinere Pakete hochzuladen
- Stellen Sie sicher, dass das Zielverzeichnis beschreibbar ist
- Die maximale Upload-Größe beträgt 1 GB pro Datei

**Das Hochladen großer Dateien verlangsamt das Gerät**
- Das Hochladen von Dateien über 100 MB kann dazu führen, dass die Benutzeroberfläche des E-Readers während der Übertragung vorübergehend nicht reagiert. Dies ist normal — das Gerät hat eine begrenzte Rechenleistung. Die Oberfläche wird nach Abschluss des Uploads wiederhergestellt.

## Mitwirken

Beiträge sind willkommen!

1. Forken Sie das Repository
2. Erstellen Sie einen Feature-Branch
3. Nehmen Sie Ihre Änderungen vor
4. Führen Sie die Tests aus (siehe unten)
5. Testen Sie wenn möglich auf einem echten Gerät
6. Reichen Sie einen Pull Request ein

### Tests ausführen

Das Projekt verwendet [busted](https://lunarmodules.github.io/busted/) für Unit-Tests. Die Tests decken reine Logikfunktionen ab (JSON-Kodierung/-Dekodierung, Pfadvalidierung, Versionsanalyse usw.) und benötigen keine KOReader-Umgebung.

**busted installieren** (falls noch nicht installiert):

```bash
luarocks install busted
```

**Alle Tests ausführen:**

```bash
busted
```

Dies führt über 177 Tests in 5 Testdateien aus. Sie sollten eine Ausgabe wie diese sehen:

```
177 successes / 0 failures / 0 errors / 0 pending : 0.04 seconds
```

**Eine bestimmte Testdatei ausführen:**

```bash
busted spec/json_spec.lua
```

**Testdateien:**

| Datei | Abdeckung |
|-------|-----------|
| `spec/json_spec.lua` | JSON-Kodierung/-Dekodierung, Grenzfälle, Fehlerbehandlung |
| `spec/fileops_spec.lua` | Path-Traversal-Schutz, Dateinamenvalidierung, Größenformatierung, MIME-Typen |
| `spec/updater_spec.lua` | Versionsanalyse, Versionsvergleich, Changelog-Extraktion |
| `spec/utils_spec.lua` | Plugin-Verzeichnisauflösung, Shell-Escaping |
| `spec/httpserver_spec.lua` | URL-Dekodierung, Query-String-Analyse |

Bitte fügen Sie beim Hinzufügen neuer Funktionen entsprechende Tests für reine Logikfunktionen hinzu.

## Lizenz

Dieses Projekt steht unter der [AGPLv3](https://www.gnu.org/licenses/agpl-3.0.html)-Lizenz, in Übereinstimmung mit dem KOReader-Projekt.
