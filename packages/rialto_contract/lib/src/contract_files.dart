import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
import 'package:path/path.dart' as p;

import 'contract_writer.dart';
import 'diagnostics.dart';
import 'located_document.dart';
import 'remote_sources.dart';
import 'schema.dart';

/// Reads a contract over several files (K5): the root and the fragments its `include` lists, merged
/// into the bundled form. A contract without `include` is read as it is. Every element keeps the
/// file and line it was read from, so diagnostics name the fragment (K5.5).
class ContractFiles {
  /// Sections merged per name; a name is declared in one file only.
  static const _keyed = {'types', 'shapes', 'operations', 'events', 'subscriptions', 'streams', 'storage', 'views'};

  /// Keys only the root declares.
  static const _rootOnly = {'info', 'sources', 'include'};

  static final JsonSchema _fragmentSchema = () {
    final schema = asMap(jsonDecode(contractSchema));
    return JsonSchema.create({
      r'$defs': schema[r'$defs'],
      'properties': schema['properties'],
      r'$ref': r'#/$defs/fragment',
    }, schemaVersion: SchemaVersion.draft2020_12);
  }();

  /// The bundled form of the contract at [root], or null when the root cannot be read. Findings,
  /// such as an include without a match or a name declared twice, go to [diagnostics].
  static LocatedDocument? read(String root, Diagnostics diagnostics) {
    final LocatedDocument document;
    try {
      document = LocatedDocument.readMapping(root);
    } catch (e) {
      diagnostics.error(Code.unreadable, '$e', Location(root));
      return null;
    }

    final include = asMap(document.root)['include'];
    if (include == null) return document;
    final bundle = _Bundle(document);
    for (final fragment in _fragments(root, asList(include), document, diagnostics)) {
      bundle.add(fragment, diagnostics);
    }
    return bundle.document();
  }

  /// The fragments of the contract at [root], for build tools that track their inputs; empty without `include`.
  static List<String> fragments(String root) {
    try {
      final document = LocatedDocument.read(root);
      final include = asMap(document.root)['include'];
      return include == null ? const [] : _fragments(root, asList(include), document, Diagnostics());
    } catch (_) {
      return const [];
    }
  }

  /// Writes the bundled form of the contract at [root] to [output] (`rialto bundle`); false when it has errors.
  static bool bundle(String root, String output, Diagnostics diagnostics) {
    final document = read(root, diagnostics);
    if (document == null || diagnostics.hasErrors) return false;

    // Local source paths are relative to the contract, so they follow it to its new place.
    final from = p.dirname(p.absolute(root));
    final to = p.dirname(p.absolute(output));
    final bundled = Map<String, Object?>.of(asMap(document.root));
    final sources = asMap(bundled['sources']);
    if (sources.isNotEmpty) {
      bundled['sources'] = {
        for (final entry in sources.entries)
          entry.key: () {
            final source = Map<String, Object?>.of(asMap(entry.value));
            final path = asString(source['path']);
            if (path != null && !RemoteSources.isRemote(path)) {
              source['path'] = p.posix.joinAll(p.split(p.relative(p.normalize(p.join(from, path)), from: to)));
            }
            return source;
          }(),
      };
    }

    Directory(to).createSync(recursive: true);
    File(output).writeAsStringSync(ContractWriter.toYaml(bundled));
    return true;
  }

  static List<String> _fragments(
    String root,
    List<Object?> include,
    LocatedDocument document,
    Diagnostics diagnostics,
  ) {
    final base = p.dirname(p.absolute(root));
    final self = p.normalize(p.absolute(root));
    final candidates = Directory(base)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) => p.normalize(file.absolute.path))
        .where((path) => path != self)
        .map((path) => p.posix.joinAll(p.split(p.relative(path, from: base))))
        .toList();

    final matched = <String>{};
    for (var index = 0; index < include.length; index++) {
      final pattern = asString(include[index]) ?? '';
      final regex = glob(pattern);
      final found = candidates.where(regex.hasMatch).toList();
      if (found.isEmpty) {
        diagnostics.error(
          Code.includeNoMatch,
          "include '$pattern' matches no file",
          document.locate('/include/$index'),
        );
      }
      matched.addAll(found);
    }

    final sorted = matched.toList()..sort();
    return [for (final path in sorted) p.join(base, path)];
  }

  /// A path pattern of `include`: `*` within one segment, `**` any number of segments, also none.
  static RegExp glob(String pattern) {
    final regex = pattern.split('/').map((segment) {
      if (segment == '**') return '(?:[^/]+/)*';
      return '${segment.split('*').map(RegExp.escape).join('[^/]*')}/';
    }).join();
    return RegExp('^${regex.substring(0, regex.length - 1)}\$');
  }
}

/// The root with the fragments merged into it, in reading order.
class _Bundle {
  _Bundle(this._root)
    : _merged = Map<String, Object?>.of(asMap(_root.root))..remove('include'),
      _positions = Map.of(_root.positions)
        ..removeWhere((pointer, _) => pointer == '/include' || pointer.startsWith('/include/')) {
    for (final key in _merged.keys) {
      if (ContractFiles._keyed.contains(key)) {
        for (final name in asMap(_merged[key]).keys) {
          _owner['$key/$name'] = _root.file;
        }
      } else if (key != 'mappings') {
        _owner[key] = _root.file;
      }
    }
  }

  final LocatedDocument _root;
  final Map<String, Object?> _merged;
  final Map<String, Position> _positions;

  /// Who declared each element of a keyed section (`types/Thing`) and each other top-level key.
  final _owner = <String, String>{};

  void add(String file, Diagnostics diagnostics) {
    final LocatedDocument fragment;
    try {
      fragment = LocatedDocument.readMapping(file);
    } catch (e) {
      diagnostics.error(Code.unreadable, '$e', Location(file));
      return;
    }

    final json = asMap(fragment.root);
    final version = json['rialto'];
    final expected = asMap(_root.root)['rialto'];
    if (version != expected) {
      diagnostics.error(
        Code.unsupportedVersion,
        "Fragment has format '${version ?? ''}', the root '$expected'",
        fragment.locate('/rialto'),
      );
      return;
    }

    final misplaced = json.keys.where(ContractFiles._rootOnly.contains).toList();
    for (final key in misplaced) {
      diagnostics.error(
        Code.fragmentRootKey,
        "'$key' belongs in the root, not in a fragment",
        fragment.locate('/${LocatedDocument.segment(key)}'),
      );
    }
    if (misplaced.isNotEmpty) return;

    final errors = ContractFiles._fragmentSchema.validate(fragment.root, validateFormats: true).errors;
    for (final error in errors) {
      diagnostics.error(Code.schema, error.message, fragment.locate(error.instancePath));
    }
    if (errors.isNotEmpty) return;

    json.forEach((key, value) {
      if (key == 'rialto') return;
      if (ContractFiles._keyed.contains(key)) {
        _section(fragment, key, asMap(value), diagnostics);
      } else if (key == 'mappings') {
        _mappings(fragment, asList(value));
      } else {
        _single(fragment, key, value, diagnostics);
      }
    });
  }

  LocatedDocument document() => LocatedDocument.bundled(_root.file, _merged, _positions);

  void _section(LocatedDocument fragment, String key, Map<String, Object?> value, Diagnostics diagnostics) {
    final section = Map<String, Object?>.of(asMap(_merged[key]));
    value.forEach((name, element) {
      final pointer = '/$key/${LocatedDocument.segment(name)}';
      final previous = _owner['$key/$name'];
      if (previous != null) {
        diagnostics.error(
          Code.duplicateName,
          "'$name' is already declared under $key in ${_relative(previous)}",
          fragment.locate(pointer),
        );
        return;
      }
      _owner['$key/$name'] = fragment.file;
      section[name] = element;
      _copy(fragment, pointer, pointer);
    });
    _merged[key] = section;
  }

  void _mappings(LocatedDocument fragment, List<Object?> value) {
    final mappings = List<Object?>.of(asList(_merged['mappings']));
    for (var index = 0; index < value.length; index++) {
      _copy(fragment, '/mappings/$index', '/mappings/${mappings.length}');
      mappings.add(value[index]);
    }
    _merged['mappings'] = mappings;
  }

  void _single(LocatedDocument fragment, String key, Object? value, Diagnostics diagnostics) {
    final pointer = '/${LocatedDocument.segment(key)}';
    final previous = _owner[key];
    if (previous != null) {
      diagnostics.error(
        Code.sectionTwice,
        "'$key' is already declared in ${_relative(previous)}; it belongs in one file",
        fragment.locate(pointer),
      );
      return;
    }
    _owner[key] = fragment.file;
    _merged[key] = value;
    _copy(fragment, pointer, pointer);
  }

  /// [file] relative to the root's directory, as a contract author reads it.
  String _relative(String file) =>
      p.posix.joinAll(p.split(p.relative(p.absolute(file), from: p.dirname(p.absolute(_root.file)))));

  /// Copies the positions of [from] and everything below it in [fragment] to [to] in the bundle.
  void _copy(LocatedDocument fragment, String from, String to) {
    fragment.positions.forEach((pointer, position) {
      if (pointer == from || pointer.startsWith('$from/')) _positions[to + pointer.substring(from.length)] = position;
    });
  }
}
