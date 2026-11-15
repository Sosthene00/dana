import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

/// Device-class probe for the §6.3.2 encrypt-side KDF fallback.
///
/// §6.3.2: at encrypt time, if `ActivityManager.isLowRamDevice()` is true AND
/// the device cannot afford the 64 MiB default, the app MAY fall back to
/// m=32 MiB t=4 p=1 — visibly, never silently. On this codebase the low-RAM
/// flag IS the affordability signal we have: it marks the Go-class (≤1 GB /
/// 512 MB-era) devices the §6.3.1 analysis deems marginal, so a low-RAM
/// device uses the reduced profile and every other device keeps the default.
///
/// The fallback is encrypt-side only; restore reads header KDF params as
/// written and has no device-class logic (§6.3.2).
class DeviceCapabilityService {
  DeviceCapabilityService._();

  static final instance = DeviceCapabilityService._();

  static const MethodChannel _channel =
      MethodChannel('dev.silentpayments.danawallet/device');

  Future<bool> isLowRamDevice() async {
    try {
      return await _channel.invokeMethod<bool>('isLowRamDevice') ?? false;
    } on MissingPluginException {
      // Non-Android platforms: no low-RAM signal, keep the default profile.
      Logger().d('Device capability channel unavailable; assuming not low-RAM');
      return false;
    } on PlatformException catch (e) {
      Logger().w('isLowRamDevice probe failed; assuming not low-RAM: $e');
      return false;
    }
  }
}
