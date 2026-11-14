/// A parsed type expression of the contract format, such as `decimal(8,3)` or `list<string?>`.
sealed class TypeExpression {
  const TypeExpression();

  /// The named types this expression refers to.
  List<String> names() => switch (this) {
    ScalarType() => const [],
    NamedType(:final name) => [name],
    ListType(:final element) => element.names(),
    SetType(:final element) => element.names(),
    MapType(:final key, :final value) => [...key.names(), ...value.names()],
  };

  static const scalars = {
    'boolean',
    'int32',
    'int64',
    'decimal',
    'float64',
    'string',
    'uuid',
    'date',
    'time',
    'localDateTime',
    'instant',
    'offsetDateTime',
    'zonedDateTime',
    'duration',
    'period',
    'bytes',
    'json',
    'binary',
  };

  /// Scalars that can be the key of a map.
  static const mapKeys = {'string', 'uuid', 'int32', 'int64', 'date'};

  static final _decimal = RegExp(r'^decimal\((\d+),(\d+)\)$');
  static final _name = RegExp(r'^[A-Z][A-Za-z0-9]*$');
  static final _collection = RegExp(r'^(list|set|map)<(.+)>$');

  /// Parses [text], or returns null when it is not a valid type expression.
  static TypeExpression? parse(String text) {
    final trimmed = text.trim();
    final collection = _collection.firstMatch(trimmed);
    if (collection != null) {
      final kind = collection.group(1)!;
      final arguments = collection.group(2)!;
      if (kind == 'map') return _parseMap(arguments);
      final element = _parseElement(arguments);
      if (element == null) return null;
      return kind == 'list' ? ListType(element.$1, element.$2) : SetType(element.$1, element.$2);
    }
    return _parseSingle(trimmed);
  }

  static TypeExpression? _parseMap(String arguments) {
    final comma = arguments.indexOf(',');
    if (comma < 0) return null;
    final key = _parseSingle(arguments.substring(0, comma).trim());
    if (key == null || (key is ScalarType && !mapKeys.contains(key.name))) return null;
    final value = _parseElement(arguments.substring(comma + 1));
    if (value == null) return null;
    return MapType(key, value.$1, value.$2);
  }

  static (TypeExpression, bool)? _parseElement(String text) {
    final trimmed = text.trim();
    final nullable = trimmed.endsWith('?');
    final single = _parseSingle(nullable ? trimmed.substring(0, trimmed.length - 1) : trimmed);
    return single == null ? null : (single, nullable);
  }

  static TypeExpression? _parseSingle(String text) {
    final decimal = _decimal.firstMatch(text);
    if (decimal != null) {
      final precision = int.parse(decimal.group(1)!);
      final scale = int.parse(decimal.group(2)!);
      return scale > precision ? null : ScalarType('decimal', precision, scale);
    }
    if (scalars.contains(text)) return ScalarType(text);
    if (_name.hasMatch(text)) return NamedType(text);
    return null;
  }
}

class ScalarType extends TypeExpression {
  const ScalarType(this.name, [this.precision, this.scale]);
  final String name;
  final int? precision;
  final int? scale;

  @override
  bool operator ==(Object other) =>
      other is ScalarType && other.name == name && other.precision == precision && other.scale == scale;

  @override
  int get hashCode => Object.hash(name, precision, scale);
}

class NamedType extends TypeExpression {
  const NamedType(this.name);
  final String name;

  @override
  bool operator ==(Object other) => other is NamedType && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

class ListType extends TypeExpression {
  const ListType(this.element, this.nullableElements);
  final TypeExpression element;
  final bool nullableElements;

  @override
  bool operator ==(Object other) =>
      other is ListType && other.element == element && other.nullableElements == nullableElements;

  @override
  int get hashCode => Object.hash('list', element, nullableElements);
}

class SetType extends TypeExpression {
  const SetType(this.element, this.nullableElements);
  final TypeExpression element;
  final bool nullableElements;

  @override
  bool operator ==(Object other) =>
      other is SetType && other.element == element && other.nullableElements == nullableElements;

  @override
  int get hashCode => Object.hash('set', element, nullableElements);
}

class MapType extends TypeExpression {
  const MapType(this.key, this.value, this.nullableValues);
  final TypeExpression key;
  final TypeExpression value;
  final bool nullableValues;

  @override
  bool operator ==(Object other) =>
      other is MapType && other.key == key && other.value == value && other.nullableValues == nullableValues;

  @override
  int get hashCode => Object.hash('map', key, value, nullableValues);
}
