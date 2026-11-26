// B5.5 — the frigate tip source: foreign tips rejected, no silent fallback.
//
// The chain tip on the frigate path comes ONLY from the selected backend's
// session (docs/BEHAVIOR.md B5.5, carried from v0.1 B5.1-B5.2). The single
// Dart adopter of session tips is FrigateState.applyLifecycle — the
// subscription controller feeds every session event through it (both the
// app isolate and the foreground-service path), so the tip-source guard
// lives exactly there and holds for every consumer. A tip from any other
// origin cannot reach the adopter (the Rust side holds a single
// subscription sink, B1.3); the guard pins the remaining foreign-tip
// surface: a payload that is not a well-formed chain tip is rejected
// rather than silently adopted.
//
// This suite pins:
//   (a) a foreign/malformed tip payload is REJECTED, never adopted;
//   (b) NO silent fallback: on rejection the tip height, the catch-up bar
//       and the reachability banner stay exactly as they were — no reset to
//       defaults, no stale wipe, and a foreign tip is never mistaken for a
//       successful interaction with the selected backend (B4.4 interplay);
//   (c) the rejection is observable on the caller/UI path, not swallowed
//       (FrigateState.lastTipRejection, listeners notified).
//
// Removing the validation guard reintroduces silent adoption of foreign
// tips and fails (a)/(b); reintroducing any fallback-to-defaults fails (b).
import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// A well-formed 32-byte block-hash digest (the shape a genuine session tip
/// carries). Tests that assert ADOPTION must use this, so the suite cannot
/// pass on a fixture that the guard would legitimately reject.
const validTipHash =
    '0000000000000000000000000000000000000000000000000000000000000100';

void main() {
  group('B5.5 frigate tip source — foreign tips rejected, no silent fallback',
      () {
    late FrigateState state;

    setUp(() {
      state = FrigateState();
    });

    test('positive control: a well-formed session tip is adopted', () {
      state.applyLifecycle(
          const FrigateEventDto.tip(height: 900, hash: validTipHash));
      expect(state.catchUpBarVisible, isTrue,
          reason: 'a genuine tip from the selected backend shows the bar');
      expect(state.lastTipRejection, isNull,
          reason: 'a genuine tip is never a rejection');
    });

    test(
        'B5.5 (a): malformed tip payload (non-hex block hash) is rejected — '
        'never adopted as the tip', () {
      state.applyLifecycle(
          const FrigateEventDto.tip(height: 900, hash: validTipHash));
      state.applyLifecycle(
          const FrigateEventDto.tip(height: 999999, hash: 'not-a-block-hash'));

      // The progress denominator is still the GENUINE tip: the foreign tip
      // was never adopted.
      state.applyLifecycle(const FrigateEventDto.confirmed(
          blkheight: 450, blkhash: validTipHash, foundOutputs: []));
      expect(state.catchUpProgress, closeTo(0.5, 1e-9),
          reason: 'the rejected tip (999999) never became the denominator — '
              'progress is 450/900 against the last valid session tip');
    });

    test('B5.5 (a): non-positive tip height is rejected', () {
      state.applyLifecycle(
          const FrigateEventDto.tip(height: 900, hash: validTipHash));
      state.applyLifecycle(
          const FrigateEventDto.tip(height: 0, hash: validTipHash));

      state.applyLifecycle(const FrigateEventDto.confirmed(
          blkheight: 450, blkhash: validTipHash, foundOutputs: []));
      expect(state.catchUpProgress, closeTo(0.5, 1e-9),
          reason: 'height 0 is not a block height — the tip was not adopted');
    });

    test(
        'B5.5 (b): rejection never silently falls back — bar, progress and '
        'reachability banner stay exactly as they were', () {
      state.applyLifecycle(
          const FrigateEventDto.tip(height: 900, hash: validTipHash));
      state.applyLifecycle(const FrigateEventDto.confirmed(
          blkheight: 450, blkhash: validTipHash, foundOutputs: []));
      state.markUnreachable();

      state.applyLifecycle(
          const FrigateEventDto.tip(height: 0, hash: validTipHash));

      expect(state.backendUnreachable, isTrue,
          reason: 'a foreign tip is NOT a successful interaction with the '
              'selected backend — the unreachable banner must not clear '
              '(B5.5 x B4.4)');
      expect(state.catchUpBarVisible, isTrue,
          reason: 'no reset to defaults: the bar keeps its state');
      expect(state.catchUpProgress, closeTo(0.5, 1e-9),
          reason: 'no stale wipe: the determinate basis survives the '
              'rejection untouched');
    });

    test(
        'B5.5 (c): the rejection is surfaced on the caller/UI path, not '
        'swallowed', () {
      var notifications = 0;
      state.addListener(() => notifications++);

      state.applyLifecycle(
          const FrigateEventDto.tip(height: 999999, hash: 'nothex'));

      expect(state.lastTipRejection, isNotNull,
          reason: 'the rejection reason is observable, never swallowed');
      expect(state.lastTipRejection, contains('foreign tip rejected'),
          reason: 'the surfaced error stays human-readable');
      expect(notifications, greaterThan(0),
          reason: 'listeners (the UI path) are notified of the rejection');
    });

    test(
        'B5.5 (c): the rejection flag never goes stale — the next accepted '
        'tip clears it', () {
      state.applyLifecycle(
          const FrigateEventDto.tip(height: 999999, hash: 'nothex'));
      expect(state.lastTipRejection, isNotNull);

      state.applyLifecycle(
          const FrigateEventDto.tip(height: 900, hash: validTipHash));
      expect(state.lastTipRejection, isNull,
          reason: 'the next genuine session tip clears the rejection');
    });
  });
}
