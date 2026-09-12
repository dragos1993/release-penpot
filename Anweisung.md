# Anweisung: Was braucht Penpot, um in einem Cluster zu laufen?

Diese Datei ist reine Dokumentation — Helm/Kubernetes liest sie nicht,
sie ist kein Teil des Charts. Sie beantwortet auf Deutsch: welche
Services braucht Penpot, welche Container-Images werden benutzt, und ob
man diese Images auch in der OpenShift-Registry oder auf quay.io findet.

## 1) Welche Services braucht Penpot?

Penpot selbst besteht aus 3 eigenen Diensten (Backend, Frontend,
Exporter). Dazu kommen 3 weitere Dienste, die Penpot zwingend zum
Laufen braucht:

1. **PostgreSQL** — die Datenbank. Speichert Benutzerkonten, Teams, und
   auch den Inhalt der Design-Dateien selbst (als JSON in
   Datenbank-Zeilen). **Pflicht.**
2. **Valkey** — Redis-kompatibler Dienst. Wird für die
   Echtzeit-Zusammenarbeit gebraucht (mehrere Personen bearbeiten
   gleichzeitig dieselbe Datei über WebSockets) — auch mit nur EINER
   Backend-Kopie benötigt, nicht nur zum Skalieren. **Pflicht**, auch
   wenn man es leicht übersieht.
3. **MinIO** — Objekt-Speicher (S3-kompatibel) für hochgeladene Bilder,
   Schriftarten und exportierte PDF/PNG/SVG-Dateien. Alternative wäre
   reiner Dateisystem-Speicher (`PENPOT_OBJECTS_STORAGE_BACKEND=fs`),
   aber dieses Chart benutzt standardmäßig S3/MinIO.

Zusammen mit den 3 Penpot-eigenen Diensten sind das also 6 Services
insgesamt:

| Service | Rolle |
|---|---|
| `penpot-backend` | die eigentliche Anwendungslogik/API (Java/Clojure) |
| `penpot-frontend` | die Web-Oberfläche (nginx + statische Dateien) |
| `penpot-exporter` | rendert PDF/PNG/SVG-Exporte mit einem echten Browser im Hintergrund (Playwright/Chromium) |
| `penpot-postgres` | Datenbank |
| `penpot-valkey` | Cache/Pub-Sub für Echtzeit-Funktionen |
| `penpot-minio` | Objekt-Speicher |

Von diesen 6 haben nur 2 einen PVC (persistenten Speicher, der einen
Neustart überlebt): `penpot-postgres` und `penpot-minio`. Die anderen 4
sind zustandslos ("stateless") — sie speichern nichts dauerhaft selbst.

Optional (nicht Pflicht, in diesem Chart nicht enthalten): ein
SMTP-Server zum Versenden von Einladungs-/Bestätigungs-E-Mails. Diese
Dev/Test-Installation hat die E-Mail-Bestätigung einfach deaktiviert
(`disable-email-verification` in `values.yaml`'s `flags`).

## 2) Welche Images werden benutzt? (genau das, was in `values.yaml` steht)

| Service | Image | Herkunft |
|---|---|---|
| `penpot-backend` | `docker.io/penpotapp/backend:2.17.2` | Docker Hub |
| `penpot-frontend` | `docker.io/penpotapp/frontend:2.17.2` | Docker Hub |
| `penpot-exporter` | `docker.io/penpotapp/exporter:2.17.2` | Docker Hub |
| `penpot-postgres` | `registry.redhat.io/rhel9/postgresql-16:1` | **OpenShift/Red-Hat-Registry** |
| `penpot-valkey` | `registry.redhat.io/rhel9/valkey-8:8` | **OpenShift/Red-Hat-Registry** |
| `penpot-minio` | `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772` | quay.io |
| Bucket-Erstellung (einmaliger Job) | `quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z-cpuv1` | quay.io |

Postgres und Valkey liefen ursprünglich auf den einfachen
Docker-Hub-Images (`postgres:16-alpine`, `valkey/valkey:8-alpine`) —
siehe Abschnitt 4 für den Wechsel zu den Red-Hat-Images und eine
wichtige Lehre daraus.

## 3) Gibt es diese Images auch auf quay.io oder in der OpenShift-Registry?

Zuerst eine wichtige Begriffsklärung, weil "OpenShift-Registry" zwei
ganz unterschiedliche Dinge bedeuten kann:

- **`registry.redhat.io`** — Red Hats offizielle Registry für
  zertifizierte Produkt-Images. Braucht meistens einen Red Hat Account
  / eine Subscription (das globale Pull-Secret des Clusters).
- **Die interne Registry jedes einzelnen OpenShift-Clusters**
  (`image-registry.openshift-image-registry.svc:5000`) — die ist am
  Anfang leer, das ist nur ein Ort, wohin man eigene gebaute Images
  hochladen kann. Dort "findet" man fremde Images nicht automatisch.

Für jedes Image, das dieses Chart benutzt, hier das tatsächliche
Ergebnis (live geprüft, nicht geraten):

### Penpot (backend/frontend/exporter)

Nur auf Docker Hub verfügbar: <https://hub.docker.com/r/penpotapp/backend>.
Nicht auf quay.io (live geprüft: quay.io-Suche nach `penpotapp` liefert
null Ergebnisse). Nicht in `registry.redhat.io` — Penpot ist eine
Drittanbieter-Anwendung, kein von Red Hat gepflegtes Produkt.

### PostgreSQL — jetzt aus der OpenShift-Registry

Dieses Chart benutzt **tatsächlich** das zertifizierte Red-Hat-Image
aus der OpenShift-Registry:

```
registry.redhat.io/rhel9/postgresql-16:1
```

Braucht eine Red-Hat-Subscription/Pull-Secret — CRC hat das bereits
automatisch konfiguriert. Katalog-Seite:
<https://catalog.redhat.com/en/software/containers/rhel9/postgresql-16/657b03866783e1b1fb87e142>

**Achtung**, das ist ein *anderes* Image als das ursprüngliche
`docker.io/library/postgres:16-alpine`:

- andere Umgebungsvariablen: `POSTGRESQL_USER`/`PASSWORD`/`DATABASE`
  statt `POSTGRES_USER`/`PASSWORD`/`DB`
- anderer interner Datenpfad: `/var/lib/pgsql/data/userdata` statt
  `/var/lib/postgresql/data/pgdata`

Siehe Abschnitt 4 — das hat bei diesem Projekt tatsächlich zu
Datenverlust beim Umstieg geführt.

Alternative auf quay.io (Community-Build, ohne Anmeldung, **nicht**
das, was hier läuft, aber falls man keine Red-Hat-Subscription hat):
`quay.io/sclorg/postgresql-16-c9s`.

### Valkey — jetzt aus der OpenShift-Registry

Genau wie bei PostgreSQL benutzt dieses Chart das zertifizierte
Red-Hat-Image:

```
registry.redhat.io/rhel9/valkey-8:8
```

Braucht ebenfalls eine Red-Hat-Subscription/Pull-Secret. Katalog-Seite:
<https://catalog.redhat.com/en/software/containers/rhel9/valkey-8/685511dd20cfb9db8fefa1cd>

Das ursprüngliche offizielle Image (`docker.io/valkey/valkey`) gibt es
**nicht** als eigenständiges, benutzbares Image auf quay.io (live
geprüft — dort liegen nur interne Red-Hat-Build-Artefakte, nichts
Brauchbares).

Anders als Postgres brauchte der Wechsel bei Valkey keine
Umgebungsvariablen-Änderung (keine ist Pflicht) — nur die bisherigen
eigenen `args:` (`--maxmemory ...`) mussten entfernt werden, weil dieses
Image sein eigenes Start-Skript mitbringt, das die echte
`valkey-server`-Kommandozeile selbst zusammenbaut.

### MinIO

Hier ist es umgekehrt: MinIO hat im Oktober 2025 aufgehört, kostenlose
Images auf Docker Hub zu veröffentlichen. Deswegen benutzt dieses Chart
bereits die quay.io-Variante: `quay.io/minio/minio` und
`quay.io/minio/mc` (für den Bucket-Erstellungs-Job). Es gibt **kein**
offizielles Red-Hat/`registry.redhat.io`-Äquivalent — Red Hat stellt
MinIO nicht als eigenes zertifiziertes Produkt bereit.

### Zusammenfassung

| Image | Docker Hub | quay.io | registry.redhat.io | tatsächlich benutzt |
|---|---|---|---|---|
| Penpot (3×) | ja (nur) | nein | nein | Docker Hub |
| PostgreSQL | ja¹ | nein² | ja (`rhel9/postgresql-16`) | **registry.redhat.io** |
| Valkey | ja¹ | nein² | ja (`rhel9/valkey-8`) | **registry.redhat.io** |
| MinIO | nein³ | ja | nein | quay.io |

¹ Das ursprüngliche, offizielle Image — nicht mehr das, was dieses
Chart benutzt.
² Für Postgres gibt es eine Community-Alternative auf quay.io
(`sclorg/postgresql-16-c9s`), für Valkey nicht.
³ MinIO stellte kostenlose Docker-Hub-Images bis Oktober 2025 bereit;
seitdem nur noch über `quay.io/minio/minio` verfügbar.

## 4) Warum Postgres/Valkey jetzt aus der OpenShift-Registry kommen — und was dabei schiefging

Auf ausdrücklichen Wunsch wurden Postgres und Valkey von den einfachen
Docker-Hub-Images auf die zertifizierten Red-Hat-Images aus der
OpenShift-Registry umgestellt. Die konkreten Schritte dazu:

1. **Konfigurationsschnittstelle recherchiert** (bevor irgendetwas
   geändert wurde): die offiziellen sclorg-Container-READMEs
   (`sclorg/postgresql-container`, `sclorg/valkey-container` auf
   GitHub) geprüft, um die exakten Umgebungsvariablen und Datenpfade
   dieser Images zu kennen.
2. **Zugangsdaten geprüft**: `oc get secret pull-secret -n
   openshift-config` zeigte, dass CRC bereits `registry.redhat.io`
   -Zugangsdaten mitbringt — kein zusätzliches Pull-Secret nötig.
3. **`values.yaml` geändert**: `postgresImage`/`postgresTag` und
   `valkeyImage`/`valkeyTag` auf die neuen Bilder umgestellt (stabile
   Stream-Tags `1` bzw. `8`, ermittelt über
   `podman search --list-tags registry.redhat.io/...`).
4. **`templates/postgres.yaml` geändert**: Umgebungsvariablen von
   `POSTGRES_DB`/`USER`/`PASSWORD` auf
   `POSTGRESQL_DATABASE`/`USER`/`PASSWORD` umgestellt, Mount-Pfad von
   `/var/lib/postgresql/data` auf `/var/lib/pgsql/data` geändert, den
   alten `PGDATA`-Unterordner-Trick entfernt (das neue Image verwaltet
   das intern selbst).
5. **`templates/valkey.yaml` geändert**: die eigenen `args:`
   (`--maxmemory 128mb` usw.) entfernt, da dieses Image sein eigenes
   Start-Skript benutzt.
6. **Commit + Push + ArgoCD-Sync ausgelöst**
   (`oc annotate application penpot-app -n argocd
   argocd.argoproj.io/refresh=hard --overwrite`), dann live geprüft:
   Pods wurden neu erstellt, Images wurden erfolgreich von
   `registry.redhat.io` gepullt, `oc get application penpot-app -n
   argocd` zeigte am Ende `Synced`/`Healthy`.

Technisch funktioniert das jetzt einwandfrei — beide Images laufen
stabil unter der `restricted-v2` SCC von OpenShift, ohne
Extra-Rechte.

**Aber**: das neue Postgres-Image benutzt intern einen *anderen*
Datenpfad (`/var/lib/pgsql/data/userdata`) als das alte Docker-Hub-Image
(`/var/lib/postgresql/data/pgdata`) — obwohl derselbe PVC (derselbe
Datenträger) weiterbenutzt wurde. Das neue Image hat an seinem
erwarteten Pfad keine Daten gefunden und deshalb automatisch eine
**frische, leere Datenbank** angelegt, statt die alten Daten zu
übernehmen. Ein zuvor registrierter Testnutzer-Account ist dabei
tatsächlich verloren gegangen (die alten Bytes liegen noch ungenutzt
auf demselben PVC, aber ohne manuelle Wiederherstellung nicht
zugänglich).

**Die Lehre**: beim Wechsel des Datenbank-Images (nicht nur bei
Penpot, bei jeder Anwendung mit Datenbank) immer vorher prüfen, ob das
neue Image denselben Datenpfad/dieselbe Datenstruktur benutzt wie das
alte — sonst lieber vorher ein Backup machen, auch wenn "nur" ein
Dev/Test-Cluster betroffen ist.

---

Mehr Details (Architektur, warum jede Komponente gebraucht wird, wie
man prüft ob alles verbunden ist) stehen auf Englisch in `README.md`
und `INSTALL.md` in diesem Repo.
