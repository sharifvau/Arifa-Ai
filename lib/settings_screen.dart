import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'auto_reply_service.dart';
import 'config.dart';
import 'model_entry.dart';
import 'settings_service.dart';

/// Play-Store-style settings with a fully editable model catalog.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _gemini = TextEditingController();
  final _openRouter = TextEditingController();
  final _customId = TextEditingController();

  // WhatsApp Auto Reply controls
  final _waAllowInput = TextEditingController();
  final _waCustomContact = TextEditingController();
  final _waCustomReply = TextEditingController();
  final _waToken = TextEditingController();
  final _waPhoneId = TextEditingController();
  final _waStyle = TextEditingController();
  final _waImportant = TextEditingController();
  StreamSubscription<List<AutoReplyLogEntry>>? _waLogSub;

  late bool _waEnabled;
  late bool _waCloudBrain;
  late bool _waCloudApi;
  late bool _waReplyUnknown;
  List<String> _waAllow = const [];
  List<String> _waStyles = const [];
  List<String> _waImportantList = const [];
  Map<String, String> _waReplies = const {};
  List<AutoReplyLogEntry> _waLogs = const [];
  bool _notifAccess = false;
  bool _accessibility = false;

  late VoiceChoice _voice;
  late bool _wake;
  ModelProvider? _customProvider; // null = auto-detect from the ID
  bool _obscureGemini = true;
  bool _obscureRouter = true;
  bool _saving = false;
  bool _fetching = false;
  List<Map<String, String>> _fetched = const [];

  @override
  void initState() {
    super.initState();
    final s = SettingsService.instance;
    _gemini.text = s.geminiKey;
    _openRouter.text = s.openRouterKey;
    _voice = s.voice;
    _wake = s.wakeEnabled;

    _waEnabled = s.whatsappAutoReply;
    _waAllow = List.unmodifiable(s.whatsappAllowList);
    _waImportantList = List.unmodifiable(s.whatsappImportantContacts);
    _waStyles = List.unmodifiable(s.whatsappStyleSamples);
    _waReplies = Map.unmodifiable(s.whatsappCustomReplies);
    _waCloudBrain = s.whatsappUseCloudBrain;
    _waCloudApi = s.whatsappUseCloudApi;
    _waReplyUnknown = s.whatsappReplyUnknown;
    _waToken.text = s.whatsappBusinessToken;
    _waPhoneId.text = s.whatsappBusinessPhoneId;
    _waImportant.text = _waImportantList.join(', ');
    _waLogs = AutoReplyService.instance.entries;

    _waLogSub = AutoReplyService.instance.logs.listen((logs) {
      if (mounted) setState(() => _waLogs = logs);
    });
    _refreshWaPermissions();
  }

  @override
  void dispose() {
    _waLogSub?.cancel();
    _gemini.dispose();
    _openRouter.dispose();
    _customId.dispose();
    _waAllowInput.dispose();
    _waCustomContact.dispose();
    _waCustomReply.dispose();
    _waToken.dispose();
    _waPhoneId.dispose();
    _waStyle.dispose();
    _waImportant.dispose();
    super.dispose();
  }

  Future<void> _refreshWaPermissions() async {
    final listener = AutoReplyService.instance.notificationListener;
    final notif = await listener.notificationAccessEnabled;
    final acc = await listener.accessibilityEnabled;
    if (!mounted) return;
    setState(() {
      _notifAccess = notif;
      _accessibility = acc;
    });
  }

  /// Every WhatsApp control takes effect immediately — no Save needed.
  Future<void> _persistWa({bool includeEnabled = true}) async {
    await SettingsService.instance.saveWhatsApp(
      enabled: includeEnabled ? _waEnabled : null,
      allowList: _waAllow,
      importantContacts: _waImportantList,
      businessToken: _waToken.text,
      businessPhoneId: _waPhoneId.text,
      useCloudBrain: _waCloudBrain,
      useCloudApi: _waCloudApi,
      styleSamples: _waStyles,
      customReplies: _waReplies,
      replyUnknown: _waReplyUnknown,
    );
    await AutoReplyService.instance.refreshConfig();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await SettingsService.instance.saveAll(
        gemini: _gemini.text,
        openRouter: _openRouter.text,
        selectedVoice: _voice,
        selectedWake: _wake,
        whatsappAutoReplyEnabled: _waEnabled,
        whatsappAllow: _waAllow,
        whatsappImportant: _waImportantList,
        whatsappToken: _waToken.text,
        whatsappPhoneId: _waPhoneId.text,
        whatsappCloudBrain: _waCloudBrain,
        whatsappCloudApi: _waCloudApi,
        whatsappStyles: _waStyles,
        whatsappReplies: _waReplies,
        whatsappReplyToUnknown: _waReplyUnknown,
      );
      await AutoReplyService.instance.refreshConfig();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('সেভ হয়েছে Emon Bhai ♥ (encrypted storage-এ)'),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      _snack('সেভ করা যায়নি Emon Bhai: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  ModelProvider _resolveProvider(String id) {
    if (_customProvider != null) return _customProvider!;
    final v = id.trim().toLowerCase();
    if (v.startsWith('gemini-') || v.startsWith('models/gemini-')) {
      return ModelProvider.gemini;
    }
    return ModelProvider.openRouter;
  }

  Future<void> _addCustom() async {
    final id = _customId.text.trim();
    if (id.isEmpty) {
      _snack('Model ID লিখে দিও Emon Bhai।');
      return;
    }
    final provider = _resolveProvider(id);
    await SettingsService.instance.addModel(
      ModelEntry(
        key: ModelEntry.newKey(),
        name: id,
        id: id,
        provider: provider,
        supportsVision: true,
      ),
      setDefault: true,
    );
    _customId.clear();
    setState(() {});
    _snack('$id অ্যাড হয়েছে আর Default সেট হয়েছে ♥');
  }

  Future<ModelEntry?> _showModelDialog(ModelEntry? existing) async {
    final nameC = TextEditingController(text: existing?.name ?? '');
    final idC = TextEditingController(text: existing?.id ?? '');
    var provider = existing?.provider ?? ModelProvider.openRouter;
    var vision = existing?.supportsVision ?? true;

    final result = await showDialog<ModelEntry>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          backgroundColor: const Color(0xFF06182B),
          title: Text(
            existing == null ? 'Add New Model' : 'Edit Model',
            style: const TextStyle(color: Colors.cyanAccent),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameC,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    labelStyle: TextStyle(color: Colors.cyanAccent),
                    hintText: 'Whatever you like',
                    hintStyle: TextStyle(color: Colors.white24),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: idC,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Model ID',
                    labelStyle: TextStyle(color: Colors.cyanAccent),
                    hintText: 'provider/model-id',
                    hintStyle: TextStyle(color: Colors.white24),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ModelProvider>(
                  value: provider,
                  dropdownColor: const Color(0xFF0A1B2E),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Provider',
                    labelStyle: TextStyle(color: Colors.cyanAccent),
                  ),
                  items: ModelProvider.values
                      .map(
                        (p) => DropdownMenuItem(value: p, child: Text(p.label)),
                      )
                      .toList(),
                  onChanged: (v) => setDialog(() => provider = v ?? provider),
                ),
                CheckboxListTile(
                  value: vision,
                  onChanged: (v) => setDialog(() => vision = v ?? vision),
                  activeColor: Colors.cyanAccent,
                  title: const Text(
                    'Supports screen vision',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameC.text.trim();
                final id = idC.text.trim();
                if (name.isEmpty || id.isEmpty) return;
                Navigator.pop(
                  ctx,
                  ModelEntry(
                    key: existing?.key ?? ModelEntry.newKey(),
                    name: name,
                    id: id,
                    provider: provider,
                    supportsVision: vision,
                    starter: existing?.starter ?? false,
                  ),
                );
              },
              style: FilledButton.styleFrom(backgroundColor: Colors.cyanAccent),
              child: const Text('Save', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );

    nameC.dispose();
    idC.dispose();
    return result;
  }

  Future<void> _editModel(ModelEntry? existing) async {
    final entry = await _showModelDialog(existing);
    if (entry == null) return;
    final s = SettingsService.instance;
    if (existing == null) {
      await s.addModel(entry);
      _snack('নতুন মডেল অ্যাড হয়েছে Emon Bhai।');
    } else {
      await s.updateModel(existing.key, entry);
      _snack('মডেল আপডেট হয়েছে Emon Bhai।');
    }
    setState(() {});
  }

  Future<void> _deleteModel(ModelEntry model) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF06182B),
        title: const Text(
          'Delete model?',
          style: TextStyle(color: Colors.cyanAccent),
        ),
        content: Text(
          '${model.name} কে মুছে ফেলব Emon Bhai?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SettingsService.instance.deleteModel(model.key);
    setState(() {});
    _snack('মডেল মুছে ফেলা হয়েছে Emon Bhai।');
  }

  Future<void> _fetchModels() async {
    setState(() => _fetching = true);
    try {
      final res = await http
          .get(Uri.parse(ArifaConstants.openRouterModelsEndpoint))
          .timeout(const Duration(seconds: 25));
      if (res.statusCode >= 400) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final list = <Map<String, String>>[];
      for (final e in (j['data'] as List? ?? [])) {
        if (e is! Map) continue;
        final id = (e['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        final name = (e['name'] ?? id).toString().trim();
        list.add({'id': id, 'name': name});
      }
      list.sort((a, b) => a['id']!.compareTo(b['id']!));
      setState(() => _fetched = list);
      await _showFetchedSheet();
    } catch (e) {
      _snack('মডেল লোড fail: $e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _showFetchedSheet() async {
    var query = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF06182B),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final shown = _fetched.where((m) {
            final q = query.trim().toLowerCase();
            if (q.isEmpty) return true;
            return m['name']!.toLowerCase().contains(q) ||
                m['id']!.toLowerCase().contains(q);
          }).toList();

          return Padding(
            padding: EdgeInsets.only(
              left: 14,
              right: 14,
              top: 14,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 14,
            ),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.72,
              child: Column(
                children: [
                  TextField(
                    onChanged: (v) => setSheet(() => query = v),
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Search models...',
                      hintStyle: TextStyle(color: Colors.white38),
                      prefixIcon: Icon(Icons.search, color: Colors.cyanAccent),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final m = shown[i];
                        return ListTile(
                          title: Text(
                            m['name']!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            m['id']!,
                            style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 11,
                            ),
                          ),
                          onTap: () async {
                            await SettingsService.instance.addModel(
                              ModelEntry(
                                key: ModelEntry.newKey(),
                                name: m['name']!,
                                id: m['id']!,
                                provider: ModelProvider.openRouter,
                                supportsVision: true,
                              ),
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                            setState(() {});
                            _snack('অ্যাড হয়েছে Emon Bhai ♥');
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _exportJson() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/arifa_models/models.json');
      file.parent.createSync(recursive: true);
      final catalog = SettingsService.instance.toCatalog();
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(catalog.toJson()),
      );
      await Share.shareXFiles([XFile(file.path)], subject: 'ARIFA models.json');
    } catch (e) {
      _snack('Export fail: $e');
    }
  }

  Future<void> _importJson() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = result?.files.singleOrNull?.path;
      if (path == null) return;
      final raw = await File(path).readAsString();
      await SettingsService.instance.importCatalog(raw);
      setState(() {});
      _snack('models.json ইমপোর্ট হয়েছে Emon Bhai ♥');
    } catch (e) {
      _snack('Import fail: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF03060D),
      appBar: AppBar(
        title: const Text('ARIFA Settings'),
        backgroundColor: const Color(0xFF06182B),
        foregroundColor: Colors.cyanAccent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          _privacyCard(),
          const SizedBox(height: 16),
          _whatsAppCard(),
          const SizedBox(height: 16),
          _keyField(
            controller: _gemini,
            label: 'Gemini API Key',
            hint: 'Google AI Studio key',
            obscure: _obscureGemini,
            onToggle: () => setState(() => _obscureGemini = !_obscureGemini),
          ),
          const SizedBox(height: 12),
          _keyField(
            controller: _openRouter,
            label: 'OpenRouter API Key',
            hint: 'OpenRouter key',
            obscure: _obscureRouter,
            onToggle: () => setState(() => _obscureRouter = !_obscureRouter),
          ),
          const SizedBox(height: 18),
          _modelManagerCard(),
          const SizedBox(height: 14),
          _dropdownCard(
            icon: Icons.record_voice_over_outlined,
            title: 'Voice Selector',
            subtitle: 'ARIFA কেমন শব্দে কথা বলবে',
            child: DropdownButtonFormField<VoiceChoice>(
              value: _voice,
              dropdownColor: const Color(0xFF0A1B2E),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.cyanAccent),
                ),
              ),
              items: VoiceChoice.values
                  .map((v) => DropdownMenuItem(value: v, child: Text(v.label)))
                  .toList(),
              onChanged: (v) => setState(() => _voice = v ?? _voice),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            color: const Color(0xFF08182A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.cyanAccent.withOpacity(0.3)),
            ),
            child: SwitchListTile(
              value: _wake,
              onChanged: (v) => setState(() => _wake = v),
              activeColor: Colors.cyanAccent,
              secondary: const Icon(Icons.graphic_eq, color: Colors.cyanAccent),
              title: const Text(
                'Wake Word ON/OFF',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                '"Arifa" bollei sunbe (background service)',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text(
                'Save',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- WhatsApp Auto Reply ----------

  void _addWaAllow() {
    final value = _waAllowInput.text.trim();
    if (value.isEmpty) return;
    setState(() {
      if (!_waAllow.any((e) => e.toLowerCase() == value.toLowerCase())) {
        _waAllow = [..._waAllow, value];
      }
      _waAllowInput.clear();
    });
    unawaited(_persistWa());
  }

  void _removeWaAllow(String value) {
    setState(() => _waAllow = _waAllow.where((e) => e != value).toList());
    unawaited(_persistWa());
  }

  void _addWaReply() {
    final contact = _waCustomContact.text.trim();
    final reply = _waCustomReply.text.trim();
    if (contact.isEmpty || reply.isEmpty) return;
    setState(() {
      _waReplies = {..._waReplies, contact: reply};
      _waCustomContact.clear();
      _waCustomReply.clear();
    });
    unawaited(_persistWa());
  }

  void _removeWaReply(String contact) {
    final next = Map<String, String>.from(_waReplies)..remove(contact);
    setState(() => _waReplies = next);
    unawaited(_persistWa());
  }

  void _addWaStyle() {
    final value = _waStyle.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _waStyles = [..._waStyles, value];
      _waStyle.clear();
    });
    unawaited(_persistWa());
  }

  void _removeWaStyle(String value) {
    setState(() => _waStyles = _waStyles.where((e) => e != value).toList());
    unawaited(_persistWa());
  }

  Widget _whatsAppCard() {
    final listener = AutoReplyService.instance.notificationListener;
    return Card(
      color: const Color(0xFF08182A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.greenAccent.withOpacity(0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.chat_bubble_outline, color: Colors.greenAccent),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'WhatsApp Auto Reply',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Switch, allow list, custom reply আর log — সব শুধু এই ফোনে। '
              'ON/OFF আর বাকি সব সেটিংস সাথে সেভ হয় (Save চাপতে হবে না)।',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _waEnabled,
              activeColor: Colors.greenAccent,
              secondary: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _waEnabled ? Colors.greenAccent : Colors.redAccent,
                  boxShadow: [
                    BoxShadow(
                      color:
                          (_waEnabled ? Colors.greenAccent : Colors.redAccent)
                              .withOpacity(0.8),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              title: Text(
                _waEnabled ? 'Auto Reply ON' : 'Auto Reply OFF',
                style: TextStyle(
                  color: _waEnabled ? Colors.greenAccent : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: const Text(
                'Voice: "Arifa WhatsApp auto reply ON/OFF koro"',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              onChanged: (v) async {
                setState(() => _waEnabled = v);
                await _persistWa();
              },
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _permissionButton(
                    label: _notifAccess
                        ? 'Notification access ON'
                        : 'Give notification access',
                    ok: _notifAccess,
                    onTap: () async {
                      await listener.openNotificationSettings();
                      await _refreshWaPermissions();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _permissionButton(
                    label: _accessibility
                        ? 'Accessibility ON'
                        : 'Give accessibility',
                    ok: _accessibility,
                    onTap: () async {
                      await listener.openAccessibilitySettings();
                      await _refreshWaPermissions();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Kake reply dibo (Allow List)',
              style: TextStyle(
                color: Colors.greenAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'এই নাম/নম্বর ছাড়া কোনো মেসেজ পড়া বা reply দেওয়া হবে না। '
              '"*" দিলে সবাইকে reply দিবে (unknown line সহ)।',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _waInput(
                    controller: _waAllowInput,
                    label: 'Contact name / number',
                    hint: 'Ammu, 017..., or *',
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _addWaAllow,
                  icon: const Icon(Icons.add_circle, color: Colors.greenAccent),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _waAllow.isEmpty
                  ? const [
                      Text(
                        'কেউ এড করা হয়নি — কিছুই পড়া হবে না',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ]
                  : _waAllow
                        .map(
                          (c) => Chip(
                            label: Text(
                              c,
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 11,
                              ),
                            ),
                            backgroundColor: const Color(0xFF0A2036),
                            onDeleted: () => _removeWaAllow(c),
                          ),
                        )
                        .toList(),
            ),
            const SizedBox(height: 14),
            const Text(
              'Kake ki reply dibo (custom rules)',
              style: TextStyle(
                color: Colors.greenAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            _waInput(
              controller: _waCustomContact,
              label: 'Contact',
              hint: 'e.g. Ammu',
            ),
            const SizedBox(height: 8),
            _waInput(
              controller: _waCustomReply,
              label: 'Reply message',
              hint: 'Emon Bhai ektu busy ache...',
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _addWaReply,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add rule'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.greenAccent,
                ),
              ),
            ),
            for (final entry in _waReplies.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  entry.key,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  entry.value,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                trailing: IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Colors.redAccent,
                  ),
                  onPressed: () => _removeWaReply(entry.key),
                ),
              ),
            const SizedBox(height: 10),
            const Text(
              'Amar talking style (setting er moton kotha shikhbe)',
              style: TextStyle(
                color: Colors.greenAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _waInput(
                    controller: _waStyle,
                    label: 'Style sample',
                    hint: 'are ei to achi, bol ki khobor?',
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _addWaStyle,
                  icon: const Icon(Icons.add_circle, color: Colors.greenAccent),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: _waStyles
                  .map(
                    (s) => Chip(
                      label: Text(
                        s,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                      backgroundColor: const Color(0xFF0A2036),
                      onDeleted: () => _removeWaStyle(s),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 10),
            _waInput(
              controller: _waImportant,
              label: 'Important contacts (comma separated)',
              hint: 'Ammu, Family',
              onChanged: (v) {
                _waImportantList = v
                    .split(',')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
              },
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _waReplyUnknown,
              activeColor: Colors.greenAccent,
              title: const Text(
                'Unknown person-ke fixed line reply',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              subtitle: const Text(
                'OFF: unknown person-ke kichu reply dibo na (safe)',
                style: TextStyle(color: Colors.white54, fontSize: 10),
              ),
              onChanged: (v) async {
                setState(() => _waReplyUnknown = v);
                await _persistWa();
              },
            ),
            const SizedBox(height: 10),
            const Text(
              'Optional cloud (default OFF)',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Cloud Brain/API ON করলে incoming message text তোমার configured '
              'AI model বা WhatsApp-এ পাঠানো যাবে। Privacy চাইলে দুটোই OFF রাখো ♥',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _waCloudBrain,
              activeColor: Colors.orangeAccent,
              title: const Text(
                'Use AI brain to compose reply',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              onChanged: (v) async {
                setState(() => _waCloudBrain = v);
                await _persistWa();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _waCloudApi,
              activeColor: Colors.orangeAccent,
              title: const Text(
                'Send via WhatsApp Business Cloud API',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              onChanged: (v) async {
                setState(() => _waCloudApi = v);
                await _persistWa();
              },
            ),
            const SizedBox(height: 8),
            _waInput(
              controller: _waToken,
              label: 'Business Cloud Token',
              hint: 'optional',
            ),
            const SizedBox(height: 8),
            _waInput(
              controller: _waPhoneId,
              label: 'Phone Number ID',
              hint: 'optional',
            ),
            const SizedBox(height: 14),
            Row(
              children: const [
                Icon(Icons.history, color: Colors.greenAccent, size: 18),
                SizedBox(width: 8),
                Text(
                  'Kake ki reply dilam',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (_waLogs.isEmpty)
              const Text(
                'Ekhono kono reply dei nai Emon Bhai ♥',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              )
            else
              ..._waLogs.take(40).map(_waLogTile),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await AutoReplyService.instance.clearLogs();
                  if (mounted) _snack('Reply log clear hoyeche Emon Bhai');
                },
                icon: const Icon(Icons.delete_sweep, size: 15),
                label: const Text('Clear log'),
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionButton({
    required String label,
    required bool ok,
    required VoidCallback onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(
        ok ? Icons.check_circle : Icons.warning_amber_rounded,
        size: 15,
      ),
      label: Text(
        label,
        style: const TextStyle(fontSize: 10),
        overflow: TextOverflow.ellipsis,
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: ok ? Colors.greenAccent : Colors.orangeAccent,
        side: BorderSide(
          color: (ok ? Colors.greenAccent : Colors.orangeAccent).withOpacity(
            0.6,
          ),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  Widget _waInput({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: onChanged,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.greenAccent, fontSize: 11),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
        filled: true,
        fillColor: const Color(0xFF04121F),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.greenAccent.withOpacity(0.3)),
        ),
      ),
    );
  }

  Widget _waLogTile(AutoReplyLogEntry e) {
    final time =
        '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF04121F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                e.contact,
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Text(
                time,
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${e.incoming}  →  ${e.reply}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 3),
          Text(
            '${e.sent ? 'sent' : 'fail'} • ${e.channel} • ${e.source}'
            '${e.important ? ' • important' : ''}',
            style: TextStyle(
              color: e.sent ? Colors.greenAccent : Colors.redAccent,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _privacyCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF04121F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.cyanAccent.withOpacity(0.25)),
      ),
      child: const Row(
        children: [
          Icon(Icons.lock_outline, color: Colors.cyanAccent),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'কী আর মডেল লিস্ট কোডে বা APK-তে থাকে না। '
              'Flutter Secure Storage (Android Keystore) -এ এনক্রিপ্ট করে রাখা হয়।',
              style: TextStyle(color: Colors.cyanAccent, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelManagerCard() {
    final s = SettingsService.instance;
    return Card(
      color: const Color(0xFF08182A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.cyanAccent.withOpacity(0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(
                  Icons.psychology_outlined,
                  color: Colors.cyanAccent,
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI Brain / Model Manager',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'সব মডেল এডিটেবল। কোনো ভার্সন কোডে লেখা নেই — '
              'ID আপডেট করলেই অ্যাপই নতুন মডেল চালাবে।',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 12),
            if (s.models.isEmpty)
              const Text(
                'এখনো কোনো মডেল নেই। নিচে Add বা Fetch চাপো Emon Bhai।',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              )
            else
              ...s.models.map((m) => _modelTile(m)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _miniButton(
                  icon: Icons.add,
                  label: 'Add New Model',
                  onPressed: () => _editModel(null),
                ),
                _miniButton(
                  icon: Icons.cloud_download_outlined,
                  label: _fetching ? 'Fetching...' : 'Fetch Latest Models',
                  onPressed: _fetching ? null : _fetchModels,
                ),
                _miniButton(
                  icon: Icons.upload_file_outlined,
                  label: 'Import JSON',
                  onPressed: _importJson,
                ),
                _miniButton(
                  icon: Icons.share_outlined,
                  label: 'Export JSON',
                  onPressed: _exportJson,
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Custom Model ID',
              style: TextStyle(
                color: Colors.cyanAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _customId,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'যেকোনো Model ID লিখো — instantly চলবে',
                hintStyle: TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Color(0xFF04121F),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.cyanAccent),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ModelProvider?>(
                    value: _customProvider,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF0A1B2E),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: 'Provider',
                      labelStyle: TextStyle(color: Colors.cyanAccent),
                    ),
                    items: [
                      const DropdownMenuItem<ModelProvider?>(
                        value: null,
                        child: Text('Auto-detect'),
                      ),
                      ...ModelProvider.values
                          .map(
                            (p) => DropdownMenuItem<ModelProvider?>(
                              value: p,
                              child: Text(p.label),
                            ),
                          ),
                    ],
                    onChanged: (v) => setState(() => _customProvider = v),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _addCustom,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyanAccent,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Add & Use Now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelTile(ModelEntry m) {
    final isDefault = m.key == SettingsService.instance.defaultModelKey;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF04121F),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDefault ? Colors.cyanAccent : Colors.white12,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isDefault
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            color: isDefault ? Colors.cyanAccent : Colors.white38,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Text(
                  '${m.provider.label} • '
                  '${m.id.isEmpty ? 'ID set korun' : m.id}'
                  '${m.starter ? ' • starter (editable)' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Set default',
            icon: const Icon(Icons.check_circle_outline, size: 18),
            color: isDefault ? Colors.cyanAccent : Colors.white54,
            onPressed: isDefault
                ? null
                : () async {
                    await SettingsService.instance.setDefault(m.key);
                    setState(() {});
                  },
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: Colors.cyanAccent,
            onPressed: () => _editModel(m),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, size: 18),
            color: Colors.redAccent,
            onPressed: () => _deleteModel(m),
          ),
        ],
      ),
    );
  }

  Widget _miniButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.cyanAccent,
        side: BorderSide(color: Colors.cyanAccent.withOpacity(0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }

  Widget _keyField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24),
        labelStyle: const TextStyle(color: Colors.cyanAccent),
        filled: true,
        fillColor: const Color(0xFF08182A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.cyanAccent.withOpacity(0.4)),
        ),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_off : Icons.visibility,
            color: Colors.cyanAccent,
          ),
          onPressed: onToggle,
        ),
      ),
    );
  }

  Widget _dropdownCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Card(
      color: const Color(0xFF08182A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.cyanAccent.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.cyanAccent, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}
