# Learnyst Multi-Tenant Mobile Build & Release Automation Pipeline

Automates the white-label release process for Learnyst's mobile apps: pulls a
client's branding/config out of `clients.json`, stamps it into a dummy Android
project, "builds" an APK/AAB, logs every step, and pings a release webhook
(Slack / App Center style) when it's done.

## Project layout

```
learnyst-pipeline/
├── build_and_release.sh          # master script
├── config/
│   └── clients.json              # per-client, per-environment configuration
├── templates/
│   └── mobile-app-template/      # dummy Android project with __PLACEHOLDER__ tokens
│       └── app/
│           ├── build.gradle
│           └── src/main/
│               ├── AndroidManifest.xml
│               └── res/values/{strings.xml,colors.xml}
├── assets/logos/                 # dummy client logo files referenced by clients.json
├── builds/                       # timestamped build logs (generated)
│   └── 2026-09-17_AcademyX.log
└── output/                       # per-release stamped project + artifacts (generated)
    └── AcademyX_production_2.1.0/
        ├── app/...                                    (branded project copy)
        ├── AcademyX-2.1.0-production.apk               (dummy artifact)
        ├── AcademyX-2.1.0-production.aab                (dummy artifact)
        └── webhook_payload.json                          (if --mock-webhook)
```

## Usage

```bash
./build_and_release.sh --client "AcademyX" --env "production" --version "2.1.0"
```

Flags:

| Flag                | Required | Description |
|---------------------|----------|-------------|
| `--client <name>`   | yes      | Must match a `"name"` in `config/clients.json` |
| `--env <env>`       | yes      | Must exist under that client's `"environments"` object |
| `--version <x.y.z>` | yes      | Semantic version, used as `versionName` (also derives `versionCode`) |
| `--mock-webhook`    | no       | Skip the real network call; write the payload to `output/<slug>/webhook_payload.json` instead |
| `--strict-webhook`  | no       | Treat a failed webhook call as a fatal error (exit 6) instead of a warning |
| `-h, --help`        | no       | Show usage |

## What the script does

1. **`parse_args`** — validates required flags and that `--version` looks like `x.y.z`.
2. **`check_prerequisites`** — confirms `git`, `curl`, `jq`, `clients.json`, and the
   project template all exist before touching anything.
3. **`validate_client_config`** — looks the client up in `clients.json` with `jq`,
   confirms the requested environment exists, and confirms every required field
   (`app_name`, `bundle_id`, `theme_color`, `logo_path`, `webhook_url`,
   `environments.<env>.api_base_url`) is present and non-empty.
4. **`prepare_workspace`** — copies `templates/mobile-app-template` into
   `output/<client>_<env>_<version>/` and uses `sed` to replace every
   `__PLACEHOLDER__` token (app name, bundle ID, API URL, theme color, logo
   path, version, version code) in the copied files.
5. **`simulate_build`** — logs each build step to `builds/<date>_<client>.log`
   (and stdout), then writes dummy `.apk` / `.aab` files and a SHA256 checksum.
6. **`notify_webhook`** — POSTs a JSON payload to the client's webhook URL (or
   writes it to a file with `--mock-webhook`). A webhook failure is a warning,
   not a hard stop, unless `--strict-webhook` is set.

## Error handling

The script runs under `set -euo pipefail` with an `ERR` trap that reports the
failing line number, plus explicit checks with dedicated exit codes:

| Exit code | Meaning |
|-----------|---------|
| `1` | Bad/missing CLI arguments |
| `2` | Missing dependency (`git`/`curl`/`jq`) or missing `clients.json`/template |
| `3` | Client name or environment not found in `clients.json` |
| `4` | Client config exists but is missing a required value |
| `5` | Build artifacts failed to write correctly |
| `6` | Webhook notification failed (`--strict-webhook` only) |

`config/clients.json` ships with an `IncompleteClient` entry (empty
`bundle_id`) specifically to exercise the exit-code-4 path.

## Try it

```bash
# Successful multi-tenant builds
./build_and_release.sh --client "AcademyX"   --env "production" --version "2.1.0" --mock-webhook
./build_and_release.sh --client "SkillForge" --env "staging"    --version "1.4.2" --mock-webhook
./build_and_release.sh --client "BrightMind" --env "production" --version "3.0.1" --mock-webhook

# Failure paths
./build_and_release.sh --client "GhostAcademy"    --env "production" --version "1.0.0"   # exit 3, unknown client
./build_and_release.sh --client "IncompleteClient" --env "production" --version "1.0.0"   # exit 4, missing bundle_id
./build_and_release.sh --client "AcademyX" --env "production" --version "2.1"             # exit 1, bad version format
```

Drop `--mock-webhook` to have the script actually `curl` the client's real
Slack/App Center webhook URL once you swap in real endpoints in
`config/clients.json`.

## Extending toward a real pipeline

- Replace the dummy `.apk`/`.aab` writes in `simulate_build` with real
  `./gradlew assembleRelease` / `bundleRelease` calls.
- Replace the `sed` placeholder stamping with Gradle product flavors, or a
  proper templating tool, once the dummy project becomes a real one.
- Point `webhook_url` at a real Slack Incoming Webhook or App Center API
  endpoint per client/environment.
