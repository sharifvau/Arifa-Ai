# ARIFA ♥

A **living, full-screen AI agent** for **Emon Bhai** — Bangla voice, wake word,
screen vision, phone control, an editable multi-model brain, and a source
builder with AI self-review.

There is **no `.env`, no `bridge/`, no bundled API key and no bundled model
version** in this repository or in the APK.

---

## 1. The new home screen

The home screen is one full-screen experience, not a list of boring cards.

- **Top:** glowing `ARIFA` wordmark + a green `Online` dot.
- **Center:** a big animated ARIFA avatar — a cute Bangladeshi girl with long
  black hair, big eyes, a futuristic blue dress and a glowing arc-reactor
  necklace. She blinks, breathes, sways her hair and looks around while idle.
- **Bottom:** one large glowing **MIC** button, then exactly three small
  buttons: **Chat**, **Build APK**, **Settings**.
- **Chat** opens as a bottom sheet with quick chips; it never replaces the
  avatar screen.

### Avatar states

| State | Trigger | What she does |
|---|---|---|
| Happy | Idle / ready | Soft smile, slow breathing, occasional blink |
| Listening | Wake word or mic press | Leans forward, bright eyes, smile — *“Ji Emon Bhai”* |
| Speaking | TTS starts | Lips and hands move with the voice, head follows |
| Thinking | Command being processed | Looks up, finger on chin — *“Daran Emon Bhai, vabtesi...”* |
| Success | Build/fix finished | Jumps and claps — *“Hoye geche!”* |
| Sad / Error | Failure | Sorry face — *“Sorry Emon Bhai, ami thik kore dicchi”* |

Success and error reuse the happy and sad faces with different body motion.
The avatar is painted every frame with Flutter `CustomPainter`
(`lib/arifa_avatar.dart`) — no external image, Rive or 3D engine is required.

### Live background

`lib/live_background.dart` draws an animated dark-blue galaxy: drifting stars,
breathing central glow, moving cyan energy waves behind ARIFA, and a soft
music-visualizer bar row at the bottom. When she speaks or listens, the glow
gets stronger and the waves/visualizer move faster.

### App icon

A round premium launcher icon — dark-blue gradient, ARIFA's face inside a
glowing blue arc-reactor ring, neon `ARIFA` text — is generated locally:

```bash
python3 scripts/generate_icon.py
```

This writes PNGs into `android/app/src/main/res/mipmap-*/` and
`assets/icon/arifa_icon.png`. `AndroidManifest.xml` declares both
`android:icon="@mipmap/ic_launcher"` and
`android:roundIcon="@mipmap/ic_launcher_round"`.

---

## 2. Model system — fully editable, zero hardcoded versions

`models.json` is an **editable seed**, not the live catalog. On first launch
ARIFA copies it into Flutter Secure Storage (`model_catalog_v1`, with
`model_catalog_seed_version`). After that, every call reads the saved catalog
from `SettingsService.instance.models` at request time. Editing a model in the
app takes effect immediately — no rebuild, no source edit.

The seed contains exactly five starter rows with **empty IDs**:

| Name | Provider | ID |
|---|---|---|
| Gemini Latest | Gemini | _(you fill it)_ |
| Claude Latest | OpenRouter | _(you fill it)_ |
| GPT Latest | OpenRouter | _(you fill it)_ |
| Kimi Latest | OpenRouter | _(you fill it)_ |
| Qwen Latest | OpenRouter | _(you fill it)_ |

### Settings → AI Brain / Model Manager

- **Add New Model** / **Edit** / **Delete** any row.
- **Fetch Latest Models** pulls the live list from
  `https://openrouter.ai/api/v1/models`, with search, then adds your pick.
- **Set Default Model** chooses the first model tried.
- **Custom Model ID** with provider auto-detect (`gemini-…` → native Google,
  anything else → OpenRouter) or manual provider override. **Add & Use Now**
  makes it the default instantly.
- **Import / Export `models.json`** — export shares the current catalog;
  import replaces it from a picked JSON file.
- Every row shows its provider, saved ID and a `starter (editable)` marker.

Routing order in `lib/arifa_brain.dart`: default model first, then
vision-capable models when a screenshot is attached, then all other usable
models. A model is usable only if its ID is filled and its provider's key is
saved. If a call fails, ARIFA falls through to the next model.

Native Gemini calls Google directly; all other providers go through
OpenRouter. Only endpoints live in `lib/config.dart` — no keys, no model
slugs, no versions.

---

## 3. First-run setup

The first popup title is exactly:

> **Emon Bhai, Settings e giye API Key din**

Then tap **Settings e jaan** and:

| Field | What to paste / choose |
|---|---|
| Gemini API Key | Google AI Studio key (`AIza...`) |
| OpenRouter API Key | `sk-or-v1-...` — for Claude, GPT, Kimi, Qwen or any custom ID |
| Voice Selector | Bangladeshi Female Cute / Bangladeshi Male / English Female |
| Wake Word ON/OFF | `"Arifa"` bollei sunbe (foreground service) |
| AI Brain / Model Manager | Fill IDs, fetch, add, edit, set default |
| Save | Encrypts everything into Android Keystore via `flutter_secure_storage` |

Also allow **microphone** and **notifications**. The first `Arifa screen dekho`
triggers Android **MediaProjection** consent. For phone control, enable ARIFA's
Accessibility Service. Install Bangla voice data in Android TTS settings if
the accent sounds wrong.

---

## 3.1 WhatsApp Auto Reply (new)

Say **“Arifa WhatsApp auto reply ON koro”** / **“Arifa WhatsApp auto reply OFF koro”**.
The home screen shows a big **green dot + WA Reply ON** or **red dot + WA Reply OFF**;
tapping that pill toggles it too. No brain call, no delay.

### Setup (one time)

1. In **Settings → WhatsApp Auto Reply**, tap **Give notification access** and allow
   ARIFA to read notifications.
2. Tap **Give accessibility** and enable ARIFA's Accessibility Service so it can
   type into WhatsApp and tap Send.
3. Add names/numbers to **Kake reply dibo (Allow List)**. Nothing is read until
   auto reply is ON **and** at least one contact is allowed. `*` means everyone
   (only with the “Unknown person-ke fixed line reply” switch).

### How a reply happens

- `ArifaNotificationListener.kt` sees only allow-listed WhatsApp / WhatsApp
  Business **message notifications**, drops group summaries and “typing…”, and
  sends contact + text + notification key to Dart **on the device**.
- The instant local style brain writes a Bangla + English, human-sounding reply
  (e.g. `hi, kemon achos?`, `are ei to achi, ektu busy chilam, bol ki khobor?`,
  the exact work/APK busy line, and the unknown-sender line).
- A **0.5 s human typing beat** runs, then the accessibility service opens the
  exact chat from the notification's own PendingIntent, types the reply and
  taps Send. Local path: typically **under 1 second**. Optional cloud brain is
  time-boxed to 1.1 s with instant local fallback, so the total stays 1–2 s.
- Every attempt is written to the encrypted **“Kake ki reply dilam”** log in
  Settings (contact, incoming, reply, time, sent/failed, channel). Clear anytime.
- Ammu / Family (editable list) also raise a local notification:
  *“Emon Bhai, Ammu message dise, dekhen”*.

### Privacy switches (both OFF by default)

- **Use AI brain to compose reply** — sends the incoming message text and your
  saved style samples to your configured Gemini / OpenRouter model.
- **Send via WhatsApp Business Cloud API** — uses your own token + Phone Number
  ID and sends the reply through Meta's servers.

Leave both OFF and every message stays on your phone. Your own talking style is
learned from style samples you type in Settings plus your last local replies —
ARIFA does not read your WhatsApp chat history.

---

## 4. What is real and what is not

| Request | Reality | What ARIFA does |
|---|---|---|
| “Build the APK on my phone” | **Impossible.** A phone app has no Flutter SDK, Android SDK, JDK or Gradle. | Generates a complete Flutter project, runs AI review, self-repairs, and shares a **source zip**. The message says “source zip ready”, never “APK ready”. |
| “Always listening” | Possible with a foreground service + notification; OEM battery managers may still kill it. | Native Kotlin `ArifaService` + `START_STICKY` + boot receiver + continuous `SpeechRecognizer`. |
| “Turn WiFi on/off directly” | Android 10+ blocks this for normal apps. | Opens WiFi Settings and tries an accessibility tap (best effort). |
| “Use a 3D/Rive avatar” | Not bundled here. | A code-drawn 2D avatar with all five expressions and smooth animation. |

To turn the source zip into an APK, build **outside the app** on a machine
with Flutter + Android SDK + JDK (desktop or Termux).

---

## 5. Build instructions

This repo contains Dart sources, native Android overrides, `models.json` and
build scripts. Generate the standard Flutter scaffold first:

```bash
cd arifa
bash scripts/bootstrap.sh
```

Bootstrap runs `flutter create --org com.example --project-name arifa .`,
restores `lib/` and Android overrides, then runs `flutter pub get`.

### Termux (aarch64)

```bash
pkg update -y
pkg install -y clang cmake ninja git openjdk-17 python3
bash scripts/termux_config.sh
bash scripts/build_apk.sh
```

`build_apk.sh` runs:

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons
```

Output: `build/app/outputs/flutter-apk/app-release.apk`.

On desktop:

```bash
bash scripts/bootstrap.sh
bash scripts/build_apk.sh
```

> This workspace had **no Flutter / Android SDK**, so only Dart parse checks,
> shell syntax checks and Python compile checks were run here. A compiled APK
> must be produced externally.

---

## 6. What to say

| Say | What happens |
|---|---|
| `Arifa` | Wakes: “হ্যাঁ Emon Bhai, বলুন?” |
| `Arifa screen dekho` | Screenshot → vision model → Bangla explanation; auto-fixes a generated app if an error is visible. |
| `Arifa calculator APK banaw` | Generate code → AI review → self-repair → **source zip** → share sheet + notification. |
| `Arifa WhatsApp message 017... hello` / `Arifa open YouTube` / `Arifa wifi on` / `Arifa call 017...` / `Arifa play Bangla hits` | Android intents + accessibility. |
| `Arifa WhatsApp auto reply ON/OFF koro` | Instant local toggle — green/red home dot, allow-listed replies start/stop. |
| `Arifa settings` | Opens Settings / Model Manager. |
| Anything else | Routed through your saved models with failover. |

Every code reply has a **Copy** button. Chat history stays in memory.

---

## 7. Files

```
lib/main.dart                 full-screen avatar UI + command orchestration
lib/arifa_avatar.dart          animated 2D ARIFA (happy/listening/speaking/thinking/sad)
lib/live_background.dart      galaxy, stars, waves, visualizer
lib/settings_screen.dart      keys, voice, wake, Model Manager, import/export
lib/settings_service.dart     secure storage, model catalog persistence, VoiceChoice
lib/model_entry.dart          ModelEntry / ModelProvider / ModelCatalog
models.json                   editable seed catalog (5 starter rows, empty IDs)
lib/arifa_brain.dart          dynamic routing, failover, JSON generation, review
lib/voice_service.dart        Settings-driven TTS/STT + wake matching
lib/screen_service.dart       MediaProjection -> vision -> error report
lib/apk_builder.dart          source generation + review + zip packaging
lib/phone_control.dart        intents + accessibility wrappers
lib/notification_listener.dart native notification listener bridge + permission helpers
lib/whatsapp_service.dart     accessibility typing/send + optional Business Cloud API
lib/auto_reply_service.dart   instant style brain, allow list, queue, encrypted reply log
lib/background_service.dart   native channel for FGS/screenshot events
lib/config.dart               endpoints only — no keys, no model versions
lib/models.dart               chat/code data classes
android/.../ArifaService.kt            wake word + screenshot foreground service
android/.../ArifaAccessibilityService.kt UI taps + WhatsApp composer typing
android/.../ArifaNotificationListener.kt allow-listed WhatsApp notification reader
android/.../MainActivity.kt            intents + MediaProjection consent
scripts/generate_icon.py       local PNG launcher-icon generator
scripts/bootstrap.sh           flutter create + restore custom files
scripts/termux_config.sh       Termux/aarch64 Gradle tweaks
scripts/build_apk.sh           real external APK build
```

---

## 8. Known limits

- OEM battery optimizers may kill the listening service. Disable battery
  optimisation for ARIFA and enable auto-start.
- `SpeechRecognizer` needs Google's speech service and network access.
- WhatsApp auto-send depends on its current UI; the accessibility tap may miss.
- Auto Reply needs both Notification access and Accessibility enabled. WhatsApp
  sometimes changes notification text/composer IDs; when a send fails, the
  reason is recorded in the **Kake ki reply dilam** log. Cloud options are OFF
  by default so message text stays on the device until you opt in.
- OpenRouter model slugs change. Use **Fetch Latest Models** or a custom ID if
  one returns 404 — nothing needs to be edited in source.
- API keys and the model catalog live only on your device. Wiping app data
  removes them; the seed rows will be recreated on next launch.
