import 'dart:convert';

import 'package:crypto/crypto.dart';

String collapseWhitespace(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

String normalizedText(String value) => collapseWhitespace(value).toLowerCase();

String stableHash(Iterable<Object?> values) {
  final canonical = values
      .map((value) => value?.toString() ?? '')
      .join('\u001f');
  return sha256.convert(utf8.encode(canonical)).toString();
}

String stableId(Iterable<Object?> values) =>
    stableHash(values).substring(0, 32);

String slugify(String value) {
  const replacements = <String, String>{
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  var result = normalizedText(value);
  replacements.forEach((source, replacement) {
    result = result.replaceAll(source, replacement);
  });
  return result
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

String stripFileName(String value) {
  var result = collapseWhitespace(value)
      .replaceFirst(RegExp(r'^Drive,\s*', caseSensitive: false), '')
      .replaceFirst(
        RegExp(r'\.(mp4|mkv|avi|mov|webm)$', caseSensitive: false),
        '',
      )
      .replaceFirst(RegExp(r'^\d{1,3}\s*[xX×]\s*\d{1,3}\s*[-–—:]?\s*'), '')
      .trim();
  if (!result.contains(' ') && RegExp(r'[-_]').hasMatch(result)) {
    result = collapseWhitespace(result.replaceAll(RegExp(r'[-_]+'), ' '));
  }
  return result.replaceAll(
    RegExp(r'\bsubtitulos\b', caseSensitive: false),
    'subtítulos',
  );
}

Uri canonicalPageUri(Uri value) => Uri(
  scheme: value.scheme,
  userInfo: value.userInfo,
  host: value.host,
  port: value.hasPort ? value.port : null,
  path: value.path,
);
