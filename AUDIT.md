# ARIFA-Ai — Phase 1 Audit

Audit date: 2026-11-19. Auditor role: senior Flutter + Android (Kotlin) engineer.
Scope: every `lib/*.dart`, `android/**/*.kt`, `AndroidManifest.xml`, all gradle files,
`pubspec.yaml`, `models.json`, `scripts/*.sh`, `.github/workflows/*.yml` plus directly
related config (`analysis_options.yaml`, `.gitignore`, `README.md`, Android resources).

**No source code was changed in Phase 1.** Every finding below was re-read against the
current files on disk (HEAD `ee70e5d`); subagent claims that did not survive verification
are listed at the end under "Rejected / not confirmed".

Severity scale: **Critical** = feature is broken / build cannot start; **High** = privacy,
security, data-loss or severe battery/battery-loop regression; **Medium** = wrong behaviour
or latent crash with a workaround; **Low** = hygiene / minor.

---

## Critical

### C1. `android/app/src/main/AndroidManifest.xml:17-25` — `<queries>` lacks RecognitionService
- **What is wrong:** The package-visibility `<queries>` block declares only launcher apps and WhatsApp. It does not declare `<intent><action android:name="android.speech.RecognitionService"/></intent>`.
- **Why:** `pubspec.yaml:20` pins `speech_to_text: 7.0.0` and `android/app/build.gradle:40` sets `targetSdk = 34`. From SDK 30 the plugin needs this app-side query; the plugin's own manifest is empty, so manifest merge will not add it. `SpeechRecognizer.createSpeechRecognizer(this)` in `ArifaService.kt:135` then fails to find a recognition service → the primary wake-word feature is dead on the target SDK.
- **Fix direction:** Add the `android.speech.RecognitionService` intent query inside the existing `<queries>` block.

### C2. `scripts/bootstrap.sh:24,27,31-32` — restores Kotlin from a directory that does not exist
- **What is wrong:** Script runs `flutter create --org com.example` (`:24`), makes `android/app/src/main/kotlin/com/example/arifa` (`:27`), then copies `.../com/example/arifa/*.kt` (`:31-32`). Tracked Kotlin files live in `android/app/src/main/kotlin/com/arifa/app/arifa/` (namespace/applicationId `com.arifa.app.arifa`, `app/build.gradle:22,38`).
- **Why:** The glob matches nothing; with `set -euo pipefail` (`:3`) `cp` aborts the bootstrap on a fresh checkout. `--org com.example` also conflicts with the real app id.
- **Fix direction:** Use `--org com.arifa.app` and restore from `com/arifa/app/arifa/*.kt`, or discover the generated package directory instead of hard-coding.

---

## High

### H1. `scripts/bootstrap.sh:10-11` — cannot bootstrap when `android/` is absent
- **What:** `cp -a android/. "$TMP/android/"` runs unconditionally; if `android/` is missing, `set -e` aborts before `flutter create` (`:24`) can regenerate it.
- **Why:** README presents bootstrap as the scaffold-generation entrypoint, but it can only repair an existing tree. Fresh clone with no `android/` → immediate failure.
- **Fix:** Guard the copies (`[ -d android ] && cp ...`) and document that bootstrap repairs/regenerates.

### H2. `android/app/src/main/kotlin/com/arifa/app/arifa/ArifaService.kt:81-89,127-133` — mic FGS started before permission check; sticky restart ignores `wake_enabled`
- **What:** `onStartCommand()` starts `FOREGROUND_SERVICE_TYPE_MICROPHONE` FGS (`:86`) before `RECORD_AUDIO` is checked (`:128-133`); `startFg()` (`:92-99`) has no try/catch. Any non-`ACTION_CAPTURE` intent, including the `null` intent on a sticky restart, starts wake listening; returns `START_STICKY` (`:89`) without reading the persisted `wake_enabled` flag (`MainActivity.kt:383-386`, `BootReceiver.kt:18-22`).
- **Why:** Android 14+ throws `SecurityException` starting a microphone FGS without mic access → crash loop. Sticky restart bypasses the user's OFF setting → always-on mic without consent, privacy + battery regression.
- **Fix:** Check `RECORD_AUDIO` before `startFg()`, wrap FGS start, handle `intent == null`, read `wake_enabled` and `stopSelf()`/`START_NOT_STICKY` when disabled.

### H3. `ArifaService.kt:76-77,134-135,177-182` — SpeechRecognizer created/driven off the main thread
- **What:** `HandlerThread("ArifaWakeThread")` (`:76-77`); `SpeechRecognizer.createSpeechRecognizer(this)` (`:135`) and `recognizer?.startListening(intent)` (`:178`) run on that background handler.
- **Why:** The SpeechRecognizer API requires main-thread calls; off-thread use gives inconsistent callbacks, recognizer failures or crashes.
- **Fix:** Use `Handler(Looper.getMainLooper())` for recognizer creation and start/stop.

### H4. `ArifaService.kt:143-146,204-214` — every error restarts in 900 ms with no destroy/backoff
- **What:** `onError` emits and calls `scheduleRestart()`; it posts `startWakeListening()` after fixed `900 ms` and never calls `recognizer.destroy()` before reuse. All error classes are treated identically.
- **Why:** A permanent failure becomes a tight retry loop → battery drain and `wake_error` spam; a recognizer stuck in a failed state is reused.
- **Fix:** Distinguish transient vs terminal errors, destroy+recreate recognizer on error, exponential backoff with cap.

### H5. `ArifaService.kt:82-88,204-214,216-226` — FGS switched to `mediaProjection` while mic recognizer still active
- **What:** `ACTION_CAPTURE` calls `startFg(FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION, ...)` (`:83`) but nothing stops `startWakeListening()`/the queued restart (`:204-214`) before capture.
- **Why:** The service keeps using the microphone while advertising only `mediaProjection`, conflicting with Android 14 type-specific while-in-use rules → mic denied or FGS type mismatch.
- **Fix:** Pause/stop recognizer before capture, resume wake mode after; or start with both declared types if concurrent use is genuine.

### H6. `ArifaService.kt:216-243` — no `MediaProjection.Callback.onStop()`
- **What:** `projection` obtained at `:225-226`, stopped only inside the image callback `finally` (`:291-294`). No `registerCallback` for user revocation.
- **Why:** If the user turns off screen capture via system UI, the virtual display/image reader stay active and the pending MethodChannel result in `MainActivity.kt:153-179` is never completed (UI hangs).
- **Fix:** Register a projection callback; on `onStop()` release reader/display, `finishCapture(null)`, reset service.

### H7. `ArifaService.kt:220-230` vs `:295-296` — early capture failures never restore wake listening
- **What:** Invalid consent (`:220-222`) and `getMediaProjection()` failure (`:225-229`) call `finishCapture(null)` and return. Only the success image path (`:295-296`) restarts the wake service.
- **Why:** After a failed/denied screenshot the service stays in `ACTION_CAPTURE` with the wrong FGS type and wake detection stops.
- **Fix:** Centralize capture cleanup so every exit path (success/denial/exception/stop) restores mic wake mode.

### H8. `lib/screen_service.dart:36-43` (+ `lib/main.dart:460-461`) — `$bytes` interpolates the entire byte list
- **What:** `'$bytes bytes'` stringifies the whole `List<int>`; text claims "আবার চেষ্টা করছি" but no retry happens.
- **Why:** A >4 MB screenshot becomes a multi-megabyte chat string that is also passed to TTS (`main.dart:461`) → UI freeze / memory spike / unusable speech, plus a misleading message.
- **Fix:** Use `bytes.length`; remove the false retry claim (native already downsamples to 1280px/quality 80 in `ArifaService.kt:259-272`).

### H9. `lib/arifa_brain.dart:77-99,203-219,358-369,461-474` — unbounded model failover (90 s × N)
- **What:** `_modelsFor()` returns every usable catalog model; `ask()`/`generateApp()` try them sequentially with a 90 s timeout each. Settings can import hundreds of rows. `apk_builder.dart` repeats generate+review up to 2 attempts.
- **Why:** A bad key/404 can block for N×90 s (minutes to hours); a single user command appears hung.
- **Fix:** Global deadline/cap (e.g. 3 models or ~20 s total), stop early on auth errors, dedupe errors.

### H10. `lib/apk_builder.dart:55-58,89-93` — AI review failure aborts the whole pipeline
- **What:** `reviewApp()` is awaited with no try/catch in both the Flutter-missing fallback (`:56`) and each attempt (`:90`), yet `reviewApp()` calls `ask()` which throws when all models fail.
- **Why:** Even after successful `generateApp()` the user gets no source zip — build/review failure is reduced to a generic "একটু সমস্যা হলো".
- **Fix:** Treat review as optional: `try/catch`, log review failure, continue to `saveSourceZip()`.

### H11. `lib/settings_service.dart:176-210` (+ `:212-219`, `:233-240`) — empty seed overwrites stored catalog
- **What:** When secure storage has no catalog, `saveCatalog(await _readSeed())` is unconditional (`:179-181`) even if `_readSeed()` returned `ModelCatalog.empty()` (asset missing/malformed). It also writes `_kModelsSeed`, so the later `seed.schemaVersion > storedVersion` migration check (`:195`) never re-triggers.
- **Why:** A transient asset/read failure permanently leaves an empty catalog with no seed recovery.
- **Fix:** Only save when `seed.models.isNotEmpty`; leave the seed-version key unset otherwise. Also back up a corrupt stored catalog instead of replacing it with empty (see M1).

### H12. `lib/auto_reply_service.dart:444-453` + `lib/notification_listener.dart:98-120,182-184` — `*` wildcard defeats the allow-list
- **What:** `_matches()` returns true for `'*'` (`auto_reply_service.dart:451`); `configure()` injects `'*'` into the native allow list when `replyUnknown` is on (`notification_listener.dart:182-184`); native also accepts `it == '*'` (`:120`); Settings offers `*` (`settings_screen.dart:860-864`).
- **Why:** The documented "only allow-listed contacts are read/replied to" promise is bypassed; every notification is read and, with `replyUnknown`, replied to.
- **Fix:** Disallow `*` in custom rules/allow list, or require an explicit separate confirmation; keep unknown-reply as a distinct, clearly-labelled decision rather than a wildcard.

### H13. `lib/notification_listener.dart:89-121,146-159` + `lib/auto_reply_service.dart:204-217` — pending queue replay causes duplicate replies
- **What:** Every event is persisted (`:157`); the queue is cleared only at the start of the next `drainPending()` (`:97`) — there is no acknowledgement after a successful reply.
- **Why:** If the app dies after replying but before the next drain, the same message is replayed and answered again on restart.
- **Fix:** Remove a pending item once its reply succeeds, or keep a sent-key set and skip fingerprint keys on replay (native `notification.key` is available).

### H14. `lib/whatsapp_service.dart:83-100` — accessibility fallback can abort before logging and type into the wrong app
- **What:** `_method.invokeMethod('openWhatsApp')` (`:85`) sits outside the try block; `typeWhatsAppReply` (`:90`) is attempted after a fixed 80 ms regardless of whether the intended chat opened.
- **Why:** A `PlatformException` propagates to `_handleMessage`, skipping the log insert (`auto_reply_service.dart:271-285`); if opening failed, the reply text can be injected into whatever app is foregrounded.
- **Fix:** Wrap the fallback open in try/catch; verify the foreground chat is WhatsApp before typing; always record the outcome.

### H15. `lib/settings_screen.dart:1082-1086` (+ `:1162-1172`) — WhatsApp Business token displayed in clear text
- **What:** `_waToken` uses `_waInput()`, whose `obscure` defaults to false (`:1166`). Gemini/OpenRouter fields correctly use `_keyField()` with obscuring (`:569-583`).
- **Why:** A live bearer token is readable on screen/screenshots; this token can send messages from the user's number.
- **Fix:** Use `_keyField()` (or `obscureText: true` with a reveal toggle) for the token field.

### H16. `lib/arifa_avatar.dart:36-44,588` — avatar repaints continuously even when idle
- **What:** `_life` and `_talk` controllers both `repeat(reverse: true)` forever; `shouldRepaint => true` (`:588`). Every tick rebuilds the painter, gradient shaders and blurred layers.
- **Why:** ~60 fps of unnecessary CPU/GPU work and battery drain for a static mood.
- **Fix:** Value comparison in `shouldRepaint`; run `_talk` only for speaking/celebrate.

### H17. `lib/live_background.dart:22-30,59-71,199-200` — full-screen galaxy painter repaints unconditionally forever
- **What:** `_flow` and `_bars` repeat for the widget's whole life; `shouldRepaint => true` (`:200`). Each frame redraws two full-screen gradient shaders, 110 stars, 5 wave paths and 56 bars.
- **Why:** Permanent full-screen repaint even when idle/obscured → severe battery drain.
- **Fix:** Compare old/new `flow`/`bars`/`speaking`/`listening` in `shouldRepaint`; pause controllers when not visible.

### H18. `.github/workflows/build.yml:37-47` — scaffold condition is always true / implicit `pub get`
- **What:** The condition checks `android/gradlew` and `android/gradle/wrapper/gradle-wrapper.jar` (`:39-40`), which are not tracked in git, so `flutter create` runs on every CI job. `flutter create` (`--org com.arifa.app`) also performs an implicit `pub get`, then `:50` runs `flutter pub get` again; `:46` restores only `lib/ assets/ models.json`, not `android/`.
- **Why:** CI mutates the Android tree on every run with generated state that is not represented in the repo; duplicated dependency resolution slows the job.
- **Fix:** Add `--no-pub` to the scaffold `flutter create` so the single explicit `flutter pub get` is authoritative. Preserve the user-mandated step order and commands.

### H19. `android/app/build.gradle:45-51` + `scripts/build_apk.sh:16,19` — "release" APK signed with the debug key
- **What:** `release { signingConfig = signingConfigs.debug }` (`:49`); `build_apk.sh` builds `--release` and reports `app-release.apk`.
- **Why:** A distributed "release" has no authenticity guarantee and is not publishable.
- **Fix:** Wire a real release `signingConfig` from `android/key.properties` with a documented debug fallback for local dev; add `android/key.properties` to `.gitignore`.

### H20. Untracked Android build inputs — wrapper JAR/scripts + `styles.xml`
- **What:** `git ls-files` shows `android/gradlew`, `android/gradle/wrapper/gradle-wrapper.jar` and `android/app/src/main/res/values/styles.xml` are not tracked, while `AndroidManifest.xml:37,43` references `@style/LaunchTheme`/`@style/NormalTheme` and the wrapper properties (`:1-5`) exist without the JAR.
- **Why:** A fresh checkout cannot build locally through the wrapper or resolve the declared themes unless `flutter create` regenerates them first; `scripts/build_apk.sh:9-17` does no scaffold preflight.
- **Fix:** Track the wrapper scripts/JAR and `styles.xml`, or add a deterministic scaffold preflight to every build entrypoint.

---

## Medium

### M1. `lib/model_entry.dart:174-180` + `lib/settings_service.dart:184-189` — corrupt stored catalog silently replaced with empty
- **What:** `ModelCatalog.decode()` lets `jsonDecode` throw; `_loadModels()` catches and substitutes `ModelCatalog.empty()`, then may persist it. No backup/status.
- **Why:** One malformed write destroys the user's entire model list with no warning.
- **Fix:** Keep the raw bad value under a backup key and merge seed rows instead of empty overwrite.

### M2. `lib/settings_service.dart:242-248` — `importCatalog` performs almost no validation
- **What:** Only emptiness is checked. Duplicate keys, empty IDs, arbitrary `schemaVersion` (e.g. 999999), unknown providers and unbounded model counts are accepted and written.
- **Why:** Duplicate keys break `defaultModel`/`updateModel`/`deleteModel`; a huge version permanently disables future seed merges; thousands of rows worsen H9.
- **Fix:** Require unique non-empty keys and IDs, sane version range and a row cap before `saveCatalog`.

### M3. `lib/model_entry.dart:17-23` — unknown provider strings silently become OpenRouter
- **What:** `fromWire()` maps any unrecognized value (`anthropic`, typo, JSON import) to `ModelProvider.openRouter`.
- **Why:** Imported non-OpenRouter entries are sent to OpenRouter with its key → 404 with no explanation.
- **Fix:** Add explicit unsupported handling/reject at import.

### M4. `lib/model_entry.dart:87-91` + `lib/settings_screen.dart:213,463` — imported/fetched/custom models default to `supportsVision: true`
- **What:** `_bool(..., fallback: true)`; fetched OpenRouter rows and custom IDs are stored with `supportsVision: true`; `_addCustom()` also forces `setDefault: true` without validating key/ID.
- **Why:** Text-only models are tried first for screenshots → base64 images sent to text-only models, 400s and wasted failover.
- **Fix:** Default unknown rows to `supportsVision: false`; let users opt in.

### M5. `lib/main.dart:20-26` — `SettingsService.init()` has no error handling
- **What:** `readAll()`/`_loadModels()` awaited directly in `main()` with no try/catch.
- **Why:** A Keystore/secure-storage exception prevents `runApp()` → black screen at startup.
- **Fix:** Catch init errors, fall back to in-memory defaults, still start the UI with a short status.

### M6. `lib/arifa_brain.dart:374-388,479-490` — unsafe JSON shape assumptions in provider responses
- **What:** Direct `as Map`/`as List` casts and `msg`/`content` casts assume exact shapes.
- **Why:** A 2xx non-JSON body or string `message` throws `CastError`, swallowed by the generic catch → healthy models skipped, opaque "all models failed" message.
- **Fix:** Guard with `is Map`/`is List`, accept string and list content forms.

### M7. `lib/arifa_brain.dart:51-61` — vision regex checked before coding
- **What:** `classify()` checks vision (`error|fix|ভুল|ঠিক`, `:53`) before coding (`:57`).
- **Why:** "fix this Dart error" → `BrainTask.vision`, which prepends "স্ক্রিনে কী আছে..." with no screenshot → wrong answers and wrong model ordering.
- **Fix:** Check coding first, or restrict vision to explicit screen/screenshot phrases.

### M8. `lib/arifa_brain.dart:253-265` — empty model ID and missing key give one unclear error
- **What:** `usable` filters out both empty-ID rows and no-key rows; one exception covers both.
- **Why:** Seed rows have empty IDs — a user with a key but no Model ID is not told to add one, and vice versa.
- **Fix:** Report the two conditions separately.

### M9. `lib/arifa_brain.dart:348-349,371-372,419-420,476-477` — no 401/403/404/429-specific handling; key checks unreachable from normal callers
- **What:** All `>= 400` become `'OR <code>: <body>'`/`'Gemini <code>: <body>'`; `_modelsFor()` already filters on `hasKeyFor()`, so the explicit "key নেই" throws are never reached by callers.
- **Why:** Invalid key (401), bad model ID (404) and rate limit (429) all look the same; no actionable Bangla guidance.
- **Fix:** Branch on status; cap/shorten error bodies; stop failover on auth errors.

### M10. `lib/arifa_brain.dart:78,96,99,203,216,219` — unbounded aggregated error text
- **What:** `errors.add` for every model and `errors.join(' | ')` has no cap; the result is shown and spoken.
- **Why:** Large catalogs produce an enormous failure message that hides the primary cause.
- **Fix:** Keep 3-5 distinct errors, dedupe by status, primary cause first.

### M11. `lib/main.dart:259-273` — `setState()` after dispose via `_addArifa`/`_addUser`
- **What:** No `mounted` guard, called after long awaits (`:387-392`, `:445`, `:460`, `:480`).
- **Why:** Navigating to Settings while a brain/build call is in flight can call `setState()` on a disposed state → framework error.
- **Fix:** `if (!mounted) return;` at the top of `_addArifa`, `_addUser`, `_scrollToEnd`.

### M12. `lib/main.dart:361-381` — command routing order: "open app ..." starts a build
- **What:** The build branch (`apk|app|...|build`, `:364-366`) precedes the `open` branch (`:380-381`).
- **Why:** "open app YouTube" is routed to `_handleBuild()` and starts AI code generation.
- **Fix:** Test explicit action intents (`open`, `call`, `sms`) before generic build keywords.

### M13. `lib/main.dart:514-541` — failure presented as success in chat/TTS
- **What:** Both success and failure branches start with `'Hoye geche Emon Bhai ♥'`, set `celebrate` (`:526-531`) and speak `'Hoye geche Emon Bhai!'` (`:532`).
- **Why:** When only a source zip was produced the user is told the APK was built. (The zip wording itself in `apk_builder.dart:18-24,320-335` is honest — keep it.)
- **Fix:** Distinct wording/mood for "APK built" vs "source zip only".

### M14. `lib/auto_reply_service.dart:207-211,470-480` — weak dedup and ineffective `_replyTimes` bound
- **What:** Fingerprint uses `millisecondsSinceEpoch ~/ 1000` (1 s resolution, `_recent` capped at 80); cleanup uses `removeWhere(value.isEmpty)` but values always get a timestamp appended, so nothing is evicted.
- **Why:** Same text >1 s apart gets a new fingerprint → duplicate replies; `_replyTimes` grows unbounded.
- **Fix:** Dedupe on native `notification.key` with longer TTL; prune old timestamps / evict oldest key.

### M15. `lib/notification_listener.dart:28-38,146-159` + `auto_reply_service.dart:424-453` — no group-conversation filtering in Dart
- **What:** `IncomingWhatsAppMessage` has no `isGroup` field; native only drops `FLAG_GROUP_SUMMARY`, not individual group messages; an allowed group name (or `*`) is treated like a person.
- **Why:** ARIFA can auto-reply inside group chats where everyone sees it.
- **Fix:** Propagate an `isGroup` flag from native and require a separate group allow-list (default empty).

### M16. `lib/auto_reply_service.dart:254-260` + `lib/whatsapp_service.dart:46-54` — cloud recipient selection stops at first name match
- **What:** Loop breaks on the first matching allow-list entry even when `_asInternationalNumber(entry)` returns empty.
- **Why:** A later entry that does contain the number is never considered → false "add the contact number" error.
- **Fix:** Only break when the converted recipient is non-empty.

### M17. `lib/auto_reply_service.dart:37-47,271-285` + `settings_screen.dart:1190-1238` — full message bodies stored and displayed
- **What:** Every log row stores `incoming`/`reply` verbatim and the UI renders them; no content-logging opt-in.
- **Why:** Private message content is retained even with cloud options OFF.
- **Fix:** Add an opt-in for content logging or store hashes/lengths and truncate previews.

### M18. `lib/auto_reply_service.dart:226-230` + `lib/whatsapp_service.dart:137-139` — raw exception/body text pushed to user-visible status
- **What:** `'WhatsApp reply error: $e'` and `'Cloud API <code>: <body>'` are interpolated into status lines; `notification_listener.dart:165-169` forwards arbitrary payloads.
- **Why:** Untrusted provider response bodies reach the UI; unreadable and unnecessary disclosure.
- **Fix:** Whitelist/sanitize status; map errors to short fixed Bangla strings with status code only.

### M19. `lib/apk_builder.dart:343-346,670-674` — Kotlin package derived from unsanitized AI name
- **What:** `package = 'com.example.$safe'`; `_safeName` only lowercases/replaces non-alphanumerics. Names like `class`/`when`/`123app` yield invalid Java/Kotlin package segments.
- **Why:** Every build attempt fails for a reason unrelated to the generated Dart code.
- **Fix:** Prefix the segment (`app_$safe`) and ensure it starts with a letter / is not a reserved word.

### M20. `lib/apk_builder.dart:155-174,229-255` — toolchain processes have no timeout
- **What:** `Process.run('flutter --version')`, `pub get`, `build apk` awaited without `.timeout()`.
- **Why:** A hung Flutter/Gradle process stalls the builder forever with no error.
- **Fix:** Wrap in a generous timeout and kill the process tree on expiry.

### M21. `lib/apk_builder.dart:275-289,546-556,589-632` — duplicate sanitized paths not detected
- **What:** `_projectFiles()` maps AI paths through `_safePath()` without collision checks; `_writeProject()` overwrites silently and the ZIP writer adds duplicate entry names.
- **Why:** Two files sanitizing to one path produce a project/ZIP whose contents depend on write order, and the "complete source" is not what was reviewed.
- **Fix:** Reject or rename duplicates before writing and before computing the ZIP central directory.

### M22. `lib/apk_builder.dart:582-647` — ZIP sink not closed on failure
- **What:** `zip.openWrite()` is not wrapped in `try/finally`; `close()` only on success (`:647`).
- **Why:** A disk/encoding exception leaves the `IOSink`/file handle open → locked/partial files.
- **Fix:** `try { ... } finally { await sink.close(); }`.

### M23. `lib/main.dart:254-257` + `lib/phone_control.dart:33-42` — phone/SMS permissions requested at boot; no confirmation before call/SMS
- **What:** `_askPermissions()` requests `CALL_PHONE`/`SEND_SMS` in `_boot()`; `_handleCall`/`_handleSms` act immediately on regex-extracted text.
- **Why:** A misrecognized wake command can call or text the wrong number; broad permissions granted before the feature is used.
- **Fix:** Request lazily on first call/SMS intent and require an explicit confirmation step. (`_handleSms`/`_handleCall` re-request permissions — `:589`,`:607` — so boot request is redundant.)

### M24. `lib/settings_screen.dart:1010-1021` — important-contact edits are never persisted
- **What:** `_waImportant.onChanged` mutates `_waImportantList` without `setState()` and without `unawaited(_persistWa())`, unlike every other WhatsApp control (`:706-744` etc.).
- **Why:** The card promises "Every WhatsApp control takes effect immediately — no Save needed" (`:117`); edits are silently discarded on leaving the screen.
- **Fix:** Call `_persistWa()` from `onChanged` (debounced if needed).

### M25. `lib/auto_reply_service.dart:219-233` — disabling auto-reply mid-drain drops queued messages
- **What:** `while (_queue.isNotEmpty && isEnabled)` exits when disabled, leaving `_queue` populated; never cleared or resumed on re-enable.
- **Why:** Messages are neither replied to nor explicitly discarded; combined with H13 they resurface as delayed duplicates.
- **Fix:** Clear the queue on disable or re-drain on re-enable with fresh permission checks.

### M26. `ArifaService.kt:158-165` + `lib/main.dart:304-326` — partial wake results can fire multiple starts
- **What:** `onPartialResults` emits "wake" on every matching partial; Dart sets `_listening` only after `await _voice.speak(...)` (`:316-326`), leaving a guard window.
- **Why:** Repeated TTS and repeated background activity starts before `_busy`/`_listening` are set.
- **Fix:** Debounce wake emissions in Kotlin and set the Dart guard synchronously before the first await.

### M27. `ArifaService.kt:236-298` — MediaProjection capture has no image timeout and unguarded virtual-display creation
- **What:** `ImageReader.newInstance`/`createVirtualDisplay()` (`:236-241`) are unguarded; no watchdog if no image arrives.
- **Why:** The pending capture result hangs indefinitely and the projection can leak.
- **Fix:** Try/catch creation and add a handler-posted timeout that completes the result and releases resources.

### M28. `ArifaService.kt:51-53` + `MainActivity.kt:37,153-216` — single static capture callback can be overwritten
- **What:** `onCaptureDone`/`pendingCaptureResult` are single global slots; a second capture before the first completes orphans the first result.
- **Why:** Concurrent/rapid captures give wrong or missing results.
- **Fix:** Reject a new capture while one is in flight, or key callbacks by request id.

### M29. `AndroidManifest.xml:81-89` + `BootReceiver.kt:13-22,44-52` — locked-boot declaration is non-functional; boot Activity start blocked
- **What:** `LOCKED_BOOT_COMPLETED` declared without `directBootAware` and prefs are `MODE_PRIVATE`; `startActivity()` from a boot broadcast is restricted and exceptions swallowed.
- **Why:** The pre-unlock path cannot work as declared, and "fresh isolate drains pending WhatsApp messages" cannot be relied on.
- **Fix:** Remove the locked-boot action or make it truly direct-boot aware; replace the boot Activity start with a notification/PendingIntent or defer to user open.

### M30. `android/app/src/main/res/xml/accessibility_service_config.xml:3,6,9` — overly broad event mask with empty callback
- **What:** `typeAllMask`, `canPerformGestures="true"`, `notificationTimeout="100"` while `onAccessibilityEvent()` is empty (`ArifaAccessibilityService.kt:28`).
- **Why:** Wakes the service for every UI event at 100 ms cadence doing nothing → CPU/battery overhead and unnecessarily broad access.
- **Fix:** Narrow/empty event types, raise timeout, drop unused gesture capability.

### M31. `lib/main.dart:672-686` (+ `voice_service.dart:240-246`, `background_service.dart:94-97`) — async `dispose()` futures discarded
- **What:** `_voice.dispose()`/`_native.dispose()` return `Future<void>` but are called from synchronous `dispose()` unawaited.
- **Why:** Late TTS/STT callbacks can add to closing controllers → "Bad state" errors.
- **Fix:** Close controllers synchronously / use `unawaited(...)` with error swallowing for plugin teardown.

### M32. `scripts/termux_config.sh:55-61` + `android/app/build.gradle:45-51` — no shrinking/obfuscation for release
- **What:** No `minifyEnabled`/`shrinkResources`/`proguardFiles`; the Termux script explicitly injects `minifyEnabled false`/`shrinkResources false`.
- **Why:** Release APKs are larger and unobfuscated.
- **Fix:** Add R8 with keep rules for the release type (Termux low-RAM override can remain for local builds).

### M33. `.gitignore:10-17` — no `android/key.properties` ignore
- **What:** `.env`, `*.key`, `*.jks`, `*.keystore`, `local.properties`, `debug.keystore` are ignored but the standard signing secret file is not.
- **Why:** Once H19 is fixed, a developer can commit store/key passwords.
- **Fix:** Add `android/key.properties`.

---

## Low

### L1. `lib/arifa_avatar.dart:46,59-61` — one-shot blink `Timer` not retained/cancelled
- Nested 130 ms timer is untracked; harmless due to `mounted` guard but can outlive the widget briefly. Store and cancel in `dispose()`.

### L2. `lib/voice_service.dart:91-99` — gender keyword contradicts its own comment
- Comment says `'google'` is not a gender hint yet it is in `maleWords`; `'বাংলা'` (just "Bengali") is in `femaleWords`. Remove both; match only real gender markers.

### L3. `lib/arifa_brain.dart:141-153,358-369,461-474` — timeouts have no `onTimeout`, autoReply POST not cancelled
- Errors read like raw `TimeoutException`; abandoned requests keep sockets. Add labelled `onTimeout`.

### L4. `lib/arifa_brain.dart:315-339` — `_call` does not reject a trimmed-empty model ID
- Only `_modelsFor()` guards emptiness. Add an explicit `BrainException('Model ID empty')`.

### L5. `lib/apk_builder.dart:201-210,280-281` — `buildMode` not validated
- Arbitrary strings become `--<mode>` but APK naming only handles `release`/`debug`. Restrict to `debug`/`release`.

### L6. `scripts/termux_config.sh:12-17,35` — aapt2 fallback path may not exist
- Writes `$PREFIX/bin/aapt2` without checking; README install list (`:206`) does not include an aapt2 provider. Verify before writing or document.

### L7. `analysis_options.yaml:3-5` — `avoid_print: ignore` with no `print()` in `lib`
- Unnecessary global suppression; remove.

### L8. `pubspec.yaml:6-8,16,28` — misleading dependency comments
- Claims "no ... Windows-only implementation" while pinned federated packages still declare Windows stubs; `flutter_lints 5.0.0` in fact requires Dart `^3.5.0`. Fix or remove the comments. (Pins themselves are kept per the user's explicit toolchain constraint.)

### L9. `ArifaService.kt:3-30` — `WAKE_LOCK` declared (`AndroidManifest.xml:10`) but never acquired
- Remove the permission or use a scoped wake lock.

### L10. `ArifaService.kt:148-166` — no app-controlled beep/vibration on wake detection
- No `ToneGenerator`/`Vibrator`; platform sounds are the only feedback. Add an opt-in haptic/audio cue or accept platform sounds.

---

## Rejected / not confirmed (do not act on these stale claims)

- **`pubspec.yaml:23 path_provider: 2.2.3` "nonexistent version" (reported Critical by a subagent):** FALSE for the current tree. Verified `pubspec.yaml:23` is `path_provider: 2.1.4` (a real, Flutter-3.24-era version, consistent with the `path_provider_android: 2.2.6` override at `:35`). Consequently the subagent's "implicit pub get fails before restore" CI claim is also not applicable. No change needed.
- **`flutter_lints 5.0.0` pin claim:** the file pins `flutter_lints: 4.0.0` (`pubspec.yaml:29`), kept per the user's explicit toolchain constraint. Only the comment is questionable (L8).
- **`flutter analyze --no-fatal-infos || true` (workflow `:53`) and `if-no-files-found: warn` (`:76`), SDK `>=3.5.0 <4.0.0` (`pubspec.yaml:10`), and `shared_preferences: 2.2.3` (`:19`):** these were explicitly mandated by the user in the prior build task. They are intentionally NOT treated as findings to change; subagent suggestions to remove/tighten them are rejected to preserve the user's decision. H18 addresses only the duplicated implicit `pub get`.

---

## Severity tally (confirmed, actionable)
- Critical: 2
- High: 20
- Medium: 33
- Low: 10

Phase 2 will fix in order Critical → High → Medium, with minimal focused changes, preserving
all existing features and UI text — including the exact first-run popup title
`Emon Bhai, Settings e giye API Key din` (`lib/main.dart:205-208`). No new dependency is
planned; if one becomes necessary, the reason will be stated explicitly.
