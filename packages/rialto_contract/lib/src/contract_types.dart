import 'contract.dart';
import 'located_document.dart';
import 'type_expression.dart';

/// Looks up the properties of types and shapes, and the scalars they stand for.
class ContractTypes {
  const ContractTypes(this.contract);

  final Contract contract;

  /// The properties of a type or shape, following a projection to its source.
  Map<String, Object?>? propertiesOf(String name, [int depth = 0]) {
    if (depth > 16) return null;
    final type = contract.types[name];
    if (type != null) {
      final declaration = asMap(type);
      switch (declaration['kind']) {
        case 'entity' || 'value':
          return asMap(declaration['properties']);
        case 'union':
          final variants = asMap(
            declaration['variants'],
          ).values.map((name) => asMap(contract.types[name])).where((variant) => variant['kind'] == 'entity').toList();
          if (variants.isEmpty) return null;
          final first = variants.first;
          return Map.fromEntries(
            asMap(first['properties']).entries.where(
              (entry) =>
                  asList(first['identity']).contains(entry.key) &&
                  variants.every(
                    (variant) =>
                        asList(variant['identity']).contains(entry.key) &&
                        asMap(asMap(variant['properties'])[entry.key])['type'] == asMap(entry.value)['type'],
                  ),
            ),
          );
        case 'projection':
          // Each projection property is the property its source path ends in.
          final source = declaration['source'] as String;
          if (propertiesOf(source, depth + 1) == null) return null;
          return {
            for (final e in projectionPaths(declaration).entries)
              if (resolvePath(source, e.value) case (final property, _)) e.key: property,
          };
        default:
          return null;
      }
    }
    final shape = contract.shapes[name];
    return shape == null ? null : propertiesOf(asMap(shape)['source'] as String, depth + 1);
  }

  /// Per projection property its source path: `[id, state]` names them after their source,
  /// `{id: id, city: destination.city}` maps them.
  Map<String, String> projectionPaths(Map<String, Object?> projection) {
    final properties = projection['properties'];
    if (properties is List) return {for (final name in properties.whereType<String>()) name: name};
    return asMap(properties).map((name, path) => MapEntry(name, path as String));
  }

  /// A resolved property path: its final property and whether it crossed a collection.
  (Map<String, Object?>, bool)? resolvePath(String root, String path) {
    var owner = root;
    var crosses = false;
    Map<String, Object?>? property;
    for (final segment in path.split('.')) {
      final found = propertiesOf(owner)?[segment];
      if (found == null) return null;
      property = asMap(found);
      final expression = TypeExpression.parse(property['type'] as String);
      if (expression == null) return null;
      final element = switch (expression) {
        ListType(:final element) || SetType(:final element) => () {
          crosses = true;
          return element;
        }(),
        _ => expression,
      };
      // A scalar has no properties: a further segment does not resolve.
      owner = element is NamedType ? element.name : '';
    }
    return property == null ? null : (property, crosses);
  }

  /// Follows [path] from [root] as a view reads it (U5.11, U6.6): a shape gives only the properties it
  /// selects. The final property, the number of collections on the way, its own included, and whether one of
  /// them is a map; null when a segment does not resolve.
  (Map<String, Object?>, int, bool)? walk(String root, String path) {
    var owner = root;
    var collections = 0;
    var throughMap = false;
    Map<String, Object?>? property;
    for (final segment in path.split('.')) {
      final shape = contract.shapes[owner];
      if (shape != null && !asMap(asMap(shape)['properties']).containsKey(segment)) return null;
      final found = propertiesOf(owner)?[segment];
      if (found == null) return null;
      property = asMap(found);
      final expression = TypeExpression.parse(property['type'] as String);
      if (expression == null) return null;
      final element = switch (expression) {
        ListType(:final element) || SetType(:final element) => element,
        MapType(:final value) => value,
        _ => expression,
      };
      if (expression is ListType || expression is SetType || expression is MapType) collections++;
      if (expression is MapType) throughMap = true;
      owner = element is NamedType ? element.name : '';
    }
    return property == null ? null : (property, collections, throughMap);
  }

  /// Whether [property] holds one value a view can show or carry in a route, or a collection of them: a
  /// scalar other than `json`, `bytes` and `binary`, an enum or a single-value wrapper.
  bool isValue(Map<String, Object?> property) {
    final expression = TypeExpression.parse(property['type'] as String);
    final element = switch (expression) {
      ListType(:final element) || SetType(:final element) => element,
      MapType() || null => null,
      _ => expression,
    };
    return switch (element) {
      ScalarType(:final name) => !const {'json', 'bytes', 'binary'}.contains(name),
      NamedType(:final name) => () {
        final type = asMap(contract.types[name]);
        return type['kind'] == 'enum' || (type['kind'] == 'value' && type['wraps'] != null);
      }(),
      _ => false,
    };
  }

  /// R1.5: whether [path] from [root], when it goes through a list or set, ends right after it at
  /// the identity of the element. A path that does not resolve counts as true (reported apart).
  bool endsAtElementIdentity(String root, String path) {
    final segments = path.split('.');
    var owner = root;
    for (var index = 0; index < segments.length - 1; index++) {
      final property = propertiesOf(owner)?[segments[index]];
      if (property == null) return true;
      final type = asString(asMap(property)['type']) ?? '';
      final element = collectionElement(type);
      if (element != null) return index == segments.length - 2 && _identityOf(element).contains(segments.last);
      final expression = TypeExpression.parse(type);
      if (expression is! NamedType) return true;
      owner = expression.name;
    }
    return true;
  }

  /// The identity of an entity, or the shared identity of a union of entities.
  Set<String> _identityOf(String name) {
    final type = asMap(contract.types[name]);
    return switch (type['kind']) {
      'entity' => asList(type['identity']).whereType<String>().toSet(),
      'union' => propertiesOf(name)?.keys.toSet() ?? const {},
      _ => const {},
    };
  }

  /// The properties a type or shape carries, a shape only those it selects.
  Map<String, Object?> carriedProperties(String name) {
    final shape = contract.shapes[name];
    if (shape == null) return propertiesOf(name) ?? const {};
    final source = propertiesOf(asString(asMap(shape)['source']) ?? '') ?? const {};
    return {
      for (final key in asMap(asMap(shape)['properties']).keys)
        if (source.containsKey(key)) key: source[key],
    };
  }

  /// The scalar a property stands for, looking through enums and single-value wrappers.
  String scalarOf(Map<String, Object?> property) {
    final expression = TypeExpression.parse(property['type'] as String);
    if (expression == null) return 'unknown';
    return switch (expression) {
      ScalarType(:final name) => name,
      NamedType(:final name) => () {
        final type = asMap(contract.types[name]);
        if (type['kind'] == 'enum') return 'enum';
        final wraps = asString(type['wraps']);
        final wrapped = type['kind'] == 'value' && wraps != null ? TypeExpression.parse(wraps) : null;
        return wrapped is ScalarType ? wrapped.name : 'object';
      }(),
      ListType(:final element) || SetType(:final element) => element is ScalarType ? element.name : 'object',
      MapType() => 'object',
    };
  }
}

/// The element type name of a list or set of a named type, or null for anything else.
String? collectionElement(String type) {
  final element = switch (TypeExpression.parse(type)) {
    ListType(:final element) || SetType(:final element) => element,
    _ => null,
  };
  return element is NamedType ? element.name : null;
}
