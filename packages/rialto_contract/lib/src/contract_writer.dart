import 'dart:convert';
import 'dart:io';

/// Writes a contract as YAML in block style; strings are quoted when YAML would read them otherwise.
class ContractWriter {
  static void write(Map<String, Object?> contract, String file) {
    File(file)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(toYaml(contract));
  }

  static String toYaml(Map<String, Object?> contract) {
    final out = StringBuffer();
    _map(contract, 0, out);
    return out.toString();
  }

  static bool _empty(Object? value) =>
      value == null || (value is Map && value.isEmpty) || (value is List && value.isEmpty);

  static void _map(Map<Object?, Object?> map, int indent, StringBuffer out) {
    map.forEach((key, value) {
      if (_empty(value)) return;
      out.write('${' ' * indent}${_scalar(key.toString())}:');
      _value(value, indent, out);
    });
  }

  static void _value(Object? value, int indent, StringBuffer out) {
    if (value is Map) {
      out.writeln();
      _map(value, indent + 2, out);
    } else if (value is List) {
      out.writeln();
      for (final item in value) {
        out.write('${' ' * (indent + 2)}-');
        if (item is Map) {
          out.writeln();
          _map(item, indent + 4, out);
        } else {
          out.writeln(' ${_scalar(item)}');
        }
      }
    } else {
      out.writeln(' ${_scalar(value)}');
    }
  }

  static final _plain = RegExp(r'^[A-Za-z_/][A-Za-z0-9_ .#/<>,?()\-]*$');
  static const _reserved = {'true', 'false', 'null', 'yes', 'no', 'on', 'off', 'y', 'n', '~'};

  static String _scalar(Object? value) {
    if (value is! String) return jsonEncode(value);
    final plain =
        _plain.hasMatch(value) &&
        !value.endsWith(' ') &&
        !value.contains(' #') &&
        !_reserved.contains(value.toLowerCase());
    return plain ? value : jsonEncode(value);
  }
}
