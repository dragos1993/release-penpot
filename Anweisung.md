# =============================================================================
# ANWEISUNG: Was braucht Penpot, um in einem Cluster zu laufen?
# =============================================================================
#
# Diese Datei ist reine Dokumentation (nur Kommentare) — Helm/Kubernetes
# liest sie nicht, sie ist kein Teil des Charts. Sie beantwortet auf Deutsch:
# welche Services braucht Penpot, welche Container-Images werden benutzt,
# und ob man diese Images auch in der OpenShift-Registry oder auf quay.io
# findet.
#
# -----------------------------------------------------------------------------
# 1) WELCHE SERVICES BRAUCHT PENPOT?
# -----------------------------------------------------------------------------
#
# Penpot selbst besteht aus 3 eigenen Diensten (Backend, Frontend, Exporter).
# Dazu kommen 3 weitere Dienste, die Penpot zwingend zum Laufen braucht:
#
#   1. PostgreSQL   -> die Datenbank. Speichert Benutzerkonten, Teams, und
#                      auch den Inhalt der Design-Dateien selbst (als JSON in
#                      Datenbank-Zeilen). PFLICHT.
#
#   2. Valkey        -> Redis-kompatibler Dienst. Wird für die
#                      Echtzeit-Zusammenarbeit gebraucht (mehrere Personen
#                      bearbeiten gleichzeitig dieselbe Datei über
#                      WebSockets) — auch mit nur EINER Backend-Kopie
#                      benötigt, nicht nur zum Skalieren. PFLICHT, auch wenn
#                      man es leicht übersieht.
#
#   3. MinIO         -> Objekt-Speicher (S3-kompatibel) für hochgeladene
#                      Bilder, Schriftarten und exportierte PDF/PNG/SVG-
#                      Dateien. Alternative wäre reiner Dateisystem-Speicher
#                      (PENPOT_OBJECTS_STORAGE_BACKEND=fs), aber dieses
#                      Chart benutzt standardmäßig S3/MinIO.
#
# Zusammen mit den 3 Penpot-eigenen Diensten sind das also 6 Services
# insgesamt:
#
#   penpot-backend    -> die eigentliche Anwendungslogik/API (Java/Clojure)
#   penpot-frontend   -> die Web-Oberfläche (nginx + statische Dateien)
#   penpot-exporter   -> rendert PDF/PNG/SVG-Exporte mit einem echten
#                        Browser im Hintergrund (Playwright/Chromium)
#   penpot-postgres   -> Datenbank
#   penpot-valkey     -> Cache/Pub-Sub für Echtzeit-Funktionen
#   penpot-minio      -> Objekt-Speicher
#
# Von diesen 6 haben nur 2 einen PVC (persistenten Speicher, der einen
# Neustart überlebt): penpot-postgres und penpot-minio. Die anderen 4 sind
# zustandslos ("stateless") — sie speichern nichts dauerhaft selbst.
#
# Optional (nicht Pflicht, in diesem Chart nicht enthalten): ein SMTP-Server
# zum Versenden von Einladungs-/Bestätigungs-E-Mails. Diese Dev/Test-
# Installation hat die E-Mail-Bestätigung einfach deaktiviert
# (disable-email-verification in values.yaml's "flags").
#
# -----------------------------------------------------------------------------
# 2) WELCHE IMAGES WERDEN BENUTZT? (genau das, was in values.yaml steht)
# -----------------------------------------------------------------------------
#
#   penpot-backend:   docker.io/penpotapp/backend:2.17.2
#   penpot-frontend:  docker.io/penpotapp/frontend:2.17.2
#   penpot-exporter:  docker.io/penpotapp/exporter:2.17.2
#   penpot-postgres:  registry.redhat.io/rhel9/postgresql-16:1   (zertifiziertes Red-Hat-Image)
#   penpot-valkey:    registry.redhat.io/rhel9/valkey-8:8        (zertifiziertes Red-Hat-Image)
#   penpot-minio:     quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772
#   Bucket-Erstellung (einmaliger Job): quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z-cpuv1
#
# Postgres und Valkey liefen ursprünglich auf den einfachen Docker-Hub-Images
# (postgres:16-alpine, valkey/valkey:8-alpine) — siehe Abschnitt 4 unten für
# den Wechsel zu den Red-Hat-Images und eine wichtige Lehre daraus.
#
# -----------------------------------------------------------------------------
# 3) GIBT ES DIESE IMAGES AUCH AUF QUAY.IO ODER IN DER OPENSHIFT-REGISTRY?
# -----------------------------------------------------------------------------
#
# Zuerst eine wichtige Begriffsklärung, weil "OpenShift-Registry" zwei ganz
# unterschiedliche Dinge bedeuten kann:
#
#   a) registry.redhat.io — Red Hats offizielle Registry für zertifizierte
#      Produkt-Images. Braucht meistens einen Red Hat Account / eine
#      Subscription (das globale Pull-Secret des Clusters).
#   b) Die INTERNE Registry jedes einzelnen OpenShift-Clusters
#      (image-registry.openshift-image-registry.svc:5000) — die ist am
#      Anfang LEER, das ist nur ein Ort, wohin man EIGENE gebaute Images
#      hochladen kann. Dort "findet" man fremde Images nicht automatisch.
#
# Für jedes Image, das dieses Chart benutzt, hier das tatsächliche Ergebnis
# (live geprüft, nicht geraten):
#
# --- Penpot (backend/frontend/exporter) ---
#   NUR auf Docker Hub verfügbar: https://hub.docker.com/r/penpotapp/backend
#   NICHT auf quay.io (live geprüft: quay.io-Suche nach "penpotapp" liefert
#   null Ergebnisse). NICHT in registry.redhat.io — Penpot ist eine
#   Drittanbieter-Anwendung, kein von Red Hat gepflegtes Produkt.
#
# --- PostgreSQL ---
#   Das offizielle (Docker-Hub-)Image ist NICHT auf quay.io, und nicht das,
#   was jetzt in diesem Chart läuft. Dieses Chart benutzt inzwischen
#   TATSÄCHLICH das zertifizierte Red-Hat-Image aus der OpenShift-Registry:
#     - registry.redhat.io/rhel9/postgresql-16:1 (braucht eine Red Hat
#       Subscription/Pull-Secret — CRC hat das bereits automatisch)
#       Katalog-Seite: https://catalog.redhat.com/en/software/containers/rhel9/postgresql-16/657b03866783e1b1fb87e142
#   ACHTUNG, das ist ein ANDERES Image als das ursprüngliche
#   docker.io/library/postgres:16-alpine — andere Umgebungsvariablen
#   (POSTGRESQL_USER/PASSWORD/DATABASE statt POSTGRES_USER/PASSWORD/DB) und
#   ein anderer interner Datenpfad (/var/lib/pgsql/data/userdata statt
#   /var/lib/postgresql/data/pgdata). Siehe Abschnitt 4 unten — das hat bei
#   diesem Projekt tatsächlich zu Datenverlust beim Umstieg geführt.
#   Alternative auf quay.io (Community-Build, ohne Anmeldung, nicht das,
#   was hier läuft, aber falls man KEINE Red-Hat-Subscription hat):
#     - quay.io/sclorg/postgresql-16-c9s
#
# --- Valkey ---
#   Genau wie bei PostgreSQL: dieses Chart benutzt inzwischen das
#   zertifizierte Red-Hat-Image aus der OpenShift-Registry:
#     - registry.redhat.io/rhel9/valkey-8:8 (braucht eine Red Hat
#       Subscription/Pull-Secret — CRC hat das bereits automatisch)
#       Katalog-Seite: https://catalog.redhat.com/en/software/containers/rhel9/valkey-8/685511dd20cfb9db8fefa1cd
#   Das ursprüngliche offizielle Image (docker.io/valkey/valkey) gibt es
#   NICHT als eigenständiges, benutzbares Image auf quay.io (live geprüft —
#   dort liegen nur interne Red-Hat-Build-Artefakte, nichts Brauchbares).
#
# --- MinIO ---
#   HIER ist es umgekehrt: MinIO hat im Oktober 2025 aufgehört, kostenlose
#   Images auf Docker Hub zu veröffentlichen. Deswegen benutzt dieses Chart
#   bereits die quay.io-Variante:
#     - https://quay.io/repository/minio/minio
#     - https://quay.io/repository/minio/mc (für den Bucket-Erstellungs-Job)
#   Es gibt KEIN offizielles Red-Hat/registry.redhat.io-Äquivalent — Red Hat
#   stellt MinIO nicht als eigenes zertifiziertes Produkt bereit.
#
# -----------------------------------------------------------------------------
# ZUSAMMENFASSUNG
# -----------------------------------------------------------------------------
#
#   Image          | Docker Hub | quay.io | registry.redhat.io      | tatsächlich benutzt
#   ---------------|------------|---------|--------------------------|--------------------
#   Penpot (3x)    | ja (nur)   | nein    | nein                     | Docker Hub
#   PostgreSQL     | ja*        | nein**  | ja (rhel9/postgresql-16) | registry.redhat.io
#   Valkey         | ja*        | nein**  | ja (rhel9/valkey-8)      | registry.redhat.io
#   MinIO          | nein***    | ja      | nein                     | quay.io
#
#   * Das ursprüngliche, offizielle Image — nicht mehr das, was dieses
#     Chart benutzt (siehe Abschnitt 4).
#   ** Es gibt eine Community-Alternative auf quay.io (sclorg/postgresql-16-c9s
#      für Postgres), aber keine für Valkey.
#   *** MinIO stellte kostenlose Docker-Hub-Images bis Oktober 2025 bereit;
#       seitdem nur noch über quay.io/minio/minio verfügbar.
#
# -----------------------------------------------------------------------------
# 4) WARUM POSTGRES/VALKEY JETZT AUS DER OPENSHIFT-REGISTRY KOMMEN — UND WAS
#    DABEI SCHIEFGING
# -----------------------------------------------------------------------------
#
# Auf ausdrücklichen Wunsch wurden Postgres und Valkey von den einfachen
# Docker-Hub-Images auf die zertifizierten Red-Hat-Images aus der
# OpenShift-Registry umgestellt (registry.redhat.io/rhel9/postgresql-16 und
# .../rhel9/valkey-8). Technisch funktioniert das einwandfrei — beide Images
# laufen stabil unter der `restricted-v2` SCC von OpenShift, ohne
# Extra-Rechte.
#
# ABER: das neue Postgres-Image benutzt intern einen ANDEREN Datenpfad
# (/var/lib/pgsql/data/userdata) als das alte Docker-Hub-Image
# (/var/lib/postgresql/data/pgdata) — obwohl derselbe PVC (derselbe
# Datenträger) weiterbenutzt wurde. Das neue Image hat an seinem erwarteten
# Pfad keine Daten gefunden und deshalb automatisch eine FRISCHE, LEERE
# Datenbank angelegt, statt die alten Daten zu übernehmen. Ein zuvor
# registrierter Testnutzer-Account ist dabei tatsächlich verloren gegangen
# (die alten Bytes liegen noch ungenutzt auf demselben PVC, aber ohne
# manuelle Wiederherstellung nicht zugänglich).
#
# DIE LEHRE: beim Wechsel des Datenbank-Images (nicht nur bei Penpot, bei
# JEDER Anwendung mit Datenbank) IMMER vorher prüfen, ob das neue Image
# denselben Datenpfad/dieselbe Datenstruktur benutzt wie das alte — sonst
# lieber vorher ein Backup machen, auch wenn "nur" ein Dev/Test-Cluster
# betroffen ist.
#
# Mehr Details (Architektur, Warum jede Komponente gebraucht wird, wie man
# prüft ob alles verbunden ist) stehen auf Englisch in README.md und
# INSTALL.md in diesem Repo.
