// GENERATED-PATCH-TARGET: this file is written to the worktree by the patch
// run. Full replacement of lib/data/models/name_server_info_response.dart.
// GET /info response (D12): the capability list is the challenge-auth
// availability surface. A missing or non-list `capabilities` field parses as
// an empty list so the flow's fail-closed gate (challenge-auth:v1 required,
// spec section 4) triggers naturally on servers that do not advertise the
// feature.
class NameServerInfoResponse {
  final String domain;
  final String network;
  final List<String> capabilities;

  const NameServerInfoResponse({
    required this.domain,
    required this.network,
    this.capabilities = const [],
  });

  factory NameServerInfoResponse.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final capabilities = <String>[];
    if (rawCapabilities is List) {
      for (final entry in rawCapabilities) {
        if (entry is String) capabilities.add(entry);
      }
    }
    return NameServerInfoResponse(
      domain: json['domain'] as String,
      network: json['network'] as String,
      capabilities: capabilities,
    );
  }
}
