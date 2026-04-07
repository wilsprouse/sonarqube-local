# sonarqube-local

Run SonarQube locally with Docker and scan any project folder — all from a single script.

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| [Docker](https://docs.docker.com/get-docker/) | Runs the SonarQube container and the scanner |
| `curl` | Talks to the SonarQube REST API |

No local SonarQube installation or `sonar-scanner` binary is required.

---

## Quick start

```bash
# Clone the repo
git clone https://github.com/wilsprouse/sonarqube-local.git
cd sonarqube-local

# Make the script executable (first time only)
chmod +x sonar-local.sh

# Start SonarQube and scan a project
./sonar-local.sh --dir /path/to/your/project
```

SonarQube starts, the admin password is rotated automatically, the project is
created, a scan is performed, and the script prints a credential summary when
it finishes.

---

## Options

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--dir <path>` | `-d` | _(required for scanning)_ | Path to the local project to scan |
| `--name <name>` | `-n` | directory basename | Project key / display name in SonarQube |
| `--port <port>` | `-p` | `9000` | Host port to expose SonarQube on |
| `--skip-start` | | `false` | Skip `docker compose up` (use an already-running instance) |
| `--skip-scan` | | `false` | Start SonarQube only — no scan is performed |
| `--down` | | `false` | Stop and remove the SonarQube containers, then exit |
| `--help` | `-h` | | Show usage information |

---

## Examples

### Start SonarQube only (no scan)

```bash
./sonar-local.sh --skip-scan
```

### Scan a project on a custom port

```bash
./sonar-local.sh --dir ~/projects/my-app --port 9100
```

### Scan with an explicit project name

```bash
./sonar-local.sh --dir ~/projects/my-app --name "My Application"
```

### Re-scan an already-running instance (skip `docker compose up`)

```bash
./sonar-local.sh --dir ~/projects/my-app --skip-start
```

### Tear everything down

```bash
./sonar-local.sh --down
```

---

## Credential handling

On first run the script:

1. Detects that the default `admin` / `admin` credentials are still active.
2. Generates a random 20-character alphanumeric password and rotates it via
   the SonarQube API.
3. Creates a **project-scoped analysis token** (no global token permissions).
4. Passes the token directly to the scanner — you never need to copy/paste it.

On subsequent runs the script tries the default password first. If it fails
(password already rotated), it falls back to the `SONAR_ADMIN_PASSWORD`
environment variable, then prompts interactively.

### Credential summary

At the end of every successful run the script prints:

```
============================================================
 SonarQube Local — Summary
============================================================
  SonarQube URL:         http://localhost:9000
  Admin username:        admin
  Admin password:        <generated>
  Project key:           my-app
  Analysis token:        sqa_xxxxxxxxxxxxxxxxxxxx
============================================================

View results: http://localhost:9000/dashboard?id=my-app
```

---

## Persistence

Docker named volumes keep SonarQube data, extensions, and logs across container restarts. Remove them with:

```bash
docker volume rm sonarqube_data sonarqube_extensions sonarqube_logs
```

---

## Architecture

```
sonar-local.sh
    │
    ├── docker compose up        (sonarqube container)
    ├── wait for /api/system/status → "UP"
    ├── POST /api/users/change_password   (rotate default password)
    ├── POST /api/projects/create         (idempotent)
    ├── POST /api/user_tokens/generate    (project-scoped token)
    └── docker run sonarsource/sonar-scanner-cli
```
