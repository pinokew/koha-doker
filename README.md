# README

# Koha Docker (v25.05 Production Ready) 🐳📚

**A fully operational, modern Docker configuration for deploying Koha ILS (Integrated Library System) v25.05.**

This repository provides a robust, microservices-based architecture designed for stability, performance, and ease of deployment on both **Linux** and **Windows (WSL 2)** environments.

## ✨ Key Features

This build moves away from legacy CGI methods to a modern Plack-based architecture.

- **Core Version:** Koha **25.05** (stable).
- **Architecture:** True microservices approach (Koha, MariaDB, Elasticsearch, Memcached, RabbitMQ running in isolated containers).
- **Web Server:** Apache2 + **Plack (Starman)**. Delivers significantly higher performance and lower latency compared to the traditional CGI mode.
- **Search Engine:** **Elasticsearch 8.19.6** (pre-configured with `analysis-icu` plugin for correct multilingual support).
- **Database:** MariaDB 11.
- **Caching:** Memcached (for session handling and system acceleration).
- **Message Broker:** **RabbitMQ** (with STOMP plugin enabled). Essential for real-time indexing and background tasks.

## 🛠️ Enhancements & Architecture Fixes

This repository solves common pain points found in standard Koha Docker setups.

### 1. Windows (WSL 2) Compatibility 🪟

- **EOL Fixes:** Integrated `dos2unix` conversion during the build process to automatically fix Windows CRLF line endings in scripts, preventing container startup failures.
- **Permission Handling:** Optimized for WSL 2 file system quirks.

### 2. "The Big Split" Architecture 🏗️

We separated configuration logic to ensure stability:

- **Build-Time (`patch-koha-templates.sh`):** Generates perfect configuration templates (`koha-conf.xml`, `log4perl.conf`) on the host using `.env` variables *before* the container starts.
- **Run-Time (`02-setup-koha.sh`):** Handles initialization, database connectivity, and service startup inside the container.

### 3. Stability & Performance 🚀

- **Permissions Hell Solved:** Runs services under a dedicated system user `library-koha` (UID 1000) instead of `root` or `www-data`, fixing `503 Service Unavailable` and permission denied errors.
- **Race Condition Fix:** `docker-compose.yml` includes strict `healthcheck` conditions. Koha waits until MariaDB and RabbitMQ are fully healthy before attempting to start.
- **Auto-Indexing:** The `koha-es-indexer` daemon is configured to start automatically, ensuring real-time search indexing without manual cron jobs.

### 4. Backup & Disaster Recovery 🛡️

- **Included Scripts:** ready-to-use `backup.sh` and `restore.sh` scripts.
- **Full Cycle:** Backs up SQL data, configuration volumes, and local files. Restore script handles volume cleaning and full re-indexing automatically.

## 🚀 Installation Guide

### Prerequisites

- **Docker Desktop** (Windows) or **Docker Engine** (Linux).
- **Windows Users:** Ensure you are using the **WSL 2** backend.
- **Git**

### Step 1: Clone the Repository

```
git clone https://github.com/pinokew/koha-doker.git

```

### Step 2: Environment Setup

Create your `.env` file from the example template.

```
cp .env.example .env

```

**⚠️ Important:** Open `.env` and change the default passwords!

```
# .env example
KOHA_IMAGE_TAG=25.05
KOHA_INSTANCE=library
DB_NAME=koha_library

# SECURITY WARNING: Change these passwords!
DB_USER=koha_library
DB_PASS=SecurePassword123!
DB_ROOT_PASS=SuperRootPassword456!
RABBITMQ_DEFAULT_PASS=RabbitPass789!

```

### Step 3: Download & Patch Templates (For the version of Koha 25.05.xx not required)

Before building images, you must generate the correct configuration files using the official Koha templates.

1. Download Source Templates:
    
    Go to the official Koha Git repository: https://git.koha-community.org/Koha-community/Koha.
    
    Select the branch/tag corresponding to your target version (e.g., v25.05.x) and navigate to debian/templates. Download the following files:
    
    - `koha-conf-site.xml.in`
    - `koha-common.cnf`
    - `koha-sites.conf`
    - `SIPconfig.xml`
    
    Save them to a local folder on your machine.
    
2. Configure the Patch Script:
    
    Open the patch-koha-templates.sh script in a text editor.
    
    Find and update the path variables to match your environment:
    
    - Set the path to the folder where you downloaded the `.in` files.
    - Set the path to the root of your `koha-docker` directory.
3. **Run the Script:**
    
    ```
    ./patch-koha-templates.sh
    
    ```
    

**⚠️ STOP AND VERIFY:** Proceed to Step 4 **only if** the script runs successfully and the patched files are correctly written to the `files/docker/templates` directory. If this step fails, the Docker build will not contain the correct configurations.

### Step 4: Build and Launch

Run the following command. The first build may take 5–15 minutes.

```
docker compose up -d --build

```

Wait 1–2 minutes after the containers are up for the initialization scripts to complete (look for "healthy" status).

### Step 5: Web Installer

Open your browser and navigate to the Koha Staff Interface:

👉 http://localhost:8081

1. **Login:** Use the value of `DB_USER` from your `.env` (e.g., `koha_library`).
2. **Password:** Use the value of `DB_PASS` from your `.env`.

Follow the on-screen wizard to create your library administrator account and configure basic settings.

## 📂 Administration & Maintenance

### Backup & Restore

This repository includes custom scripts for data safety.

- **Backup:**
    
    ```
    ./backup.sh
    
    ```
    
    Creates a timestamped folder in `./backups` containing SQL dumps and volume archives.
    
- Restore:
    
    Edit restore.sh to point to your backup folder, then run:
    
    ```
    ./restore.sh
    
    ```
    
    *Warning: This destroys current data and replaces it with the backup.*
    

### Useful Commands

```
# Stop all containers
docker compose down

# Stop and remove volumes (DANGER: Deletes all data!)
docker compose down -v

# View Koha logs
docker compose logs -f koha

# Enter the Koha container shell
docker compose exec koha bash

# Rebuild search index manually
docker compose exec koha koha-elasticsearch --rebuild -d -v library

```

## 📜 License

This project is licensed under the GPL v3, consistent with the Koha project.