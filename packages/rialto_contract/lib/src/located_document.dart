import 'dart:io';

import 'package:yaml/yaml.dart';

import 'diagnostics.dart';

/// A YAML or JSON document as plain Dart values, with the line and column of every element.
/// Where an element was read: its file, which differs per fragment of a contract over several files (K5.5), line and column.
typedef Position = (String file, int line, int column);

class LocatedDocument {
  /// A document from [positions] that may span files; [file] is the root (see ContractFiles).
  LocatedDocument.bundled(this.file, this.root, this.positions);

  final String file;

  /// Maps, lists, strings, numbers, booleans and null.
  final Object? root;

  /// The position of every element, by JSON Pointer.
  final Map<String, Position> positions;

  /// Reads [path]; JSON is read as YAML, of which it is a subset.
  factory LocatedDocument.read(String path) => LocatedDocument.parse(File(path).readAsStringSync(), path);

  /// Parses [text] as the document at [path], which need not exist.
  factory LocatedDocument.parse(String text, String path) {
    final node = loadYamlNode(text, sourceUrl: Uri.file(path));
    final lines = <String, (int, int)>{};
    final root = _plain(node, '', lines);
    return LocatedDocument.bundled(path, root, {
      for (final entry in lines.entries) entry.key: (path, entry.value.$1, entry.value.$2),
    });
  }

  /// Reads [path] like [LocatedDocument.read] and requires a mapping at the top, as every contract and
  /// fragment is. Anything else, such as a list or a single value, throws, which callers report as RIALTO-K001.
  /// An empty file reads as an empty mapping, as on the JVM.
  factory LocatedDocument.readMapping(String path) {
    final document = LocatedDocument.read(path);
    final root = document.root;
    if (root is Map) return document;
    if (root == null && File(path).readAsStringSync().trim().isEmpty) {
      return LocatedDocument.bundled(path, <String, Object?>{}, document.positions);
    }
    final found = root is List ? 'a list' : (root == null ? 'null' : 'a single value');
    throw FormatException('The document is not a mapping but $found');
  }

  /// Escapes one JSON Pointer segment (RFC 6901).
  static String segment(String name) => name.replaceAll('~', '~0').replaceAll('/', '~1');

  /// The location of [pointer], or of its nearest ancestor with a known position.
  Location locate(String pointer) {
    var current = pointer;
    while (true) {
      final position = positions[current];
      if (position != null) return Location(position.$1, line: position.$2, column: position.$3, pointer: pointer);
      if (current.isEmpty) return Location(file, pointer: pointer);
      final slash = current.lastIndexOf('/');
      current = slash <= 0 ? '' : current.substring(0, slash);
    }
  }

  /// The element at [pointer], or null when there is none.
  Object? at(String pointer) => elementAt(root, pointer);

  /// The element of [root] at [pointer] (RFC 6901), or null.
  static Object? elementAt(Object? root, String pointer) {
    if (pointer.isEmpty) return root;
    if (!pointer.startsWith('/')) return null;
    Object? current = root;
    for (final raw in pointer.substring(1).split('/')) {
      final key = raw.replaceAll('~1', '/').replaceAll('~0', '~');
      if (current is Map) {
        if (!current.containsKey(key)) return null;
        current = current[key];
      } else if (current is List) {
        final index = int.tryParse(key);
        if (index == null || index < 0 || index >= current.length) return null;
        current = current[index];
      } else {
        return null;
      }
    }
    return current;
  }

  static Object? _plain(YamlNode node, String pointer, Map<String, (int, int)> positions) {
    positions.putIfAbsent(pointer, () => (node.span.start.line + 1, node.span.start.column + 1));
    if (node is YamlMap) {
      final result = <String, Object?>{};
      node.nodes.forEach((key, value) {
        final name = (key as YamlNode).value.toString();
        final child = '$pointer/${segment(name)}';
        positions[child] = (key.span.start.line + 1, key.span.start.column + 1);
        result[name] = _plain(value, child, positions);
      });
      return result;
    }
    if (node is YamlList) {
      return [for (var i = 0; i < node.nodes.length; i++) _plain(node.nodes[i], '$pointer/$i', positions)];
    }
    return node.value;
  }
}

/// The text of [error] for a diagnostic message: what went wrong, without the name of the exception type. A YAML
/// error keeps its line and column.
String errorText(Object error) => switch (error) {
  YamlException() => '$error',
  FormatException(:final message) => message,
  FileSystemException(:final message, :final path, :final osError) =>
    '${osError?.message ?? message}${path == null || path.isEmpty ? '' : ': $path'}',
  HttpException(:final message) => message,
  _ => '$error',
};

/// Helpers to read plain JSON values.
Map<String, Object?> asMap(Object? value) => value is Map ? value.cast<String, Object?>() : const {};

List<Object?> asList(Object? value) => value is List ? value.cast<Object?>() : const [];

String? asString(Object? value) => value is String ? value : null;
