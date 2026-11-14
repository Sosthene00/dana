import 'dart:async';

import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:danawallet/widgets/skeletons/screen_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

/// B5.1/B5.2: the frigate backend declaration screen — URL plus a
/// public/private declaration whose default is PRIVATE (public is always
/// opt-in, never a default or a promotion).
///
/// The URL is probed (parse + reachability, NEVER a subscribe handshake —
/// a probe must not burn the scan key, B5.1) before anything is saved. On
/// probe failure the screen stays open with a persistent inline error and
/// the typed URL is preserved (B5.1).
class FrigateBackendScreen extends StatefulWidget {
  const FrigateBackendScreen({super.key});

  @override
  State<FrigateBackendScreen> createState() => _FrigateBackendScreenState();
}

class _FrigateBackendScreenState extends State<FrigateBackendScreen> {
  final TextEditingController _urlController = TextEditingController();
  final SettingsRepository _settings = SettingsRepository.instance;

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
      await probeFrigateUrl(url);
    } on FrigateProbeException catch (e) {
      if (!mounted) return;
      setState(() {
        // Persistent inline error; the typed URL is preserved (B5.1).
        _inlineError = e.message;
        _saving = false;
      });
      return;
    }

    await _settings.setFrigateUrl(url);
    await _settings.setFrigatePublic(_isPublic);
    Logger().i(
        'frigate backend set to $url (public: $_isPublic) after a successful B5.1 probe');

    if (!mounted) return;

    // A changed URL or declaration takes effect on the next subscription
    // start: stop the app-side leg so the gate re-evaluates (the service
    // isolate re-evaluates on its own retry loop).
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
                      'Anyone can reach this backend; a one-time warning '
                      'explains the privacy cost before the first public sync'),
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
