/// Outcome of asking the sync host to apply the committed chain backend
/// (review M-c: no silent apply loss).
///
/// Deliberately not a bare bool: each not-delivered value names the reason
/// so callers can surface the divergence to the user instead of pretending
/// the committed setting is already live.
enum BackendApplyResult {
  /// The host that holds the writer lease received (or performed) the
  /// scanner swap.
  delivered,

  /// Not delivered: no foreground service is running to receive the
  /// request and this isolate holds no in-process scanner. The committed
  /// setting takes effect on the next service start.
  noService,

  /// Not delivered: the in-process host apply threw. The committed
  /// setting and the running scanner diverge until a host restart.
  hostError;

  bool get isDelivered => this == delivered;
}

/// User-facing text for a not-delivered apply (M-c). One shared string so
/// every UI path (settings screen inline error, public-warning SnackBar)
/// names the same divergence.
const String backendApplyDivergenceMessage =
    'Saved, but the running scanner could not be switched — it will '
    'switch on next service start';
