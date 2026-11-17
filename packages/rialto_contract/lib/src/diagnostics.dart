/// Whether a finding fails the run.
enum Severity { error, warning }

/// Where a finding was made: a file, a position in it when known, and a JSON Pointer.
class Location {
  const Location(this.file, {this.line, this.column, this.pointer = ''});

  final String file;
  final int? line;
  final int? column;
  final String pointer;

  @override
  String toString() {
    final name = file.split('/').last;
    final position = line != null ? ':$line:${column ?? 1}' : '';
    final path = pointer.isNotEmpty ? ' #$pointer' : '';
    return '$name$position$path';
  }
}

/// The standard diagnostic codes of the specification (contract.md, "Standard diagnostic codes"), shared with every
/// implementation: `K` the contract itself, `S` its sources, `P` the rules of a profile. Each code names the
/// requirement a finding reports when its check names none.
enum Code {
  unreadable('RIALTO-K001', 'K1.7', 'contract or fragment cannot be read or parsed, or is not a mapping'),
  schema('RIALTO-K002', 'K1.7', 'contract is not valid against the JSON Schema'),
  unsupportedVersion('RIALTO-K003', 'K1.1', 'unsupported contract format version'),
  unresolvedReference('RIALTO-K004', 'K1.2', 'reference does not resolve'),
  duplicateName('RIALTO-K005', 'K1.3', 'name is used twice'),
  typeExpression('RIALTO-K006', 'K2.1', 'invalid type expression'),
  includeNoMatch('RIALTO-K007', 'K5.2', 'include path matches no file'),
  fragmentRootKey('RIALTO-K008', 'K5.2', 'fragment declares info, sources or include'),
  sectionTwice('RIALTO-K009', 'K5.4', 'section that belongs in one file appears in two'),
  lockUnusable('RIALTO-K010', 'K4.5', 'rialto.lock cannot be read, or cannot be written when it must change'),
  sourceUnreadable('RIALTO-S001', 'K1.9', 'referenced source cannot be read'),
  sourceReference('RIALTO-S002', 'K1.2', 'reference into a source does not resolve'),
  remoteUnavailable('RIALTO-S003', 'K4.3', 'remote source can neither be fetched nor found in the cache'),
  remoteChanged('RIALTO-S004', 'K4.2', 'remote source differs from its hash in rialto.lock'),
  remoteScheme('RIALTO-S005', 'K4.4', 'remote source does not use https'),
  missingIdentity('RIALTO-P001', 'D2.2', 'entity identity is not one of its properties'),
  unionVariants('RIALTO-P002', 'D2.6', 'union variants are not all entities or all value objects'),
  queryField('RIALTO-P003', 'Q1.1', 'query field or operator does not fit the output type'),
  tiebreaker('RIALTO-P004', 'Q1.3', 'tiebreaker is not a sortable query field'),
  errorCode('RIALTO-P005', 'E1.1', 'operation returns an undeclared error code'),
  commandProperty('RIALTO-P006', 'L1.2', 'command property does not fit its relationship'),
  sourceVersion('RIALTO-P007', 'V1.4', 'source version differs from the document version'),
  undeclaredScope('RIALTO-P008', 'S1.1', 'scope used by an operation is not declared'),
  listWire('RIALTO-P009', 'Q1.4', 'list wire element does not exist in the OpenAPI operation'),
  errorWire('RIALTO-P010', 'E1.3', 'error wire pointer does not exist in the problem schema'),
  eventSubject('RIALTO-P011', 'A1.1', 'event subject is not a property of the event data'),
  discriminator('RIALTO-P012', 'K2.8', 'a variant declares the discriminator with a type other than string'),
  listKind(
    'RIALTO-P013',
    'Q1.6',
    'list wire or encodings do not fit a REST or local operation, or a fixed sort takes a sort parameter or encoding',
  ),
  shapeConstraint(
    'RIALTO-P014',
    'D3.5',
    "shape constraint weakens its source property's or does not apply to its type",
  ),
  parameter('RIALTO-P015', 'R1.5', 'REST parameter is not mapped, or its mapping does not resolve'),
  codeType(
    'RIALTO-P016',
    'E2.2',
    'code types are not one template with {code}, or two codes or categories share a type',
  ),
  deprecation('RIALTO-P017', 'V2.2', 'deprecated operation is not marked deprecated in its OpenAPI operation'),
  pathLocation(
    'RIALTO-P018',
    'E1.5',
    'with locationFormat path, a request body property and a parameter or header share a name',
  ),
  countFilter(
    'RIALTO-P019',
    'Q5.2',
    "count operation does not take the list's filter, or requires a parameter the list does not have",
  ),
  conditional(
    'RIALTO-P020',
    'R6.1',
    'conditional operation is not a GET or HEAD with If-None-Match, an ETag on success and a 304',
  ),
  binary('RIALTO-P021', 'K2.11', 'binary without maxSize, in a collection, as a query field, or carried as JSON'),
  apiKey(
    'RIALTO-P022',
    'S6.1',
    'apiKey scheme of an operation is not declared under auth.apiKeys, or not sent in a header',
  ),
  transition(
    'RIALTO-P023',
    'L5.1',
    'transition state is not a closed enum with a member default, a rule or delete names a non-member, a transition names an unknown rule, or a command shape contains the state',
  ),
  idempotency(
    'RIALTO-P024',
    'L3.2',
    'idempotency on a safe method, or its header is not a header of the OpenAPI operation',
  ),
  mappingCoverage(
    'RIALTO-P025',
    'M2.8',
    'mapping names a property neither side has, leaves a required property uncovered, or uses version: stored without a stored version',
  ),
  storageColumn(
    'RIALTO-P026',
    'P1.5',
    'stored property has no or two places, shares a column, or its column type or nullability, the type of a join\'s key column, or the type of an order column, does not fit',
  ),
  batchWire(
    'RIALTO-P027',
    'L4.5',
    'batch wire pointer does not resolve in the OpenAPI operation, or is not an array, or index or status is not an integer',
  ),
  immutable('RIALTO-P028', 'L1.6', 'update command shape has an immutable property'),
  link(
    'RIALTO-P029',
    'L6.1',
    'link operation does not name a to-many reference with a link table, does not address owner and target by identity, or also declares lifecycle, input or transition',
  ),
  uniqueKey(
    'RIALTO-P030',
    'P3.6',
    'unique key names a property without a plain column, or an operation addresses an entity by properties that are neither its identity nor a unique key',
  ),
  softDelete(
    'RIALTO-P031',
    'P6.3',
    'deleted on an operation that does not read or on an entity without soft deletion, a delete or restore that names no entity, a restore without restore: true, a subject that is not an entity, or a command property on the soft-delete marker or by column',
  ),
  referenceOrCreate(
    'RIALTO-P032',
    'L1.7',
    'as: [identity, command] outside a create command, on a property that is not a reference, without the create command shape of its type, or its mapping lacks a from per form',
  ),
  listOutput(
    'RIALTO-P033',
    'R2.7',
    'output: list<T> lacks maxItems, its success response is not an array of T, or it is also a list operation',
  ),
  actorSubject(
    'RIALTO-P034',
    'R1.8',
    'subject by actor names no entity, maps a parameter to its identity, has an input that carries that identity, or belongs to an operation that needs no signed-in caller; or an input with role actor belongs to such an operation',
  ),
  scope(
    'RIALTO-P035',
    'P6.11',
    'scope names a column twice or a column the table lacks, storage entries on one table declare different scopes, a reference lacks a source of the scope of its target, a command carries a property on a scope column, or a type with an actor entry is reached by an operation that needs no signed-in caller',
  ),
  transitionForm(
    'RIALTO-P036',
    'L5.6',
    'a select does not resolve to a string in the request body or names rules of several entities, a sets entry does not fit its property, a create transition does not start in the initial state, or from is declared off a delete or for an entity without transitions',
  ),
  actionValues(
    'RIALTO-P037',
    'U3.9',
    'an action value does not resolve in the request body of its operation, does not fit the schema there, or selects no rule',
  ),
  propertyRule(
    'RIALTO-P038',
    'D3.6',
    'requiredWhen or absentWhen does not name another enum property or its members, or is on a non-nullable property; minimumOf or maximumOf does not name another property with the same ordered scalar; or uniqueItems is not on a list',
  ),
  presence(
    'RIALTO-P039',
    'M3.11',
    'presence in a toSource mapping, on a target property that is not a non-nullable boolean, naming a property the source lacks, or from a source that does not keep presence',
  ),
  joinComputed(
    'RIALTO-P040',
    'P2.11',
    'join of two steps on a collection, in a command or generated, join without relation on a type that is not a scalar or wrapper, or a computed count of the wrong type, in a command, under generated, or of a property that is not a to-many child or link',
  ),
  viewLink(
    'RIALTO-P041',
    'U5.9',
    'menu entry, tab, link or open names a view whose route the data cannot fill, a view twice, or a badge that is not the count operation of a list',
  ),
  listView(
    'RIALTO-P042',
    'U6.5',
    'row action parameter is filled neither from the route nor the row, a where or column does not fit the list operation, or the list operation is neither a list nor list<T>',
  ),
  viewCondition(
    'RIALTO-P043',
    'U3.11',
    'visibleWhen or enabledWhen path is not an enum property with the listed members, or for actor not a string or uuid',
  ),
  fieldOptions(
    'RIALTO-P044',
    'U2.11',
    'options field is not a to-one reference of its input, or its operation or label does not fit the referenced entity',
  ),
  storageOrder(
    'RIALTO-P045',
    'P4.13',
    'list under children or links declares neither or both of order and orderBy, a set declares one, or an orderBy entry is not a sortable property of the element type',
  );

  const Code(this.id, this.requirement, this.summary);

  final String id;
  final String requirement;
  final String summary;
}

/// One finding.
class Diagnostic {
  const Diagnostic(this.severity, this.code, this.message, this.location, {this.hint, String? requirement})
    : _requirement = requirement;

  final Severity severity;
  final Code code;
  final String message;
  final Location location;
  final String? hint;
  final String? _requirement;

  /// The identifier reported: that of [code].
  String get id => code.id;

  /// The requirement this finding violates: the one its check names, else the code's.
  String? get requirement => _requirement ?? code.requirement;

  @override
  String toString() {
    final label = severity == Severity.error ? 'error' : 'warning';
    final requirement = this.requirement != null ? ' (${this.requirement})' : '';
    final hintLine = hint != null ? '\n  hint: $hint' : '';
    return '$label[$id] $location: $message$requirement$hintLine';
  }
}

/// Collects findings during one run.
class Diagnostics {
  final _items = <Diagnostic>[];

  List<Diagnostic> get all => List.unmodifiable(_items);

  bool get hasErrors => _items.any((it) => it.severity == Severity.error);

  void add(Diagnostic diagnostic) => _items.add(diagnostic);

  void error(Code code, String message, Location location, {String? hint, String? requirement}) =>
      _items.add(Diagnostic(Severity.error, code, message, location, hint: hint, requirement: requirement));

  void warning(Code code, String message, Location location, {String? hint}) =>
      _items.add(Diagnostic(Severity.warning, code, message, location, hint: hint));
}
