// Redact at the output boundary; connection URLs themselves must stay intact.
String redactLogText(String text, {Iterable<String> secrets = const []}) {
  var result = text.replaceAllMapped(
    RegExp(r'([a-z][a-z0-9+.-]*://)[^\s/?#]*@', caseSensitive: false),
    (match) => '${match[1]}[redacted]@',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'''([?&](?:password|passwd|pass|pwd|token|access_token|access[_-]?code|api[_-]?key|auth|signature)=)[^&#\s"']*''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[redacted]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'''((?:proxy-)?authorization\s*:\s*(?:basic|bearer)\s+)[^\s"']+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[redacted]',
  );
  // Native errors can quote a password on its own, outside a URL or header.
  final variants = <String>{};
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    variants.addAll([secret, Uri.encodeComponent(secret)]);
  }
  final ordered = variants.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (ordered.isNotEmpty) {
    result = result.replaceAll(
      RegExp(ordered.map(RegExp.escape).join('|')),
      '[redacted]',
    );
  }
  return result;
}
