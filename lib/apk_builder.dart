import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'arifa_brain.dart';
import 'models.dart';

class ApkBuilderException implements Exception {
  final String message;
  ApkBuilderException(this.message);

  @override
  String toString() => message;
}

/// On-device "APK builder" pipeline.
///
/// When a Flutter SDK is reachable (PATH or Termux's standard location) the
/// generated project is REALLY built with `flutter pub get` and
/// `flutter build apk`. When it is not, ARIFA honestly falls back to a complete
/// source zip (Android scaffold + one-command build script) instead of
/// pretending an APK was produced.
class ApkBuilder {
  ApkBuilder({required ArifaBrain brain}) : _brain = brain;

  final ArifaBrain _brain;

  static const _termuxFlutter = '/data/data/com.termux/files/usr/bin/flutter';

  /// Generate -> AI review -> real Flutter build -> feed the *real* toolchain
  /// log back into [ArifaBrain.generateApp] on failure, up to [maxAttempts].
  Future<BuildResult> buildWithAutoFix(
    String request, {
    int maxAttempts = 2,
    String buildMode = 'debug',
    List<String> extraBuildArgs = const [],
    void Function(String stage, String detail)? onProgress,
  }) async {
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    final log = StringBuffer();
    final docs = await getApplicationDocumentsDirectory();
    final flutter = await _findFlutter(log);

    if (flutter == null) {
      log.writeln(
        '[flutter] Flutter SDK পাওয়া যায়নি (PATH বা $_termuxFlutter)। '
        'APK build করা হলো না; সম্পূর্ণ source zip দিচ্ছি।',
      );
      onProgress?.call(
        'fallback',
        'Flutter SDK পাওয়া যায়নি, source zip তৈরি করছি...',
      );
      final app = await _brain.generateApp(request);
      final review = (await _brain.reviewApp(app)).trim();
      if (review.isNotEmpty) log.writeln('[AI review] $review');
      final zip = await saveSourceZip(app, buildMode: buildMode);
      return BuildResult(
        app: app,
        zipPath: zip,
        attempts: 1,
        review: review,
        apkPath: null,
        log: log.toString(),
        success: false,
        flutterAvailable: false,
      );
    }

    log.writeln('[flutter] Using SDK: $flutter');
    log.writeln('[flutter] Build mode: $buildMode');

    GeneratedApp? app;
    String? issue;
    String finalReview = '';

    for (var attempt = 1; attempt <= attempts; attempt++) {
      onProgress?.call(
        'generate',
        '$attempt নম্বর চেষ্টায় কোড তৈরি করছি Emon Bhai...',
      );
      app = await _brain.generateApp(
        request,
        previous: app,
        errorLog: issue,
      );

      onProgress?.call('review', 'AI দিয়ে কোড চেক করছি...');
      finalReview = (await _brain.reviewApp(app)).trim();
      if (finalReview.isNotEmpty) {
        log.writeln('[AI review attempt $attempt] $finalReview');
      }

      final projectDir = Directory(
        '${docs.path}/arifa_builds/${_safeName(app.name)}_a$attempt'
        '_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (!projectDir.existsSync()) projectDir.createSync(recursive: true);

      onProgress?.call(
        'build',
        'Flutter APK build চালাচ্ছি (চেষ্টা $attempt)...',
      );
      log.writeln('===== build attempt $attempt =====');
      final logStart = log.length;
      final built = await _buildOnce(
        app,
        projectDir,
        flutter,
        buildMode,
        extraBuildArgs,
        log,
      );
      final attemptLog = log.toString().substring(logStart);

      final zip = await saveSourceZip(app, buildMode: buildMode);

      if (built.success && built.apkPath != null) {
        return BuildResult(
          app: app,
          zipPath: zip,
          attempts: attempt,
          review: finalReview,
          apkPath: built.apkPath,
          log: log.toString(),
          success: true,
          flutterAvailable: true,
          projectDir: projectDir.path,
        );
      }

      // The real toolchain exit code is the source of truth, not a keyword
      // check on the AI review.
      issue = _buildFailureLog(attemptLog, finalReview);
      onProgress?.call(
        'fix',
        'Build fail, আসল log দিয়ে নিজে ঠিক করে আবার লিখছি...',
      );
    }

    final finalApp = app!;
    return BuildResult(
      app: finalApp,
      zipPath: await saveSourceZip(finalApp, buildMode: buildMode),
      attempts: attempts,
      review: issue ?? finalReview,
      apkPath: null,
      log: log.toString(),
      success: false,
      flutterAvailable: true,
    );
  }

  Future<String?> _findFlutter(StringBuffer log) async {
    for (final candidate in <String>['flutter', _termuxFlutter]) {
      try {
        final r = await Process.run(
          candidate,
          const ['--version'],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (r.exitCode == 0) {
          log.writeln('[flutter] Found: $candidate');
          return candidate;
        }
        log.writeln('[flutter] $candidate --version exited ${r.exitCode}');
      } catch (e) {
        log.writeln('[flutter] $candidate unavailable: $e');
      }
    }
    return null;
  }

  Future<_BuildOutcome> _buildOnce(
    GeneratedApp app,
    Directory dir,
    String flutter,
    String buildMode,
    List<String> extraBuildArgs,
    StringBuffer log,
  ) async {
    await _writeProject(app, dir, buildMode: buildMode);

    // Generated apps normally have no android/ folder. Let Flutter create a
    // correct, version-matched scaffold (also repairs a partial one).
    if (!File('${dir.path}/android/gradlew').existsSync()) {
      final code = await _run(
        flutter,
        const ['create', '--platforms=android', '--org', 'com.example', '.'],
        dir.path,
        log,
      );
      if (code != 0) return const _BuildOutcome(false, null);
    }

    var code = await _run(flutter, const ['pub', 'get'], dir.path, log);
    if (code != 0) return const _BuildOutcome(false, null);

    code = await _run(
      flutter,
      <String>['build', 'apk', '--$buildMode', '--verbose', ...extraBuildArgs],
      dir.path,
      log,
    );
    if (code != 0) return const _BuildOutcome(false, null);

    final apkName = buildMode == 'release' ? 'app-release.apk' : 'app-debug.apk';
    final built = File('${dir.path}/build/app/outputs/flutter-apk/$apkName');
    if (!built.existsSync()) {
      log.writeln('[apk] Build returned 0 but $apkName was not found.');
      return const _BuildOutcome(false, null);
    }

    // Copy out of the temp project so the APK is stable for sharing.
    final docs = await getApplicationDocumentsDirectory();
    final outDir = Directory('${docs.path}/arifa_apks');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final copied = File(
      '${outDir.path}/${_safeName(app.name)}_'
      '${DateTime.now().millisecondsSinceEpoch}_$apkName',
    );
    await built.copy(copied.path);
    log.writeln('[apk] ${copied.path}');
    return _BuildOutcome(true, copied.path);
  }

  /// Runs one toolchain command, capturing stdout + stderr + exit code.
  Future<int> _run(
    String executable,
    List<String> args,
    String workingDirectory,
    StringBuffer log,
  ) async {
    log.writeln('\$ $executable ${args.join(' ')} (in $workingDirectory)');
    try {
      final r = await Process.run(
        executable,
        args,
        workingDirectory: workingDirectory,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final out = (r.stdout as String?) ?? '';
      final err = (r.stderr as String?) ?? '';
      if (out.trim().isNotEmpty) log.writeln(out);
      if (err.trim().isNotEmpty) log.writeln('[stderr] $err');
      log.writeln('[exit ${r.exitCode}]');
      return r.exitCode;
    } catch (e) {
      log.writeln('[process error] $e');
      return -1;
    }
  }

  String _buildFailureLog(String attemptLog, String review) {
    final buf = StringBuffer()
      ..writeln('FLUTTER BUILD FAILED. Real toolchain log (tail):')
      ..writeln(_logTail(attemptLog));
    if (review.isNotEmpty) {
      buf
        ..writeln('AI review (informational):')
        ..writeln(_logTail(review, 2000));
    }
    return buf.toString();
  }

  String _logTail(String text, [int maxChars = 8000]) {
    if (text.length <= maxChars) return text;
    return '...[truncated ${text.length - maxChars} chars]...\n'
        '${text.substring(text.length - maxChars)}';
  }

  /// All files that make a generated project standalone-buildable.
  List<CodeBlock> _projectFiles(
    GeneratedApp app, {
    required String buildMode,
  }) {
    final modeFlag = buildMode == 'release' ? 'release' : 'debug';
    final apkName = modeFlag == 'release' ? 'app-release.apk' : 'app-debug.apk';
    return <CodeBlock>[
      ...app.files.map(
        (f) => CodeBlock(
          path: _safePath(f.path),
          language: f.language,
          content: f.content,
        ),
      ),
      ..._androidScaffold(app.name),
      CodeBlock(
        path: 'build_apk.sh',
        language: 'bash',
        content: r'''#!/usr/bin/env bash
set -euo pipefail

# Generated apps may not ship the Flutter Android platform folder. Recreate it
# with Flutter's own template (also repairs a partial scaffold).
if [ ! -f android/gradlew ]; then
  echo "Android scaffold missing/incomplete - flutter create --platforms=android ."
  flutter create --platforms=android --org com.example .
fi

flutter pub get
flutter build apk --MODE --verbose

echo "APK: build/app/outputs/flutter-apk/APKNAME"
'''
            .replaceAll('MODE', modeFlag)
            .replaceAll('APKNAME', apkName),
      ),
      CodeBlock(
        path: 'README_ARIFA.txt',
        language: 'text',
        content: '''${app.name}
${app.summary}

Generated by ARIFA for Emon Bhai ♥

Build this project on a machine that has the Flutter SDK + Android SDK + JDK:

    ./build_apk.sh

or manually:

    flutter pub get
    flutter build apk --$modeFlag --verbose

On aarch64 Termux use:

    flutter build apk --$modeFlag --verbose --target-platform android-arm64 --no-tree-shake-icons

The APK appears at build/app/outputs/flutter-apk/$apkName.
API keys are NOT included in this project.
''',
      ),
    ];
  }

  /// Minimal but complete Android platform scaffold. Normally Flutter's own
  /// `flutter create` regenerates this; it is written here so the fallback zip
  /// is still a full project on machines without a Flutter SDK right now.
  List<CodeBlock> _androidScaffold(String name) {
    final safe = _safeName(name);
    final package = 'com.example.$safe';
    final packagePath = package.replaceAll('.', '/');
    final label = name.trim().isEmpty ? 'ARIFA App' : name.trim();
    return <CodeBlock>[
      const CodeBlock(
        path: 'android/settings.gradle',
        language: 'groovy',
        content: r'''
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
    id "com.android.application" version "8.1.1" apply false
    id "org.jetbrains.kotlin.android" version "1.8.22" apply false
}

include ":app"
''',
      ),
      const CodeBlock(
        path: 'android/build.gradle',
        language: 'groovy',
        content: r'''
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.buildDir = "../build"

subprojects {
    project.buildDir = "${rootProject.buildDir}/${project.name}"
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register("clean", Delete) {
    delete rootProject.buildDir
}
''',
      ),
      const CodeBlock(
        path: 'android/gradle.properties',
        language: 'text',
        content: '''
org.gradle.jvmargs=-Xmx2G -XX:MaxMetaspaceSize=1G -XX:+HeapDumpOnOutOfMemoryError
android.useAndroidX=true
android.enableJetifier=true
''',
      ),
      const CodeBlock(
        path: 'android/gradle/wrapper/gradle-wrapper.properties',
        language: 'text',
        content: '''
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\\://services.gradle.org/distributions/gradle-8.4-all.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
''',
      ),
      CodeBlock(
        path: 'android/app/build.gradle',
        language: 'groovy',
        content: '''
plugins {
    id "com.android.application"
    id "kotlin-android"
    id "dev.flutter.flutter-gradle-plugin"
}

def localProperties = new Properties()
def localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.withReader("UTF-8") { reader ->
        localProperties.load(reader)
    }
}

def flutterVersionCode = localProperties.getProperty("flutter.versionCode")
if (flutterVersionCode == null) {
    flutterVersionCode = "1"
}

def flutterVersionName = localProperties.getProperty("flutter.versionName")
if (flutterVersionName == null) {
    flutterVersionName = "1.0"
}

android {
    namespace "$package"
    compileSdk 34

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    sourceSets {
        main.java.srcDirs += 'src/main/kotlin'
    }

    defaultConfig {
        applicationId "$package"
        minSdkVersion 21
        targetSdkVersion 34
        versionCode flutterVersionCode.toInteger()
        versionName flutterVersionName
    }

    buildTypes {
        release {
            // Signing with the debug key for local testing only.
            signingConfig signingConfigs.debug
        }
    }
}

flutter {
    source "../.."
}
''',
      ),
      CodeBlock(
        path: 'android/app/src/main/AndroidManifest.xml',
        language: 'xml',
        content: r'''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <application
        android:label="APP_LABEL"
        android:name="${applicationName}"
        android:icon="@android:drawable/sym_def_app_icon">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme"
                />
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />
    </application>
</manifest>
'''
            .replaceAll('APP_LABEL', _xmlEscape(label)),
      ),
      CodeBlock(
        path: 'android/app/src/main/kotlin/$packagePath/MainActivity.kt',
        language: 'kotlin',
        content: '''
package $package

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
''',
      ),
      const CodeBlock(
        path: 'android/app/src/main/res/values/styles.xml',
        language: 'xml',
        content: r'''
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@android:color/black</item>
    </style>
    <style name="NormalTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@android:color/black</item>
    </style>
</resources>
''',
      ),
    ];
  }

  Future<void> _writeProject(
    GeneratedApp app,
    Directory dir, {
    required String buildMode,
  }) async {
    final entries = _projectFiles(app, buildMode: buildMode);
    for (final file in entries) {
      final f = File('${dir.path}/${file.path}');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(file.content);
    }
    // Best effort: make the one-command build script runnable directly.
    // `bash build_apk.sh` still works where chmod is unavailable.
    try {
      await Process.run('chmod', ['+x', '${dir.path}/build_apk.sh']);
    } catch (_) {
      // ignore
    }
  }

  Future<String> saveSourceZip(
    GeneratedApp app, {
    String buildMode = 'debug',
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final safeName = _safeName(app.name);
    final outDir = Directory('${dir.path}/arifa_projects/$safeName');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    final entries = _projectFiles(app, buildMode: buildMode);
    await _writeProject(app, outDir, buildMode: buildMode);

    // Minimal stored (uncompressed) ZIP writer. The `archive` package is not
    // part of the allowed Android-only dependency set, so the format is
    // emitted directly: local headers + central directory + EOCD.
    final zip = File('${dir.path}/arifa_projects/$safeName.zip');
    final sink = zip.openWrite();
    final central = BytesBuilder(copy: false);
    final now = DateTime.now();
    final dosTime = (now.hour << 11) | (now.minute << 5) | (now.second ~/ 2);
    final dosDate = ((now.year - 1980) << 9) | (now.month << 5) | now.day;
    var offset = 0;

    for (final file in entries) {
      final name = utf8.encode(_safePath(file.path));
      final bytes = utf8.encode(file.content);
      final crc = _crc32(bytes);

      final local = ByteData(30)
        ..setUint32(0, 0x04034b50, Endian.little) // local file signature
        ..setUint16(4, 20, Endian.little) // version needed
        ..setUint16(6, 0x0800, Endian.little) // UTF-8 filenames
        ..setUint16(8, 0, Endian.little) // stored, no compression
        ..setUint16(10, dosTime, Endian.little)
        ..setUint16(12, dosDate, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, bytes.length, Endian.little)
        ..setUint32(22, bytes.length, Endian.little)
        ..setUint16(26, name.length, Endian.little)
        ..setUint16(28, 0, Endian.little);
      sink.add(local.buffer.asUint8List());
      sink.add(name);
      sink.add(bytes);

      final cd = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little) // central dir signature
        ..setUint16(4, 20, Endian.little) // version made by
        ..setUint16(6, 20, Endian.little) // version needed
        ..setUint16(8, 0x0800, Endian.little) // UTF-8 filenames
        ..setUint16(10, 0, Endian.little) // stored
        ..setUint16(12, dosTime, Endian.little)
        ..setUint16(14, dosDate, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, bytes.length, Endian.little)
        ..setUint32(24, bytes.length, Endian.little)
        ..setUint16(28, name.length, Endian.little)
        ..setUint16(30, 0, Endian.little) // extra length
        ..setUint16(32, 0, Endian.little) // comment length
        ..setUint16(34, 0, Endian.little) // disk start
        ..setUint16(36, 0, Endian.little) // internal attrs
        ..setUint32(38, 0, Endian.little) // external attrs
        ..setUint32(42, offset, Endian.little);
      central.add(cd.buffer.asUint8List());
      central.add(name);

      offset += 30 + name.length + bytes.length;
    }

    final centralBytes = central.takeBytes();
    sink.add(centralBytes);
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little) // EOCD signature
      ..setUint16(4, 0, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, entries.length, Endian.little)
      ..setUint16(10, entries.length, Endian.little)
      ..setUint32(12, centralBytes.length, Endian.little)
      ..setUint32(16, offset, Endian.little)
      ..setUint16(20, 0, Endian.little);
    sink.add(end.buffer.asUint8List());
    await sink.flush();
    await sink.close();
    return zip.path;
  }

  static int _crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        final mask = (crc & 1) != 0 ? 0xEDB88320 : 0;
        crc = (crc >> 1) ^ mask;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  String _safeName(String raw) {
    final s = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
    final trimmed = s.replaceAll(RegExp(r'^_+|_+$'), '');
    return trimmed.isEmpty ? 'arifa_app' : trimmed;
  }

  String _safePath(String raw) {
    final cleaned = raw.replaceAll('\\', '/').replaceFirst(RegExp(r'^(\./|/)+'), '');
    final parts = cleaned
        .split('/')
        .where((p) => p.isNotEmpty && p != '.' && p != '..')
        .toList();
    return parts.isEmpty ? 'snippet.txt' : parts.join('/');
  }
}

class _BuildOutcome {
  final bool success;
  final String? apkPath;
  const _BuildOutcome(this.success, this.apkPath);
}

/// Structured result of [ApkBuilder.buildWithAutoFix].
///
/// [app], [zipPath], [attempts] and [review] are unchanged from the old API so
/// existing callers keep working; the new fields describe the real build.
class BuildResult {
  final GeneratedApp app;
  final String zipPath;
  final int attempts;
  final String review;

  /// Real APK path, non-null only when [success] is true.
  final String? apkPath;

  /// Combined stdout+stderr of every toolchain step.
  final String log;

  /// True only when `flutter build apk` really produced an APK.
  final bool success;

  /// False means Flutter was not installed and we fell back to source zip.
  final bool flutterAvailable;

  /// Temp project directory used for the last build (useful for debugging).
  final String? projectDir;

  const BuildResult({
    required this.app,
    required this.zipPath,
    required this.attempts,
    required this.review,
    this.apkPath,
    this.log = '',
    this.success = false,
    this.flutterAvailable = false,
    this.projectDir,
  });
}
