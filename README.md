<div align="center">

# 👑 MARGO

**One day. One discovery.**

Your personal guide to knowledge on Windows, Android, and Linux.<br>
One Wikipedia article a day, chosen around your interests. A new reason to stay curious.

![Platforms: Windows, Android, and Linux](https://img.shields.io/badge/platforms-Windows%20%7C%20Android%20%7C%20Linux-5952D4)
![Flutter and Dart](https://img.shields.io/badge/client-Flutter%20%2F%20Dart-02569B)
![FastAPI and Python](https://img.shields.io/badge/API-FastAPI%20%2F%20Python-009688)

[Download](https://github.com/vlod1k/MARGO/releases/latest) · [Features](#features) · [Getting started](#getting-started) · [Development](#development) · [Documentation](#documentation)

</div>

![MARGO 0.4.5 daily article screen in light mode](apps/margo_flutter/design-preview/desktop.png)

<details>
<summary>Mobile layout and dark mode</summary>

<p align="center">
  <img src="apps/margo_flutter/design-preview/mobile.png" alt="MARGO 0.4.5 mobile layout" width="320">
</p>

![MARGO 0.4.5 daily article screen in dark mode](apps/margo_flutter/design-preview/dark.png)

</details>

## About

MARGO turns curiosity into a small daily habit. Choose your interests, get a short introduction to an article, and open the full text on Wikipedia. Save discoveries, mark articles as read, and leave feedback to shape future recommendations.

Your daily article stays assigned to your day in your time zone. Every fifth day, discovery mode offers a chance to explore beyond your usual topics.

The name is inspired by Queen Margot, and the app's symbol is a golden crown.

## Features

| Feature | What it does |
| --- | --- |
| **Daily article** | Personalized recommendations across 20 topics, without repeat assignments, with an explanation of each recommendation |
| **Article catalog** | Per-language availability in your profile, scheduled daily replenishment, and a clear message when no new articles are available |
| **Feedback** | Four responses: Like, Not interested, Already know, and Too difficult |
| **Personal library** | Reading history, saved articles, search, and filters |
| **Reading progress** | Read status, statistics, and a calendar |
| **Across devices** | One account for Windows, Android, and Linux, with synchronized actions and conflict handling |
| **Offline access** | Previously downloaded cards and a persistent queue of actions to sync when you reconnect |
| **Appearance** | Light, dark, and system themes, custom fonts, and adaptive navigation |
| **Account and data controls** | Password recovery and changes, sign out other sessions, data export, and account deletion |

Windows and Android support local daily reminders independently of article downloads, as well as update checks. Release builds download available updates automatically; installation starts when you choose it.

> Full articles open on Wikipedia and require an internet connection.

## Getting started

Download the files for your platform from [GitHub Releases](https://github.com/vlod1k/MARGO/releases/latest).

| Platform | Download |
| --- | --- |
| **Windows x64** | `MARGO-Setup-<version>.exe` — installer for the current user |
| **Windows Portable** | Extract the **entire** Windows ZIP archive, then run `margo.exe` |
| **Linux x86_64** | `MARGO-<version>-x86_64.flatpak` — see the [installation and build guide](docs/linux.md) |
| **Android 7.0+** | `MARGO-Android.apk` — APK for direct installation |

The app interface and linked technical guides are currently in Russian. Russian and English article availability depends on the server's catalog.

### Try without an account

On the sign-in screen, choose the option to try MARGO without an account. This mode includes four bundled article cards, a sample daily article, saved articles, feedback, statistics, and settings. Data stays on the device between launches, separately from account data. New recommendations and reminders require an account and server access.

### Use an account

1. Install or build the app for your platform.
2. Create an account and choose your interests, article language, and time zone.
3. Save your profile to receive your first article.

Sign-in, new recommendations, and synchronization require a reachable server. The server address is set at build time with `API_BASE_URL`. For the Android and Windows build scripts, set the `API_BASE_URL` and `UPDATE_MANIFEST_URL` environment variables.

You do not need the Flutter SDK to use a ready-made build. The Windows installer includes the Visual C++ x64 runtime libraries; the portable version may require them separately.

The `dist/` directory is created during [builds](#building) and is not tracked in Git. GitHub Actions stores artifacts after successful [Windows and Android](.github/workflows/ci.yml) and [Linux](.github/workflows/linux-flatpak.yml) builds.

## Development

### Requirements

- **Flutter 3.47.9 / Dart 3.13.7** — the versions configured in CI. See the [Flutter installation guide](https://docs.flutter.dev/install).
- **Python 3.12+** and **uv** for the backend.
- **Windows:** Visual Studio with the *Desktop development with C++* workload.
- **Android:** Android SDK, JDK 17, and accepted SDK licenses.
- **Linux:** Flatpak, flatpak-builder, and the SDKs listed in the [Linux guide](docs/linux.md).
- **Docker Compose** to run the backend with PostgreSQL.

The Windows, Android, and Linux clients share a Flutter codebase.

### Run locally

From the project root, start the backend in PowerShell:

```powershell
./scripts/start-backend.ps1
```

The script installs dependencies with uv, applies migrations, seeds the catalog, and starts the API at `http://127.0.0.1:8000`. Interactive API documentation is available at `http://127.0.0.1:8000/docs`. This local setup uses SQLite.

In a second terminal, start the client:

```powershell
cd apps/margo_flutter
flutter pub get
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

For an Android emulator, use `10.0.2.2` to reach the host machine:

```powershell
flutter run -d <device-id> --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

Run `flutter devices` to find the device ID. If Flutter is installed locally in `.tools/flutter`, use `../../.tools/flutter/bin/flutter.bat` instead of `flutter` from the client directory on Windows.

<details>
<summary>Shared backend with PostgreSQL and VPS deployment</summary>

To synchronize multiple devices, use a shared API and PostgreSQL. From the project root:

```powershell
Copy-Item .env.example .env
# Set a long, random POSTGRES_PASSWORD in .env.
docker compose up --build
```

Compose starts PostgreSQL, the API, and a separate scheduler. Password characters that have a special meaning in a URL must be URL-encoded when used in `DATABASE_URL`. Keep `.env` out of Git.

For a VPS, set `API_DOMAIN` in `.env` without `https://`, point your DNS record to the server, and allow inbound TCP ports 80 and 443. Caddy obtains an HTTPS certificate; the API and PostgreSQL stay on the internal Docker network.

```sh
docker compose -f docker-compose.yml -f docker-compose.vps.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.vps.yml up -d --build
curl --fail https://api.example.com/health
```

Replace `api.example.com` with your domain. Build the client with `--dart-define=API_BASE_URL=https://api.example.com`. Configure the update manifest URL separately; see the [update guide](docs/updates.md).

The built-in authentication rate limiter is designed for one API process. Multiple processes need a shared rate limit at the reverse proxy.

The [operations guide](docs/operations.md) covers backups, restore verification, and Telegram/webhook alerts. Before using the VPS configuration, set `MARGO_VERIFY_PASSWORD` and an alert destination in `.env`.

</details>

### Building

Run these commands from the project root in PowerShell. Replace the example URLs with your own API and update manifest:

```powershell
$env:API_BASE_URL = 'https://api.example.com'
$env:UPDATE_MANIFEST_URL = 'https://api.example.com/releases/latest.json'

# Windows: portable archive and installer
./scripts/build-windows.ps1
./scripts/build-windows-installer.ps1

# Android: release APK for direct installation
$env:MARGO_ANDROID_CERT_SHA256 = '47cdf9c65e2bd828b455430785c983ba6e50a804c8c06bd6f8c21e06900a52ad'
./scripts/build-android.ps1 -AllowLegacyDebugCertificate -PreviousApk .secrets/margo-signing/previous-0.4.3-11.apk
```

Build outputs appear in `dist/`. The Windows installer requires [Inno Setup 6](https://jrsoftware.org/isdl.php) and the Visual C++ x64 runtime libraries from Visual Studio. For a debug APK, use `./scripts/build-android.ps1 -Mode debug`.

The Android command above is for the existing direct-install update channel and requires its signing key and previous APK. For your own builds, configure your own signing identity as described in the [release signing guide](docs/release-signing.md).

> Release builds require explicit signing configuration. The signing guide covers key storage, Android update compatibility, and Windows Authenticode. The existing Android channel requires `-AllowLegacyDebugCertificate` and its pinned certificate fingerprint; signed Windows releases require a publisher certificate.

For Linux, build on an x86_64 Linux machine after installing the SDKs from the [Linux guide](docs/linux.md):

```sh
./scripts/build-linux-flatpak.sh
```

### Checks

```powershell
cd backend
uv sync --locked
uv run pytest
uv run alembic upgrade head
uv run alembic check

cd ../apps/margo_flutter
flutter pub get
flutter analyze
flutter test
```

Backend tests cover authentication, data isolation, recommendations, time zones, and synchronization conflicts. Client tests cover the action queue, account-free mode, connection failures, session lifecycle, updates, and adaptive layouts.

[CI](.github/workflows/ci.yml) runs backend tests with PostgreSQL, Flutter analysis and tests on Windows, and Windows and Android builds. The [Linux workflow](.github/workflows/linux-flatpak.yml) builds the Flatpak and checks installation and launch.

## Project structure

```text
apps/margo_flutter/    Flutter client: screens, local storage, and synchronization
backend/              FastAPI, recommendations, ingestion, migrations, and scheduler
docs/                 Technical guides
scripts/              Backend startup, client builds, and update preparation
packaging/windows/    Inno Setup installer configuration
packaging/flatpak/    Linux Flatpak packaging
.github/workflows/    CI checks and builds
```

| Layer | Technologies |
| --- | --- |
| Client | Flutter, Dart, Riverpod, go_router, Dio |
| On-device data | SQLite, secure token storage, persistent action queue |
| API | FastAPI, SQLAlchemy, Alembic, Argon2, revocable bearer sessions |
| Server data | PostgreSQL; SQLite for local development |
| Deployment | Docker Compose, Caddy, separate scheduler process |

The server assigns recommendations. The client stores downloaded cards and synchronizes actions through the API. Operation UUIDs, idempotent processing, and per-field versions handle retries and conflicts between devices. See the [synchronization guide](docs/synchronization.md).

## How it works

- The bundled catalog contains **116 Russian-language cards** with original short descriptions. The scheduler replenishes Russian and English content when stock runs low, provided a contact-bearing `WIKIMEDIA_USER_AGENT` is set in `.env`. See [catalog setup and monitoring](docs/classification.md#регулярное-пополнение-и-контроль-запаса).
- Downloaded cards remain available offline, and actions are queued for the next synchronization. Full articles open on Wikipedia over the internet.
- Android uses repeating local reminders. Windows schedules reminders 30 days ahead and extends the schedule when you open the app. Tapping a reminder opens Today; the article is fetched during synchronization. Delivery depends on OS settings and capabilities. Linux does not support daily reminders.
- Password recovery uses the Gmail API. See [account access](docs/account-access.md).

<details>
<summary>Custom fonts and compatibility with earlier versions</summary>

In **Profile → Appearance**, you can use a custom font up to 32 MB.

- **Windows:** choose **Open folder**, add a `.ttf` or `.otf` file to `%APPDATA%\dev.thoth\thoth\fonts`, then choose **Refresh font**. If several files are present, the most recently modified file is used. Remove the files and refresh to restore the default font.
- **Android:** use **Import font** or **Restore default font**.

The app adopted the name MARGO in version `0.3.0+6`. The Android application ID and signing identity, Windows AppId, storage keys, and existing database names remain unchanged for compatibility. The Windows CompanyName/ProductName fields retain their earlier values because plugins use them to locate the database and secure token. The executable is named `margo.exe`.

If an older installation uses a different server, synchronize any pending actions before updating. After the update, sign in to the account on your chosen server.

</details>

## Documentation

The following guides are currently in Russian:

- [Linux: installation, updates, and Flatpak builds](docs/linux.md)
- [Password recovery and session management](docs/account-access.md)
- [Android: installation, connection, and signing](docs/android.md)
- [Updates and release preparation](docs/updates.md)
- [Synchronization and conflict resolution](docs/synchronization.md)
- [Daily reminders and delivery behavior](docs/notifications.md)
- [Classification, Wikimedia ingestion, and attribution](docs/classification.md)
- [Flutter client structure](apps/margo_flutter/README.md)
- [Project concept](idea.md)
