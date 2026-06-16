# flutter_build_release

A CLI tool that builds your Flutter app (APK + IPA) and distributes it — uploads APKs to Google Drive and IPAs to Diawi — all from one command.

---

## What it does

| Step | What happens |
|------|-------------|
| 1 | Detects your project automatically, then asks a few questions |
| 2 | Runs `flutter build apk` or `flutter build ios` for you |
| 3 | For Android: uploads the APK to a Google Drive folder you choose |
| 4 | For iOS: archives and exports the IPA, then uploads to Diawi and copies the link to your clipboard |

Answers are remembered between runs — you only type things once.

---

## Before you start — Setup Checklist

Go through this once. After setup, the tool works every time with just `flutter_build_release`.

---

### 1. Install Dart

```bash
# Check if you already have it
dart --version

# If not, install Flutter (includes Dart)
# https://flutter.dev/docs/get-started/install
```

---

### 2. Install this tool (one command)

Download and run the install script — it activates the package **and** adds it to your PATH automatically:

```bash
curl -fsSL https://raw.githubusercontent.com/Muhammad-Shadab/flutter_build_release/main/install.sh | bash
```

Or if you cloned the repo:

```bash
bash install.sh
```

That's all. No manual PATH editing needed.

---

### 3. Google Drive setup (Android upload only)

You need two things: **rclone** installed and a **Drive folder ID**.

#### Install rclone

```bash
brew install rclone
```

#### Connect rclone to your Google Drive

```bash
rclone config
```

Follow the prompts:
1. Press `n` for new remote
2. Name it `gdrive`
3. Choose `drive` (Google Drive)
4. Leave client ID and secret blank (just press Enter)
5. Choose scope `1` (full access)
6. Leave root folder blank
7. Press `n` for advanced config
8. Press `y` to use auto config — a browser window opens, log in with your Google account
9. Press `n` (not a team drive)
10. Press `y` to confirm

#### Get your Drive folder ID

Open the Google Drive folder where you want APKs uploaded, then look at the URL:

```
https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz1234567
                                        ↑ this part is your folder ID
```

Copy the ID after `/folders/`.

---

### 4. Diawi token (iOS upload only)

Diawi lets you share IPAs with testers via a link.

1. Go to [diawi.com](https://www.diawi.com) and create a free account
2. Go to **Account → API Access Tokens**
3. Create a token and copy it

---

### 5. Apple Team ID (iOS builds only)

1. Go to [developer.apple.com](https://developer.apple.com)
2. Sign in → click your name top-right → **Membership details**
3. Copy the **Team ID** (looks like `ABCD1234EF`)

---

### 6. Xcode command-line tools (iOS only)

```bash
xcode-select --install
```

---

## Quick start

Run the tool from inside your Flutter project directory:

```bash
cd /path/to/your/flutter/app
flutter_build_release
```

The tool detects your project automatically and reads the app name from `pubspec.yaml`.

**First run** (building both platforms with Drive + Diawi upload):

```
✓  Flutter project detected: /Users/john/projects/my_app

  What do you want to build?
  1) Android only  — generates APK
  2) iOS only      — generates IPA
  3) Both          — APK + IPA

  Enter choice [1/2/3]: 3

  App name [MyApp]:                    ← detected from pubspec.yaml, press Enter

  Upload APK to Google Drive? [y/N]: y

  Google Drive folder ID: 1AbCdEfGh...

  Build flavour:
  1) dev
  2) prod
  3) uat

  Enter choice [1/2/3]: 1

  Apple Developer Team ID: UC2HYA24R2

  Upload IPA to Diawi? [y/N]: y

  Diawi API token: abc123...

  ╔══════════════════════════════════════════════╗
    Build Summary
  ╚══════════════════════════════════════════════╝

  Platform      Android + iOS
  App dir       /Users/john/projects/my_app
  App name      MyApp

  Android
    Drive upload  Yes
    Flavour       dev
    Remote        gdrive
    Folder ID     1AbCdEfGh...

  iOS
    Team ID       UC2HYA24R2
    Scheme        Runner
    Export        development
    Diawi upload  Yes

  Press Enter to start the build, or Ctrl+C to cancel...
```

**Every run after that** (all values are remembered):

```
✓  Flutter project detected: /Users/john/projects/my_app

  Enter choice [1/2/3] (last: 3): ↵
  App name [MyApp]: ↵
  Upload APK to Google Drive? [y/N]: y
  Enter choice [1/2/3] (last: 1): ↵
  Apple Developer Team ID [UC2HYA24R2]: ↵
  Upload IPA to Diawi? [y/N]: y
  Diawi API token [abc123...]: ↵
  → summary → Enter → build starts
```

At the end, testing URLs are shown together:

```
  Android APK:
  https://drive.google.com/file/d/...

  iOS IPA (Diawi):
  https://i.diawi.com/AbCdEf
```

The Diawi link is also copied to your clipboard automatically on macOS.

---

## Saved configuration

After your first run, answers are saved to:

```
<your-app-dir>/.flutter_build_release_config.json
```

This file stores your folder ID, team ID, app name, and other settings so you don't retype them each run.

> **Important:** Add this file to your `.gitignore` to avoid committing credentials:
>
> ```
> echo ".flutter_build_release_config.json" >> .gitignore
> ```

---

## Non-interactive mode (for CI / scripts)

You can skip all prompts by passing flags:

```bash
flutter_build_release \
  --platform both \
  --app-dir /path/to/my_app \
  --app-name MyApp \
  --team-id YOUR_TEAM_ID \
  --diawi-token YOUR_DIAWI_TOKEN \
  --upload-drive \
  --drive-folder-id YOUR_DRIVE_FOLDER_ID \
  --flavour prod
```

You can mix flags and prompts — any flag you omit will be asked interactively.

---

## All flags

| Flag | Description | Default |
|------|-------------|---------|
| `--platform`, `-p` | `android`, `ios`, or `both` | prompted |
| `--app-dir`, `-d` | Path to Flutter app (folder with pubspec.yaml) | auto-detected from CWD |
| `--app-name`, `-n` | Label used in output file names | detected from pubspec.yaml |
| `--upload-drive` | Upload APK to Google Drive | prompted |
| `--drive-folder-id` | Google Drive folder ID | prompted |
| `--flavour`, `-f` | `dev`, `prod`, or `uat` | prompted |
| `--rclone-remote` | rclone remote name | `gdrive` |
| `--team-id`, `-t` | Apple Developer Team ID | prompted |
| `--scheme` | Xcode scheme | `Runner` |
| `--export-method` | `development`, `release-testing`, `app-store` | `development` |
| `--diawi-token` | Diawi API token | prompted |
| `--help`, `-h` | Print usage | |

---

## Google Drive folder structure

APKs are organized automatically inside your chosen folder:

```
<your-drive-folder>/
└── dev/
    └── 2026/
        └── June/
            └── MyApp_June_2026_03-45-PM.apk
```

---

## iOS export methods

| Value | Use case |
|-------|----------|
| `development` | Xcode auto-manages profiles; works with Diawi |
| `release-testing` | Ad Hoc / TestFlight internal testing |
| `app-store` | App Store submission |

---

## License

MIT
