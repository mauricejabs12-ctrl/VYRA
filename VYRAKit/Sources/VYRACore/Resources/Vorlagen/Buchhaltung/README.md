# VYRA Buchhaltungs-Starter

Entwicklungsbeispiel fuer ein lokales Journal in EUR mit Python 3.10 oder neuer.
Start: `python main.py`. Tests: `python -m unittest -v`.
Tkinter gehoert zur offiziellen Windows-Python-Installation; keine Zusatzpakete.

Die Datenbank entsteht erst beim Start in diesem Projektordner. Sie enthaelt
Belege, Centbetraege, Soll-/Habenzeilen und Stornos. Datenbanktransaktionen und
eindeutige Importschluessel verhindern Teilbuchungen und doppelte Imports.
Das Journal wird ueber die API abgeschlossen; Trigger unterbinden nachtraegliche
Aenderungen. Der Dateibesitzer kann SQLite technisch manipulieren. Dies ist
kein manipulationssicheres Archiv und keine Zertifizierung.

Vor echtem Einsatz fehlen unter anderem: Rechte/Rollen, mehrere Mandanten,
Steuerlogik, Belegarchiv, Periodenabschluss, gepruefte Wiederherstellungsablaeufe,
Mehrwaehrung und landesspezifische Freigabe. CSV vor Weiterverarbeitung pruefen.
Backups separat sicher aufbewahren. Fuer Aenderungen ZIP in VYRA importieren
oder im gleichen Chat den naechsten Programmierauftrag beschreiben.
