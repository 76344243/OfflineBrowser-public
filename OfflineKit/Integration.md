# Offline Kit v1 integrieren

Dies ist der Vertrag dieser App, kein W3C-Standard. Fügen Sie im HTML-Head `<link rel="offline-kit" href="offline-kit.json">` ein. Erzeugen Sie die Datei mit `python3 generate_manifest.py /pfad/zur/öffentlichen/seite --revision VERSION`. Lesen Sie das Inventar vor Veröffentlichung durch. Das Werkzeug erfasst explizit erlaubte öffentliche Dateitypen und überspringt versteckte/private/Build-Verzeichnisse, PHP und bekannte geheime Konfigurationen; es ersetzt keine menschliche Prüfung einer fremden Website.

`revision` bei Änderungen erhöhen. `entry` und `offlineEntry` sind relative Einstiegdateien. Jede notwendige Datei gehört mit MIME-Typ, Bytegröße und SHA-256 ins Inventar. `offlineChecks` beschreibt CSS-Selektoren nach dem Öffnen einer gespeicherten Seite. Externe Ressourcen müssen zusätzlich in `allowedResourceOrigins` deklariert sein. Netzwerkpflichtige Funktionen, Worker, WebRTC und WebSockets sind kein Offline-Vertrag.

Auf einem passwortgeschützten Webserver bleibt das Kit im Zugangskonzept. Eine Allowlist muss genau `offline-kit.json` und die inventarisierten öffentlichen Ressourcen erlauben, keine privaten Konfigurationen. Die App führt keine automatische Passwortänderung und keine Umgehung von Anmeldungen aus. Eine Login-Seite ist kein erfolgreicher Medien-Download. Hier erfolgt kein Upload.
