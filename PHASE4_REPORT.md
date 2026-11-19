# ARIFA — Phase 2/3/4 Report (Emon Bhai)

Audit: `AUDIT.md` (2 Critical, 20 High, 33 Medium, 10 Low). HEAD `ee70e5d`;
সব fix **uncommitted** — কোনো push হয়নি।

## ১. কী ঠিক হয়েছে

- **Critical ২/২:** wake-word-এর জন্য `<queries>`-এ `RecognitionService` যোগ; `bootstrap.sh`-এ সঠিক org (`com.arifa.app`), সঠিক Kotlin path, guarded backup/restore, `--platforms android`।
- **High ২০/২০:** mic permission আগে + FGS safe start + `wake_enabled` + `START_NOT_STICKY`; SpeechRecognizer main thread; destroy/recreate + exponential backoff; capture-এর আগে mic pause; `MediaProjection.Callback.onStop()`; সব capture exit-এ wake restore; screenshot-এ `bytes.length`; brain failover-এ ৩ মডেল/২৫ s deadline + auth-stop; AI review optional; empty seed overwrite ঠেকানো; `*` wildcard সরিয়ে aladা `reply_unknown` pref; sent-key দিয়ে duplicate reply ঠেকানো; accessibility fallback safe + foreground verification; token obscure; avatar/background repaint; workflow `--no-pub`; release signing config (`android/key.properties`, debug fallback); wrapper/styles-এর জন্য deterministic scaffold preflight।
- **Medium ৩১/৩৩ + ১ আংশিক:** corrupt catalog backup, import validation, provider reject, vision default false, init guard, JSON shape guard, coding-before-vision, actionable errors, status-specific messages, error cap, `mounted` guard, routing order, failure≠success wording, dedup/prune, group messages drop, cloud recipient loop, error sanitization, process timeouts, package sanitization, duplicate-path dedupe, ZIP sink close, lazy phone/SMS + confirm dialog, important-contact debounce persist, queue clear on disable, partial-wake dedup, capture watchdog, boot notification, narrowed accessibility, async dispose observed, `.gitignore`-এ key.properties — সব done। **M17 আংশিক** (নিচে)।
- **Low ৯/১০:** blink timer cleanup, gender keywords, labelled timeouts, empty-ID guard, buildMode validation, aapt2 path guard, `avoid_print: ignore` removal, pubspec comments, WAKE_LOCK removal — done। **L10 বাকি** (নিচে)।

Exact popup title অক্ষত আছে: `Emon Bhai, Settings e giye API Key din` (`lib/main.dart:211`)।
কোনো API key/secret হার্ডকোড করা হয়নি; `android/key.properties` gitignored।

## ২. বাকি আইটেম ও কারণ

- **M17 — content-logging opt-in:** log-এ `incoming`/`reply` এখন ২০০ characters-এ truncate হয় (`_logText`), অর্থাৎ "full body retain" সমস্যা সমাধান। পুরো opt-in toggle-এর জন্য `SettingsService`-এ নতুন key + `saveAll`/`saveWhatsApp` signature + `settings_screen` UI wiring বদলাতে হতো — Flutter না থাকায় টাইপ-চেক করা যাচ্ছে না, তাই risk কমিয়ে এখানেই রাখা হয়েছে। হাতে audit/verification হলে toggle যোগ করা যাবে।
- **M32 — R8 minify/obfuscate:** Flutter/Android SDK ছাড়া release build ও ProGuard keep rules verify করা যাচ্ছে না। অদৃশ্যভাবে `minifyEnabled true` চালু করলে plugin/reflection class কেটে যেতে পারে। Termux script ইচ্ছাকৃতভাবে minify off রাখে (কম RAM)। তাই defer।
- **L10 — wake-এ beep/vibration:** নতুন `VIBRATE` permission + native `Vibrator`/`ToneGenerator` + preference যোগ করতে হয়; এটা নতুন আচরণ, বর্তমান TTS ইতিমধ্যে শোনা যায়। Feature-প্রিজার্ভেশন prioritise করে defer।
- **H20 বিকল্প:** wrapper JAR / `styles.xml` commit না করে CI (`build.yml`) ও `scripts/build_apk.sh`-এ deterministic `flutter create` preflight রাখা হয়েছে — fresh checkout-এ build চলে।

## ৩. Verify — কী চলেছে, কী চলেনি

**চলেছে (pass):**
- `dart format --output=none` — **সব ১৮টি `lib/*.dart` + ৪টি `test/*.dart` parse OK** (শুধু parse; type-check নয়)।
- `bash -n` — `bootstrap.sh`, `build_apk.sh`, `termux_config.sh` OK।
- XML well-formedness — `AndroidManifest.xml`, `strings.xml`, `accessibility_service_config.xml` OK।
- YAML — workflow নিজে পড়ে step order/mandated settings মিলিয়ে দেখা হয়েছে (`pyyaml` ছিল না)।
- Kotlin brace/paren balance — ৪টি ফাইলে ০; `MainActivity.kt`-এ HEAD-এও একই imbalance আছে (pre-existing, regex/string false-positive) — আমার edit নতুন করে আনেনি।
- Standalone `dart` দিয়ে pure logic-এর **১৮টি assertion pass**: catalog parse/provider/vision/round-trip + allow-list normalize/match/wildcard-off।
- `models.json`: ৫টি model, সব starter, সব empty ID — validation-এর সাথে মেলে।

**চলেনি (Flutter SDK নেই — pass Claim করছি না):**
`flutter pub get`, `flutter analyze` (০ error claim করা যাচ্ছে না), `flutter test` (নতুন ৪টি test file চলেনি), `flutter build apk` / `bash scripts/build_apk.sh`, device-এ install/mic/notification/WhatsApp manual test।
`command -v flutter/gradle/adb` → **NOT FOUND**; শুধু `dart 3.14.1` ও `java 21` আছে।

**নতুন tests:** `test/model_catalog_test.dart`, `test/brain_routing_test.dart` (fake `http.Client` দিয়ে default-first failover, cap, auth-stop, vision order), `test/allow_list_test.dart`, `test/wake_word_test.dart` — কোনো নতুন dependency যোগ হয়নি (`flutter_test` আগে থেকেই dev_dependency)।

## ৪. ম্যানুয়াল স্টেপ (Emon Bhai)

1. **API Key:** অ্যাপ খুলুন → Settings → Gemini API Key (Google AI Studio) এবং/অথবা OpenRouter Key দিন → Save। Model Manager-এ `Fetch Latest Models` দিয়ে একটা মডেল অ্যাড করে **Default** সেট করুন (seed rows-এ ID খালি — ID পূরণ করতে ভুলবেন না)। WhatsApp Cloud API ব্যবহার করলে Business Cloud Token + Phone Number ID-ও সেখানেই দিন ( token obscure করা আছে)।
2. **Permissions:** প্রথম ব্যবহারে Mic allow করুন; Settings-এ **Notification access** (WhatsApp auto-reply-র জন্য) ও **Accessibility** (reply type/send-এর জন্য) চালু করুন। Phone/SMS permission শুধু যখনই কল/SMS কমান্ড দিবেন, তখনই চাইবে — Each action-এর আগে **Confirm** dialog আসবে।
3. **Battery optimisation off:** Phone Settings → Apps → ARIFA → Battery → **Unrestricted / Don't optimize** (OEM-এ "No restrictions")। Battery Saver চালু থাকলে wake-word/background listener বন্ধ হতে পারে। Auto-reply ও wake word চালু রাখতে ARIFA-কে background-এ চলার অনুমতি দিন।
4. **APK build:**
   - Flutter SDK থাকলে: `flutter pub get` → `flutter build apk --debug` (CI-ও এটাই করে; artifact `arifa-apk`)।
   - Termux-এ: `bash scripts/build_apk.sh` (scaffold+icon auto-regenerate)।
   - Real signed release: `android/key.properties` তৈরি করে `flutter build apk --release`। Na keystore, na key.properties commit করবেন।

## ৫. Git / token

Push করা হয়নি। আগে **পুরনো GitHub token টি revoke/replace করুন** (একবার expose হয়েছিল) — তারপরই commit/push করুন।
