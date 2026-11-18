import 'dart:async';

import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/widgets/wallet/frigate_public_warning.dart';
import 'package:danawallet/widgets/skeletons/screen_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

/// B5.1-B5.4: the frigate backend declaration screen — URL plus a
/// public/private declaration whose default is PRIVATE (public is always
/// opt-in, never a default or a promotion).
///
/// The URL is probed (parse + reachability, NEVER a subscribe handshake —
/// a probe must not burn the scan key, B5.1) before anything is saved. On
/// probe failure the screen stays open with a persistent inline error and
/// the typed URL is preserved (B5.1).
///
/// Owner ruling R12 (2026-11-18): with a PUBLIC declaration the blocking
/// two-harms warning gates the SAVE — after the probe passes, the warning
/// fires BEFORE the save commits; "No" aborts with the settings fully
/// intact, "Yes" persists the ack, the URL, the declaration and the
/// permanent disclosure record at save time (B5.2/B5.3/B5.4).
class FrigateBackendScreen extends StatefulWidget {
  const FrigateBackendScreen({super.key, this.probe});

  /// Injectable B5.1 probe (tests); defaults to the real probe. Never a
  /// subscribe — a probe must not burn the scan key (B5.1).
  final Future<void> Function(String url)? probe;

  @override
  State<FrigateBackendScreen> createState() => _FrigateBackendScreenState();
}

class _FrigateBackendScreenState extends State<FrigateBackendScreen> {
  final TextEditingController _urlController = TextEditingController();
  final SettingsRepository _settings = SettingsRepository.instance;

  Future<void> Function(String url) get _probe =>
      widget.probe ?? probeFrigateUrl;

  /// B5.2: the declaration defaults to private — public is opt-in.
  bool _isPublic = false;
  String? _inlineError;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrent());
  }

  Future<void> _loadCurrent() async {
    final url = await _settings.getFrigateUrl();
    if (!mounted) return;
    setState(() {
      if (url != null) _urlController.text = url;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    setState(() {
      _inlineError = null;
      _saving = true;
    });

    // B5.1: probe (parse + reachability, never a subscribe) BEFORE saving.
    try {
      await _probe(url);
    } on FrigateProbeException catch (e) {
      if (!mounted) return;
      setState(() {
        // Persistent inline error; the typed URL is preserved (B5.1).
        _inlineError = e.message;
        _saving = false;
      });
      return;
    }

    // B5.2/B5.3 (owner ruling R12, 2026-11-18): with a public declaration
    // the blocking two-harms warning gates the SAVE — it fires BEFORE the
    // save commits, exactly once per wallet (an already-acked wallet saving
    // another public URL never re-fires, B5.4/J1). "No" aborts: the old
    // URL/declaration/ack state is fully intact and the screen stays open.
    if (_isPublic) {
      final acked =
          await FrigateDisclosureRepository.instance.isPublicWarningAcked();
      if (!mounted) return;
      if (!acked) {
        setState(() => _saving = false);
        final accepted = await showFrigatePublicWarningDialog(context);
        if (!mounted || !accepted) {
          // "No": nothing persisted, nothing acknowledged (B5.3).
          return;
        }
        // B5.4: the per-wallet ack, persisted at save.
        await FrigateDisclosureRepository.instance.ackPublicWarning();
        if (!mounted) return;
        setState(() => _saving = true);
      }
    }

    await _settings.setFrigateUrl(url);
    await _settings.setFrigatePublic(_isPublic);
    // B5.4/J2 (R12): the disclosure record is written AT SAVE TIME — each
    // public URL + date is logged permanently, deduped per URL (the record
    // survives the wallet and is never cleared by resetAll).
    if (_isPublic) {
      await FrigateDisclosureRepository.instance.recordIfNew(url);
    }
    Logger().i(
        'frigate backend set to $url (public: $_isPublic) after a successful '
        'B5.1 probe${_isPublic ? ' and an acknowledged public warning' : ''}');

    if (!mounted) return;

    // R11 (owner ruling, 2026-11-18): the declaration takes effect
    // IMMEDIATELY on save — a successful save stops the app-side leg and
    // starts the subscription in-session with the freshly saved
    // URL/declaration, no app restart (the service isolate re-evaluates on
    // its own retry loop).
    try {
      final controller =
          Provider.of<FrigateSubscriptionController>(context, listen: false);
      await controller.stop();
      unawaited(controller.start());
    } catch (e) {
      Logger().w('frigate restart after declaration change failed: $e');
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenSkeleton(
      showBackButton: true,
      title: 'Frigate backend',
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Backend URL',
                    hintText: 'frigate.example.org:50002',
                  ),
                ),
                const SizedBox(height: 8),
                if (_inlineError != null)
                  Text(
                    _inlineError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                const SizedBox(height: 16),
                // B5.2: per-URL public/private declaration, default private.
                ListTile(
                  title: const Text('Private'),
                  subtitle: const Text(
                      'Only this device talks to the backend (recommended)'),
                  trailing: !_isPublic
                      ? const Icon(Icons.check_circle)
                      : const Icon(Icons.circle_outlined),
                  onTap: () => setState(() => _isPublic = false),
                ),
                ListTile(
                  title: const Text('Public'),
                  subtitle: const Text(
                      'Anyone can reach this backend; saving fires a one-time '
                      'warning explaining the privacy cost before the save '
                      'commits'),
                  trailing: _isPublic
                      ? const Icon(Icons.check_circle)
                      : const Icon(Icons.circle_outlined),
                  onTap: () => setState(() => _isPublic = true),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.save_outlined),
                  title: Text(_saving ? 'Probing backend…' : 'Save backend'),
                  subtitle: const Text('The backend is probed before saving'),
                  onTap: _saving ? null : () => unawaited(_save()),
                ),
              ],
            ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}
