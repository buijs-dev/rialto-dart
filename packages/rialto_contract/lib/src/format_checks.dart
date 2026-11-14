import 'checks.dart';
import 'contract.dart';
import 'contract_types.dart';
import 'diagnostics.dart';
import 'located_document.dart';
import 'sources.dart';
import 'type_expression.dart';

/// The checks of the contract format that need the whole contract: unique names (K1.3, `RIALTO-K005`), type
/// expressions (K2.1, `RIALTO-K006`), references to contract elements (K1.2, `RIALTO-K004`) and references into
/// sources (K1.2, `RIALTO-S002`), in every section. The rules of the profiles are checks of their own.
class FormatChecks extends ContractCheck {
  const FormatChecks();

  @override
  void run(CheckContext context) => _FormatRun(context).run();
}

class _FormatRun {
  _FormatRun(this.context)
    : contract = context.contract,
      typeNames = context.contract.types.keys.toSet(),
      dataNames = {...context.contract.types.keys, ...context.contract.shapes.keys},
      _lookup = ContractTypes(context.contract);

  final CheckContext context;
  final Contract contract;
  final Set<String> typeNames;
  final Set<String> dataNames;
  final ContractTypes _lookup;

  void run() {
    _names();
    _types();
    _shapes();
    _operations();
    _events();
    _mappings();
    _storage();
    _views();
    _navigation();
    _auth();
    _transitions();
    _sourceSuccessors();
  }

  // Helpers -------------------------------------------------------------------------------------

  String _pointer(List<Object> segments) => CheckContext.pointer(segments);

  void _error(Code code, String message, String pointer) => context.error(code, message, pointer);

  void _requireName(String? name, Set<String> known, String what, String pointer) {
    if (name != null && !known.contains(name)) _error(Code.unresolvedReference, "Unknown $what '$name'", pointer);
  }

  /// Checks a type or shape name, or an external `<source>#<location>` reference.
  void _requireDataOrExternal(String reference, String pointer) {
    if (reference.contains('#')) {
      _requireExternal(reference, pointer);
    } else {
      _requireName(reference, dataNames, 'type or shape', pointer);
    }
  }

  void _requireExternal(String? reference, String pointer) {
    if (reference == null) return;
    final (resolution, source) = context.sources.resolve(reference, contract.sources.keys.toSet());
    switch (resolution) {
      case Resolution.unknownSource:
        _error(Code.unresolvedReference, "Unknown source '${reference.split('#').first}' in '$reference'", pointer);
      case Resolution.missing:
        final location = reference.contains('#') ? reference.substring(reference.indexOf('#') + 1) : '';
        _error(Code.sourceReference, "'$location' does not exist in ${source!.file.split('/').last}", pointer);
      default:
        break;
    }
  }

  static List<String> _restRefs(Object? rest) => switch (rest) {
    String ref => [ref],
    Map map => map.values.whereType<String>().toList(),
    _ => const [],
  };

  // K1.3 ----------------------------------------------------------------------------------------

  void _names() {
    for (final name in contract.shapes.keys.where(typeNames.contains)) {
      _error(Code.duplicateName, "'$name' is both a type and a shape", _pointer(['shapes', name]));
    }
  }

  // Types and shapes ----------------------------------------------------------------------------

  void _types() {
    contract.types.forEach((name, value) {
      final type = asMap(value);
      switch (type['kind']) {
        case 'entity' || 'value':
          _properties(name, asMap(type['properties']));
        case 'union':
          asMap(type['variants']).cast<String, String>().forEach(
            (value, variant) => _requireName(variant, typeNames, 'type', _pointer(['types', name, 'variants', value])),
          );
        case 'projection':
          final source = type['source'] as String;
          _requireName(source, typeNames, 'type', _pointer(['types', name, 'source']));
          if (_lookup.propertiesOf(source) != null) {
            // The list form is located by index, the map form by property name.
            final listed = type['properties'] is List;
            final paths = _lookup.projectionPaths(type).entries.toList();
            for (var i = 0; i < paths.length; i++) {
              if (_lookup.resolvePath(source, paths[i].value) == null) {
                _error(
                  Code.unresolvedReference,
                  "'${paths[i].value}' is not a property of '$source'",
                  _pointer(['types', name, 'properties', listed ? i : paths[i].key]),
                );
              }
            }
          }
      }
    });
  }

  /// K2.1: each property type is a valid expression over declared types; a map key is a scalar or an enum.
  void _properties(String owner, Map<String, Object?> properties) {
    properties.forEach((property, declaration) {
      final at = _pointer(['types', owner, 'properties', property, 'type']);
      final text = asMap(declaration)['type'] as String;
      final expression = TypeExpression.parse(text);
      if (expression == null) {
        _error(Code.typeExpression, "Invalid type '$text'", at);
        return;
      }
      for (final name in expression.names()) {
        _requireName(name, typeNames, 'type', at);
      }
      if (expression is MapType && expression.key is NamedType) {
        final key = (expression.key as NamedType).name;
        final keyType = contract.types[key];
        if (keyType != null && asMap(keyType)['kind'] != 'enum') {
          _error(Code.typeExpression, "Map key '$key' must be an enum", at);
        }
      }
    });
  }

  void _shapes() {
    contract.shapes.forEach((name, value) {
      final shape = asMap(value);
      final source = shape['source'] as String;
      _requireName(source, typeNames, 'type', _pointer(['shapes', name, 'source']));
      final sourceProperties = _lookup.propertiesOf(source);
      if (sourceProperties == null) return;
      asMap(shape['properties']).forEach((property, declaration) {
        final at = _pointer(['shapes', name, 'properties', property]);
        if (sourceProperties[property] == null) {
          _error(Code.unresolvedReference, "'$property' is not a property of '$source'", at);
          return;
        }
        _requireName(asString(asMap(declaration)['shape']), contract.shapes.keys.toSet(), 'shape', '$at/shape');
      });
    });
  }

  // Operations and events -----------------------------------------------------------------------

  void _operations() {
    contract.operations.forEach((name, value) {
      final operation = Operation.of(value);
      final at = _pointer(['operations', name]);
      for (final reference in _restRefs(operation['rest'])) {
        _requireExternal(reference, '$at/rest');
      }
      _requireName(asString(operation['input']), dataNames, 'type or shape', '$at/input');
      _requireName(operation.outputType, dataNames, 'type or shape', '$at/output');
      _requireName(
        operation.subjectType,
        typeNames,
        'type',
        operation.subjectBy == null ? '$at/subject' : '$at/subject/type',
      );
      _requireName(
        asString(asMap(operation['deprecated'])['successor']),
        contract.operations.keys.toSet(),
        'operation',
        '$at/deprecated/successor',
      );
      final emits = asList(operation['emits']);
      for (var i = 0; i < emits.length; i++) {
        _requireName(emits[i] as String, contract.events.keys.toSet(), 'event', '$at/emits/$i');
      }
      if (operation['list'] != null) {
        _requireName(
          asString(asMap(asMap(operation['list'])['count'])['operation']),
          contract.operations.keys.toSet(),
          'operation',
          '$at/list/count/operation',
        );
      }
    });
  }

  void _events() {
    final events = contract.events.keys.toSet();
    contract.events.forEach((name, value) {
      final event = asMap(value);
      final at = _pointer(['events', name]);
      _requireName(event['data'] as String, dataNames, 'type or shape', '$at/data');
      _requireExternal(asString(event['channel']), '$at/channel');
    });
    contract.streams.forEach((name, value) {
      final stream = asMap(value);
      final at = _pointer(['streams', name]);
      final streamEvents = asList(stream['events']);
      for (var i = 0; i < streamEvents.length; i++) {
        _requireName(streamEvents[i] as String, events, 'event', '$at/events/$i');
      }
      _requireExternal(asString(stream['channel']), '$at/channel');
    });
    contract.subscriptions.forEach((name, value) {
      final subscription = asMap(value);
      final at = _pointer(['subscriptions', name]);
      _requireName(asString(subscription['event']), events, 'event', '$at/event');
      _requireExternal(asString(asMap(subscription['delivery'])['deadLetter']), '$at/delivery/deadLetter');
    });
  }

  // Mapping and storage -------------------------------------------------------------------------

  void _mappings() {
    final mappings = contract.mappings;
    for (var i = 0; i < mappings.length; i++) {
      final mapping = asMap(mappings[i]);
      _requireDataOrExternal(mapping['source'] as String, _pointer(['mappings', i, 'source']));
      _requireDataOrExternal(mapping['target'] as String, _pointer(['mappings', i, 'target']));
    }
  }

  void _storage() {
    contract.storage.forEach((name, value) {
      final storage = asMap(value);
      final at = _pointer(['storage', name]);
      _requireName(name, typeNames, 'type', at);
      final table = storage['table'] as String;
      _requireExternal(table, '$at/table');
      asMap(storage['columns']).forEach((property, column) {
        final columnAt = '$at/columns/${LocatedDocument.segment(property)}';
        if (column is String) {
          _requireExternal('$table.$column', columnAt);
        } else {
          final join = asMap(column);
          final steps = join['join'];
          if (steps is List) {
            // A join of two steps: each column is one of the table before it.
            final first = asMap(steps.elementAtOrNull(0)), second = asMap(steps.elementAtOrNull(1));
            _requireExternal('$table.${first['column']}', '$columnAt/join/0/column');
            _requireExternal('${first['table']}.${second['column']}', '$columnAt/join/1/column');
            _requireExternal('${second['table']}.${join['key']}', '$columnAt/key');
          } else {
            _requireExternal('$table.$steps', '$columnAt/join');
            _requireExternal('${join['table']}.${join['key']}', '$columnAt/key');
          }
        }
      });
      asMap(storage['children']).forEach((property, value) {
        final ownerKey = asString(asMap(value)['ownerKey']);
        if (ownerKey != null) {
          _requireExternal('$table.$ownerKey', '$at/children/${LocatedDocument.segment(property)}/ownerKey');
        }
        // The position column is one of the child's table.
        final order = asString(asMap(value)['order']);
        final target = order == null ? null : _targetTableOf(name, property);
        if (target != null) {
          _requireExternal('$target.$order', '$at/children/${LocatedDocument.segment(property)}/order');
        }
      });
      asMap(storage['links']).forEach((property, value) {
        final link = asMap(value);
        final linkAt = '$at/links/${LocatedDocument.segment(property)}';
        if (link['table'] == null) {
          // Read-only: the foreign key is a column of the target's table.
          final target = _targetTableOf(name, property);
          if (target != null) _requireExternal('$target.${link['ownerKey']}', '$linkAt/ownerKey');
        } else {
          _requireExternal(link['table'] as String, '$linkAt/table');
          _requireExternal('${link['table']}.${link['ownerKey']}', '$linkAt/ownerKey');
          _requireExternal('${link['table']}.${link['targetKey']}', '$linkAt/targetKey');
          // The position column is one of the link table.
          if (link['order'] != null) _requireExternal('${link['table']}.${link['order']}', '$linkAt/order');
        }
      });
      final version = asString(storage['version']);
      if (version != null) _requireExternal('$table.$version', '$at/version');
      // The soft-delete marker and the column of who deleted.
      final delete = storage['delete'];
      if (delete is Map) {
        _requireExternal('$table.${delete['soft']}', '$at/delete/soft');
        final by = asString(delete['by']);
        if (by != null) _requireExternal('$table.$by', '$at/delete/by');
      }
      final storageKey = asString(storage['storageKey']);
      if (storageKey != null) _requireExternal('$table.$storageKey', '$at/storageKey');
      // A blob keeps its key and metadata in columns of the table.
      asMap(storage['blobs']).forEach((property, value) {
        final blob = asMap(value);
        final blobAt = '$at/blobs/${LocatedDocument.segment(property)}';
        for (final key in ['key', 'mediaType', 'size', 'sha256']) {
          final column = asString(blob[key]);
          if (column != null) _requireExternal('$table.$column', '$blobAt/$key');
        }
      });
    });
  }

  /// The table of the type [property] of [owner] refers to, when it is stored.
  String? _targetTableOf(String owner, String property) {
    final type = asString(asMap(asMap(asMap(contract.types[owner])['properties'])[property])['type']);
    final expression = type == null ? null : TypeExpression.parse(type);
    final target = switch (expression) {
      ListType(:final element) || SetType(:final element) => element,
      _ => expression,
    };
    return target is NamedType ? asString(asMap(contract.storage[target.name])['table']) : null;
  }

  // Views ---------------------------------------------------------------------------------------

  void _views() {
    final operations = contract.operations.keys.toSet();
    final views = contract.views.keys.toSet();
    contract.views.forEach((name, value) {
      final view = asMap(value);
      final at = _pointer(['views', name]);
      _requireName(asString(view['load']), operations, 'operation', '$at/load');
      asMap(view['fields']).forEach((field, declaration) {
        final fieldAt = '$at/fields/${LocatedDocument.segment(field)}';
        _requireName(asString(asMap(declaration)['edit']), operations, 'operation', '$fieldAt/edit');
        _requireName(asString(asMap(declaration)['link']), views, 'view', '$fieldAt/link');
        _requireName(
          asString(asMap(asMap(declaration)['options'])['operation']),
          operations,
          'operation',
          '$fieldAt/options/operation',
        );
      });
      asMap(view['actions']).forEach((action, declaration) {
        _requireName(
          asString(asMap(declaration)['operation']),
          operations,
          'operation',
          '$at/actions/$action/operation',
        );
      });
      final tabs = asList(view['tabs']);
      for (var i = 0; i < tabs.length; i++) {
        _requireName(asString(tabs[i]), views, 'view', '$at/tabs/$i');
      }
      final list = asMap(view['list']);
      _requireName(asString(list['operation']), operations, 'operation', '$at/list/operation');
      _requireName(asString(list['open']), views, 'view', '$at/list/open');
      asMap(list['actions']).forEach((action, declaration) {
        _requireName(
          asString(asMap(declaration)['operation']),
          operations,
          'operation',
          '$at/list/actions/$action/operation',
        );
      });
      final refreshOn = asList(view['refreshOn']);
      for (var i = 0; i < refreshOn.length; i++) {
        _requireName(refreshOn[i] as String, contract.events.keys.toSet(), 'event', '$at/refreshOn/$i');
      }
    });
  }

  /// The views and count operations the menu names.
  void _navigation() {
    final navigation = contract.navigation;
    if (navigation.isEmpty) return;
    final views = contract.views.keys.toSet();
    _requireName(asString(navigation['home']), views, 'view', '/navigation/home');
    for (final menu in ['primary', 'secondary']) {
      final entries = asList(navigation[menu]);
      for (var i = 0; i < entries.length; i++) {
        final entry = asMap(entries[i]);
        _requireName(asString(entry['view']), views, 'view', '/navigation/$menu/$i/view');
        _requireName(
          asString(entry['badge']),
          contract.operations.keys.toSet(),
          'operation',
          '/navigation/$menu/$i/badge',
        );
      }
    }
  }

  // Auth, transitions and sources ---------------------------------------------------------------

  void _auth() {
    final auth = contract.auth;
    final providers = asMap(auth['providers']).keys.toSet();
    asMap(auth['clients']).forEach((name, client) {
      _requireName(
        asString(asMap(client)['provider']),
        providers,
        'provider',
        _pointer(['auth', 'clients', name, 'provider']),
      );
    });
    asMap(auth['scopes']).forEach((scope, declaration) {
      _requireExternal(asString(asMap(declaration)['scheme']), _pointer(['auth', 'scopes', scope, 'scheme']));
    });
    asMap(auth['apiKeys']).forEach((key, value) {
      _requireExternal(asString(asMap(value)['scheme']), _pointer(['auth', 'apiKeys', key, 'scheme']));
    });
  }

  /// The events a transition rule emits are declared.
  void _transitions() {
    contract.types.forEach((type, value) {
      final entity = asMap(value);
      if (entity['kind'] != 'entity') return;
      asMap(asMap(entity['transitions'])['rules']).forEach((rule, declaration) {
        final emits = asList(asMap(declaration)['emits']).whereType<String>().toList();
        for (var index = 0; index < emits.length; index++) {
          if (contract.events.containsKey(emits[index])) continue;
          _error(
            Code.unresolvedReference,
            "Unknown event '${emits[index]}'",
            _pointer(['types', type, 'transitions', 'rules', rule, 'emits', index]),
          );
        }
      });
    });
  }

  void _sourceSuccessors() {
    contract.sources.forEach((name, value) {
      _requireName(
        asString(asMap(value)['successor']),
        contract.sources.keys.toSet(),
        'source',
        _pointer(['sources', name, 'successor']),
      );
    });
  }
}
