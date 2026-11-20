import 'dart:async';

import 'package:danawallet/global_functions.dart';
import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/widgets/skeletons/screen_skeleton.dart';
import 'package:danawallet/widgets/wallet/frigate_public_warning.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

/// Exclusive chain-backend choice: Blindbit or Frigate.
///
/// Saving a Frigate URL always takes the public-server path. There is no
/// public/private toggle. After the probe passes, the existing blocking
/// privacy warning fires before the save commits (once per wallet). "No"
/// leaves the previous settings intact.
class ChainBackendScreen extends StatefulWidget {
  const ChainBackendScreen(
      {super.key,
      this.probe,
      this.restartStopTimeout = const Duration(seconds: 10)});

  /// Injectable Frigate probe (tests). Never a subscribe.
  final Future<void> Function(String url)? probe;

  /// Bound on the post-save Frigate stop() before the restart is abandoned.
  final Duration restartStopTimeout;

  @override
  State<ChainBackendScreen> createState() => _ChainBackendScreenState();
}

class _ChainBackendScreenState extends State<ChainBackendScreen> {
  final TextEditingController _blindbitController = TextEditingController();
  final TextEditingController _frigateController = TextEditingController();
  final SettingsRepository _settings = SettingsRepository.instance;

  Future<void> Function(String url) get _probe =>
      widget.probe ?? probeFrigateUrl;

  ChainBackendKind _selected = ChainBackendKind.blindbit;
  String? _inlineError;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrent());
  }

  Future<void> _loadCurrent() async {
    final kind = await _settings.getChainBackend();
    final blindbit = await _settings.getBlindbitUrl();
    final frigate = await _settings.getFrigateUrl();
    if (!mounted) return;
    setState(() {
      _selected = kind;
      if (blindbit != null) _blindbitController.text = blindbit;
      if (frigate != null) _frigateController.text = frigate;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    if (_selected == ChainBackendKind.frigate) {
      await _saveFrigate();
    } else {
      await _saveBlindbit();
    }
  }

  Future<void> _saveBlindbit() async {
    final url = _blindbitController.text.trim();
    setState(() {
      _inlineError = null;
      _saving = true;
    });

    final chainState = Provider.of<ChainState>(context, listen: false);
    if (url.isEmpty) {
      await _settings.setBlindbitUrl(null);
      await _settings.setChainBackend(ChainBackendKind.blindbit);
      await chainState.resetBlindbitUrl();
      await _stopFrigate();
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final success = await chainState.updateBlindbitUrl(url);
    if (!mounted) return;
    if (!success) {
      setState(() {
        _inlineError = 'Failed to update the Blindbit URL';
        _saving = false;
      });
      return;
    }

    await _settings.setBlindbitUrl(url);
    await _settings.setChainBackend(ChainBackendKind.blindbit);
    displayNotification('Setting blindbit url to $url');
    await _stopFrigate();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveFrigate() async {
    final url = _frigateController.text.trim();
    setState(() {
      _inlineError = null;
      _saving = true;
    });

    try {
      await _probe(url);
    } on FrigateProbeException catch (e) {
      if (!mounted) return;
      setState(() {
        _inlineError = e.message;
        _saving = false;
      });
      return;
    }

    // Adding a Frigate server is the public-server case: the existing
    // blocking warning gates the save. An already-acked wallet does not
    // see it again. "No" aborts with the previous settings intact.
    final acked =
        await FrigateDisclosureRepository.instance.isPublicWarningAcked();
    if (!mounted) return;
    if (!acked) {
      setState(() => _saving = false);
      final accepted = await showFrigatePublicWarningDialog(context);
      if (!mounted || !accepted) return;
      await FrigateDisclosureRepository.instance.ackPublicWarning();
      if (!mounted) return;
      setState(() => _saving = true);
    }

    await _settings.setFrigateUrl(url);
    await _settings.setFrigatePublic(true);
    await _settings.setChainBackend(ChainBackendKind.frigate);
    await FrigateDisclosureRepository.instance.recordIfNew(url);
    Logger().i(
        'frigate backend set to $url after a successful probe and the public '
        'warning path');

    if (!mounted) return;
    await _restartFrigate();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _stopFrigate() async {
    try {
      final controller =
          Provider.of<FrigateSubscriptionController>(context, listen: false);
      try {
        await controller.stop().timeout(widget.restartStopTimeout);
      } on TimeoutException {
        Logger().w('frigate stop: stop() did not return within '
            '${widget.restartStopTimeout.inSeconds}s');
      }
    } catch (e) {
      Logger().w('frigate stop after switching to Blindbit failed: $e');
    }
  }

  Future<void> _restartFrigate() async {
    var stopped = false;
    try {
      final controller =
          Provider.of<FrigateSubscriptionController>(context, listen: false);
      try {
        await controller.stop().timeout(widget.restartStopTimeout);
        stopped = true;
      } on TimeoutException {
        Logger().w('frigate restart: stop() did not return within '
            '${widget.restartStopTimeout.inSeconds}s — restart abandoned, '
            'the subscription re-evaluates on its next service start');
      }
      if (stopped) unawaited(controller.start());
    } catch (e) {
      Logger().w('frigate restart after backend change failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final frigate = _selected == ChainBackendKind.frigate;
    return ScreenSkeleton(
      showBackButton: true,
      title: 'Chain backend',
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  title: const Text('Blindbit'),
                  subtitle: const Text(
                      'Index server used for chain sync and broadcast'),
                  trailing: !frigate
                      ? const Icon(Icons.check_circle)
                      : const Icon(Icons.circle_outlined),
                  onTap: _saving
                      ? null
                      : () => setState(() {
                            _selected = ChainBackendKind.blindbit;
                            _inlineError = null;
                          }),
                ),
                ListTile(
                  title: const Text('Frigate'),
                  subtitle: const Text(
                      'Scan-key server. Saving warns about privacy leaks'),
                  trailing: frigate
                      ? const Icon(Icons.check_circle)
                      : const Icon(Icons.circle_outlined),
                  onTap: _saving
                      ? null
                      : () => setState(() {
                            _selected = ChainBackendKind.frigate;
                            _inlineError = null;
                          }),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller:
                      frigate ? _frigateController : _blindbitController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Backend URL',
                    hintText: frigate
                        ? 'frigate.example.org:50002'
                        : 'https://example.com/blindbit',
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
                if (!frigate)
                  ListTile(
                    leading: const Icon(Icons.restart_alt),
                    title: const Text('Reset to default'),
                    subtitle: const Text(
                        'Use the built-in Blindbit server for this network'),
                    onTap: _saving
                        ? null
                        : () {
                            _blindbitController.clear();
                            unawaited(_saveBlindbit());
                          },
                  ),
                ListTile(
                  leading: const Icon(Icons.save_outlined),
                  title: Text(_saving
                      ? (frigate ? 'Probing backend…' : 'Saving…')
                      : 'Save backend'),
                  subtitle: Text(frigate
                      ? 'The backend is probed before saving'
                      : 'The server is checked before saving'),
                  onTap: _saving ? null : () => unawaited(_save()),
                ),
              ],
            ),
    );
  }

  @override
  void dispose() {
    _blindbitController.dispose();
    _frigateController.dispose();
    super.dispose();
  }
}
