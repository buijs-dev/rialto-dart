import 'dart:io';

import 'package:path/path.dart' as p;

import 'contract.dart';
import 'contract_files.dart';
import 'diagnostics.dart';
import 'located_document.dart';
import 'remote_sources.dart';
import 'sql_schema.dart';

/// An external document the contract refers to.
sealed class LoadedSource {
  const LoadedSource(this.name, this.file);
  final String name;
  final String file;
}

/// An OpenAPI or AsyncAPI document, addressed by JSON Pointer.
class DocumentSource extends LoadedSource {
  const DocumentSource(super.name, super.file, this.document);
  final LocatedDocument document;
}

/// A SQL schema, addressed by `table` or `table.column`.
class SqlSource extends LoadedSource {
  const SqlSource(super.name, super.file, this.schema);
  final Map<String, SqlTable> schema;

  /// The column names per table.
  Map<String, Set<String>> get tables => schema.map((name, table) => MapEntry(name, table.columns.keys.toSet()));
}

/// The result of resolving one reference.
enum Resolution { resolved, unknownSource, unloaded, missing }

/// The sources of one contract, and resolution of `<source>#<location>` references.
class Sources {
  const Sources(this.loaded);

  final Map<String, LoadedSource> loaded;

  (Resolution, LoadedSource?) resolve(String reference, Set<String> declared) {
    final hash = reference.indexOf('#');
    final name = hash < 0 ? reference : reference.substring(0, hash);
    final location = hash < 0 ? '' : reference.substring(hash + 1);
    if (!declared.contains(name)) return (Resolution.unknownSource, null);
    final source = loaded[name];
    if (source == null) return (Resolution.unloaded, null);
    final found = switch (source) {
      DocumentSource(:final document) => document.at(location) != null,
      SqlSource(:final schema) => () {
        final dot = location.indexOf('.');
        final table = schema[(dot < 0 ? location : location.substring(0, dot)).toLowerCase()];
        return table != null && (dot < 0 || table.columns.containsKey(location.substring(dot + 1).toLowerCase()));
      }(),
    };
    return (found ? Resolution.resolved : Resolution.missing, source);
  }

  /// The SQL table `<source>#<table>` refers to, or null.
  SqlTable? table(String reference) {
    final hash = reference.indexOf('#');
    final source = loaded[hash < 0 ? reference : reference.substring(0, hash)];
    return source is SqlSource ? source.schema[(hash < 0 ? '' : reference.substring(hash + 1)).toLowerCase()] : null;
  }

  /// The element a document reference points at, or null.
  Object? element(String reference) {
    final hash = reference.indexOf('#');
    if (hash < 0) return null;
    final source = loaded[reference.substring(0, hash)];
    return source is DocumentSource ? source.document.at(reference.substring(hash + 1)) : null;
  }

  /// Loads every source of [contract], reporting the ones that cannot be read. A remote source (K4) is
  /// read from the cache, or from what [fetched] holds (see [RemoteSources.prefetch]), as [remote] says.
  static Sources load(
    Contract contract,
    LocatedDocument contractDocument,
    Diagnostics diagnostics, {
    RemoteMode remote = RemoteMode.locked,
    RemoteFetches? fetched,
  }) {
    final base = p.dirname(p.absolute(contractDocument.file));
    final loaded = <String, LoadedSource>{};
    final session = RemoteSession(contractDocument.file, remote, diagnostics, fetched);
    contract.sources.forEach((name, value) {
      final source = asMap(value);
      final path = source['path'] as String;
      final pointer = '/sources/${LocatedDocument.segment(name)}/path';
      if (source['kind'] == 'sql' && path.contains('*')) {
        // A service's migrations (K1.9): the schema is the result of all of them, in version order.
        final files = migrations(base, path);
        if (files.isEmpty) {
          diagnostics.error(
            Code.sourceUnreadable,
            "Source '$name' matches no migration: $path",
            contractDocument.locate(pointer),
          );
        } else {
          // One statement never spans two files.
          final sql = files.map((f) => File(f).readAsStringSync()).join(';\n');
          loaded[name] = SqlSource(name, p.dirname(files.first), SqlSchema.read(sql));
        }
        return;
      }
      final String file;
      if (RemoteSources.isRemote(path)) {
        final cached = session.resolve(path, contractDocument.locate(pointer));
        if (cached == null) return;
        file = cached;
      } else {
        file = p.normalize(p.join(base, path));
      }
      if (!File(file).existsSync()) {
        diagnostics.error(Code.sourceUnreadable, "Source '$name' not found: $path", contractDocument.locate(pointer));
        return;
      }
      try {
        loaded[name] = source['kind'] == 'sql'
            ? SqlSource(name, file, SqlSchema.read(File(file).readAsStringSync()))
            : DocumentSource(name, file, LocatedDocument.read(file));
      } catch (e) {
        diagnostics.error(
          Code.sourceUnreadable,
          "Source '$name' cannot be read: ${errorText(e)}",
          contractDocument.locate(pointer),
        );
      }
    });
    session.finish();
    return Sources(loaded);
  }
}

/// The files an SQL source path with `*` or `**` matches (K1.9), in version order: the number after a
/// leading `V` up to `__`, part by part; files without a version follow in code point order.
List<String> migrations(String base, String path) {
  final segments = path.split('/');
  final fixed = segments.takeWhile((segment) => !segment.contains('*')).toList();
  final directory = p.normalize(p.join(base, fixed.join('/')));
  if (!Directory(directory).existsSync()) return const [];
  final pattern = ContractFiles.glob(segments.skip(fixed.length).join('/'));
  final files = Directory(directory)
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.path)
      .where((file) => pattern.hasMatch(p.posix.joinAll(p.split(p.relative(file, from: directory)))))
      .toList();
  List<int>? version(String file) => RegExp(
    r'^V(\d+(?:[._]\d+)*)__',
  ).firstMatch(p.basename(file))?.group(1)!.split(RegExp('[._]')).map(int.parse).toList();
  files.sort((a, b) {
    final (va, vb) = (version(a), version(b));
    if (va != null && vb != null) {
      for (var i = 0; i < va.length && i < vb.length; i++) {
        if (va[i] != vb[i]) return va[i].compareTo(vb[i]);
      }
      return va.length.compareTo(vb.length);
    }
    if (va != null) return -1;
    if (vb != null) return 1;
    return a.compareTo(b);
  });
  return files;
}

/// Navigates schemas of one OpenAPI document, following local `$ref`s.
class OpenApiSchemas {
  OpenApiSchemas(Sources sources, String source)
    : _root = switch (sources.loaded[source]) {
        DocumentSource(:final document) => document.root,
        _ => null,
      };

  final Object? _root;

  /// [node] itself, or the element its local `$ref` points at.
  Map<String, Object?>? resolve(Object? node) {
    final target = this.target(node);
    return target is Map ? asMap(target) : null;
  }

  /// [node] itself, or the element its local `$ref` points at, as the document holds it, so that
  /// [identical] tells whether two references name one schema; null when a `$ref` does not resolve.
  Object? target(Object? node) {
    var current = node;
    for (var i = 0; i < 16; i++) {
      final ref = asMap(current)[r'$ref'];
      if (ref is! String) return current;
      if (!ref.startsWith('#')) return null;
      current = LocatedDocument.elementAt(_root, ref.substring(1));
      if (current == null) return null;
    }
    return null;
  }

  Map<String, Object?>? successSchema(Map<String, Object?> operation) =>
      _responseSchema(operation, (code) => code.startsWith('2'));

  Map<String, Object?>? problemSchema(Map<String, Object?> operation) =>
      _responseSchema(operation, (code) => code.startsWith('4') || code.startsWith('5'));

  Map<String, Object?>? _responseSchema(Map<String, Object?> operation, bool Function(String) status) {
    final responses = asMap(operation['responses']);
    for (final code in responses.keys.where(status)) {
      final response = resolve(responses[code]);
      final content = asMap(response?['content']);
      for (final type in content.keys.where((it) => it.contains('json'))) {
        final schema = asMap(content[type])['schema'];
        if (schema != null) return resolve(schema);
      }
    }
    return null;
  }

  /// The JSON schema of the request body, or null when the operation has none.
  Map<String, Object?>? requestSchema(Map<String, Object?> operation) {
    final content = asMap(resolve(operation['requestBody'])?['content']);
    for (final type in content.keys.where((it) => it.contains('json'))) {
      // The first JSON media type whose schema resolves, as on the JVM.
      final resolved = resolve(asMap(content[type])['schema']);
      if (resolved != null) return resolved;
    }
    return null;
  }

  /// The names of the top-level properties of an object [schema], including those composed with `allOf`.
  Set<String> propertyNames(Map<String, Object?> schema) {
    final resolved = resolve(schema);
    if (resolved == null) return const {};
    return {for (final candidate in _candidates(resolved)) ...asMap(candidate['properties']).keys};
  }

  /// The names an object [schema] lists as `required`, including those composed with `allOf`.
  Set<String> requiredNames(Map<String, Object?> schema) {
    final resolved = resolve(schema);
    if (resolved == null) return const {};
    return {for (final candidate in _candidates(resolved)) ...asList(candidate['required']).map((it) => '$it')};
  }

  /// Whether [schema] is an array: its `type` is or includes `array`.
  bool isArray(Object? schema) {
    final type = resolve(schema)?['type'];
    return type is List ? type.any((it) => it == 'array') : type == 'array';
  }

  /// Whether [schema] is an object: its `type` is or includes `object`, or it has properties.
  bool isObject(Object? schema) {
    final resolved = resolve(schema);
    if (resolved == null) return false;
    return _candidates(resolved).any((it) => _types(it).contains('object') || it.containsKey('properties'));
  }

  /// Whether [schema] is an integer: its `type` is or includes `integer`.
  bool isInteger(Object? schema) {
    final resolved = resolve(schema);
    return resolved != null && _types(resolved).contains('integer');
  }

  static List<String> _types(Map<String, Object?> schema) => switch (schema['type']) {
    List list => [for (final it in list) '$it'],
    null => const [],
    final type => ['$type'],
  };

  /// The schema of the property [pointer] (`/a/b`) inside an object [schema], or null.
  Map<String, Object?>? property(Map<String, Object?> schema, String pointer) {
    var current = resolve(schema);
    if (current == null) return null;
    for (final raw in pointer.split('/').where((it) => it.isNotEmpty)) {
      final name = raw.replaceAll('~1', '/').replaceAll('~0', '~');
      Map<String, Object?>? next;
      for (final candidate in _candidates(current!)) {
        final property = asMap(candidate['properties'])[name];
        if (property != null) {
          next = resolve(property);
          break;
        }
      }
      if (next == null) return null;
      current = next;
    }
    return current;
  }

  List<Map<String, Object?>> _candidates(Map<String, Object?> schema) => [
    schema,
    for (final part in asList(schema['allOf'])) ...?(resolve(part) == null ? null : _candidates(resolve(part)!)),
  ];
}
