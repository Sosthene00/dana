/// A `POST /register` body.
///
/// A registration is only provable when BOTH challenge fields are present:
/// a nameserver enforcing the challenge handshake
/// (Sosthene00/dana-nameserver #20) 401s any request that omits either one,
/// so a half-populated body is always a client bug, never a valid state.
/// The pair is atomic and the violation unrepresentable:
/// - the default constructor accepts neither field (both default to null);
/// - the only path that attaches the proof is [withChallenge], whose
///   `nonce` and `signature` parameters are both `required` and non-empty —
///   there is no constructor, named or otherwise, that can set one without
///   the other, so no call-site validation loop is needed;
/// - [toJson] emits both fields or none, keeping the wire body consistent
///   with the invariant even if a future field-level mutation appeared.
class NameServerRegisterRequest {
  final String id;
  final String userName;
  final String domain;
  final String spAddress;

  /// Challenge nonce issued by `POST /challenge`; only ever non-null
  /// together with [signature] (see [withChallenge]).
  final String? nonce;

  /// BIP-340 signature over the server's challenge message; only ever
  /// non-null together with [nonce] (see [withChallenge]).
  final String? signature;

  const NameServerRegisterRequest({
    required this.id,
    required this.userName,
    required this.domain,
    required this.spAddress,
  }) : nonce = null,
       signature = null;

  const NameServerRegisterRequest._withChallengePair({
    required this.id,
    required this.userName,
    required this.domain,
    required this.spAddress,
    required this.nonce,
    required this.signature,
  });

  /// The only way to attach the challenge proof. Both fields are required
  /// and must be non-empty: a half-proven registration cannot be built.
  factory NameServerRegisterRequest.withChallenge({
    required String id,
    required String userName,
    required String domain,
    required String spAddress,
    required String nonce,
    required String signature,
  }) {
    if (nonce.isEmpty) {
      throw const FormatException(
        'NameServerRegisterRequest.withChallenge: nonce is required and '
        'must be non-empty (a registration is provable only with BOTH a '
        'challenge nonce and its signature)',
      );
    }
    if (signature.isEmpty) {
      throw const FormatException(
        'NameServerRegisterRequest.withChallenge: signature is required and '
        'must be non-empty (a registration is provable only with BOTH a '
        'challenge nonce and its signature)',
      );
    }
    return NameServerRegisterRequest._withChallengePair(
      id: id,
      userName: userName,
      domain: domain,
      spAddress: spAddress,
      nonce: nonce,
      signature: signature,
    );
  }

  Map<String, dynamic> toJson() {
    // The constructor invariant already rules out a half-populated pair;
    // the joint condition below keeps the emitted body atomic even if a
    // future change introduced field-level mutation.
    final bool proveChallenge = nonce != null && signature != null;
    return {
      'id': id,
      'user_name': userName,
      'domain': domain,
      'sp_address': spAddress,
      if (proveChallenge) 'nonce': nonce,
      if (proveChallenge) 'signature': signature,
    };
  }

  factory NameServerRegisterRequest.fromJson(Map<String, dynamic> json) {
    // Tolerant parse for tests/telemetry: these are client-sent fields the
    // server never echoes back, so a wire body carrying exactly one of the
    // pair is a protocol violation and is refused outright.
    final nonce = json['nonce'] as String?;
    final signature = json['signature'] as String?;
    final base = NameServerRegisterRequest(
      id: json['id'] as String,
      userName: json['user_name'] as String,
      domain: json['domain'] as String,
      spAddress: json['sp_address'] as String,
    );
    if (nonce == null && signature == null) {
      return base;
    }
    if (nonce == null || signature == null) {
      throw const FormatException(
        'NameServerRegisterRequest.fromJson: nonce and signature are '
        'atomic — a body carrying exactly one of the two is invalid',
      );
    }
    return NameServerRegisterRequest.withChallenge(
      id: base.id,
      userName: base.userName,
      domain: base.domain,
      spAddress: base.spAddress,
      nonce: nonce,
      signature: signature,
    );
  }
}
