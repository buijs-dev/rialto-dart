import 'located_document.dart';
import 'type_expression.dart';

/// A validated Rialto contract, as plain JSON values with typed access to its sections.
class Contract {
  const Contract(this.json);

  final Map<String, Object?> json;

  String get rialto => json['rialto'] as String;
  Map<String, Object?> get info => asMap(json['info']);
  String get version => info['version'] as String;

  Map<String, Object?> section(String name) => asMap(json[name]);

  Map<String, Object?> get sources => section('sources');
  Map<String, Object?> get types => section('types');
  Map<String, Object?> get shapes => section('shapes');
  Map<String, Object?> get operations => section('operations');
  Map<String, Object?> get events => section('events');
  Map<String, Object?> get streams => section('streams');
  Map<String, Object?> get subscriptions => section('subscriptions');
  Map<String, Object?> get storage => section('storage');
  Map<String, Object?> get views => section('views');
  Map<String, Object?> get navigation => section('navigation');
  Map<String, Object?> get errors => section('errors');
  Map<String, Object?> get auth => section('auth');
  List<Object?> get mappings => asList(json['mappings']);
}

/// An operation of the contract, with typed access to the forms of `output` (R2.7), `subject`
/// (R1.7, R1.8) and `maxItems`. It is the JSON map itself, so every key reads as before.
extension type const Operation(Map<String, Object?> json) implements Map<String, Object?> {
  /// The operation [value] of a contract's `operations`, or an empty one.
  Operation.of(Object? value) : json = asMap(value);

  /// The type or shape of the response, or `list<T>` for a bare, unpaged array (R2.7), as written.
  String? get output => asString(json['output']);

  /// The type or shape [output] names: `T` of `list<T>`, else [output] itself.
  String? get outputType {
    final output = this.output;
    return output == null ? null : (_listElementOf(output) ?? output);
  }

  /// Whether [output] is `list<T>`, a bare, unpaged array of [outputType] (R2.7).
  bool get outputList => output != null && _listElementOf(output!) != null;

  /// [output] when it is one value, not `list<T>`.
  String? get singleOutput => outputList ? null : output;

  /// For `output: list<T>`: the most elements the response holds (R2.7).
  int? get maxItems => (json['maxItems'] as num?)?.toInt();

  /// The entity of `subject`: the name itself, or `type` of `{type, by}` (R1.7, R1.8).
  String? get subjectType => switch (json['subject']) {
    String name => name,
    Map subject => asString(subject['type']),
    _ => null,
  };

  /// `by` of `subject: {type, by}`, or null for a subject written as a name.
  String? get subjectBy => asString(asMap(json['subject'])['by']);

  /// Whether the identity of the subject comes from the verified principal (`by: actor`, R1.8).
  bool get subjectByActor => subjectBy == actor;

  static const actor = 'actor';

  /// The one rule of `transition: <Type>.<rule>` (L5), or null without one or for a select (L5.6).
  String? get transition => asString(json['transition']);

  /// The JSON Pointer of `transition: {select, rules}` in the request body (L5.6), or null.
  String? get transitionSelect => asString(asMap(json['transition'])['select']);

  /// Per body value, the `<Type>.<rule>` a select performs (L5.6); empty without a select.
  Map<String, String> get transitionSelectRules => {
    for (final entry in asMap(asMap(json['transition'])['rules']).entries)
      if (entry.value case final String rule) entry.key: rule,
  };

  /// Every `<Type>.<rule>` the operation can perform, in either form of `transition`.
  List<String> get transitionRules => switch (transition) {
    final String rule => [rule],
    _ => transitionSelectRules.values.toSet().toList(),
  };

  /// The entity type of the first rule the operation can perform, or null without a transition.
  String? get transitionType {
    final rules = transitionRules;
    if (rules.isEmpty) return null;
    final rule = rules.first;
    return rule.contains('.') ? rule.substring(0, rule.indexOf('.')) : rule;
  }

  /// For a delete: the states in which the entity may be deleted (L5.9); empty without.
  List<String> get from => asList(json['from']).whereType<String>().toList();

  /// `T` of `list<T>` with a named `T`, or null for anything else.
  static String? _listElementOf(String text) => switch (TypeExpression.parse(text)) {
    ListType(:final NamedType element, nullableElements: false) => element.name,
    _ => null,
  };
}

/// The tiebreaker of a sort (Q1.3): a field name, or `{field, direction}`; ascending when it declares none.
abstract final class Tiebreaker {
  static const asc = 'asc';

  /// The field of [tiebreaker], in either form.
  static String? field(Object? tiebreaker) => switch (tiebreaker) {
    String name => name,
    Map form => asString(form['field']),
    _ => null,
  };

  /// The direction [tiebreaker] declares, or null for the bare form.
  static String? direction(Object? tiebreaker) => asString(asMap(tiebreaker)['direction']);

  /// [direction], or `asc` when it is absent (Q1.3).
  static String effectiveDirection(Object? tiebreaker) => direction(tiebreaker) ?? asc;
}

/// The roles of a batch `wire` that point into an element of `results` (L4.5).
const batchResultRoles = ['value', 'problem', 'index', 'status'];
