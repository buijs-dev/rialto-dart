import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

/// The typed access to a contract that checks read: type expressions, operations, types, OpenAPI schemas and the writer.
void main() {
  group('type expressions', () {
    test('parse every form, with whitespace and nullable elements', () {
      expect(TypeExpression.parse(' int64 '), const ScalarType('int64'));
      expect(TypeExpression.parse('Thing'), const NamedType('Thing'));
      expect(TypeExpression.parse('set<Thing?>'), const SetType(NamedType('Thing'), true));
      expect(TypeExpression.parse('list<decimal(8,3)>'), const ListType(ScalarType('decimal', 8, 3), false));
      expect(
        TypeExpression.parse('map<string,int32?>'),
        const MapType(ScalarType('string'), ScalarType('int32'), true),
      );
      expect(TypeExpression.parse('map<Size, Thing>')!.names(), ['Size', 'Thing']);
      expect(TypeExpression.parse('list<Thing>')!.names(), ['Thing']);
      expect(TypeExpression.parse('set<Thing>')!.names(), ['Thing']);
      expect(TypeExpression.parse('uuid')!.names(), isEmpty);
    });

    test('reject what the format does not allow', () {
      for (final text in ['map<string>', 'map<json, string>', 'map<string, nope>', 'set<nope>', 'list<Thing??>', '']) {
        expect(TypeExpression.parse(text), isNull, reason: text);
      }
    });

    test('compare by value', () {
      final expressions = [
        const ScalarType('decimal', 8, 3),
        const NamedType('Thing'),
        const ListType(NamedType('Thing'), false),
        const SetType(NamedType('Thing'), false),
        const MapType(ScalarType('string'), NamedType('Thing'), false),
      ];
      for (final expression in expressions) {
        expect(expressions.where((it) => it == expression), [expression]);
        expect(expressions.toSet().contains(expression), isTrue);
      }
      expect(const ListType(NamedType('Thing'), true), isNot(const ListType(NamedType('Thing'), false)));
      expect(
        const SetType(NamedType('Thing'), true).hashCode,
        isNot(const ListType(NamedType('Thing'), true).hashCode),
      );
    });
  });

  group('operations', () {
    test('output, a bare list, maxItems and the subject in both forms', () {
      final list = Operation.of({
        'output': 'list<Thing>',
        'maxItems': 50,
        'subject': {'type': 'User', 'by': 'actor'},
      });
      expect(
        (list.output, list.outputType, list.outputList, list.singleOutput, list.maxItems),
        ('list<Thing>', 'Thing', true, null, 50),
      );
      expect((list.subjectType, list.subjectBy, list.subjectByActor), ('User', 'actor', true));

      final single = Operation.of({'output': 'Thing', 'subject': 'Thing'});
      expect((single.outputType, single.outputList, single.singleOutput), ('Thing', false, 'Thing'));
      expect((single.subjectType, single.subjectBy, single.subjectByActor), ('Thing', null, false));

      final none = Operation.of(null);
      expect(
        (none.output, none.outputType, none.outputList, none.subjectType, none.maxItems),
        (null, null, false, null, null),
      );
      expect(Operation.of({'output': 'list<string>'}).outputList, isFalse);
      expect(Operation.of({'output': 'list<Thing?>'}).outputList, isFalse);
    });

    test('a transition as one rule or as a select, and the states of a delete', () {
      final one = Operation.of({'transition': 'Thing.close'});
      expect((one.transition, one.transitionType, one.transitionSelect), ('Thing.close', 'Thing', null));
      expect(one.transitionRules, ['Thing.close']);
      final select = Operation.of({
        'transition': {
          'select': '/action',
          'rules': {'close': 'Thing.close', 'shut': 'Thing.close', 'open': 'Thing.open', 'odd': 1},
        },
        'from': ['open', 2, 'closed'],
      });
      expect(select.transition, isNull);
      expect(select.transitionSelect, '/action');
      expect(select.transitionSelectRules, {'close': 'Thing.close', 'shut': 'Thing.close', 'open': 'Thing.open'});
      expect(select.transitionRules, ['Thing.close', 'Thing.open']);
      expect(select.transitionType, 'Thing');
      expect(select.from, ['open', 'closed']);
      expect(Operation.of({'transition': 'close'}).transitionType, 'close');
      expect(Operation.of({}).transitionType, isNull);
      expect(Operation.of({})['missing'], isNull);
    });

    test('a tiebreaker as a name or with a direction', () {
      expect(
        (Tiebreaker.field('id'), Tiebreaker.direction('id'), Tiebreaker.effectiveDirection('id')),
        ('id', null, 'asc'),
      );
      const form = {'field': 'id', 'direction': 'desc'};
      expect((Tiebreaker.field(form), Tiebreaker.effectiveDirection(form)), ('id', 'desc'));
      expect(Tiebreaker.field(1), isNull);
      expect(batchResultRoles, contains('index'));
    });
  });

  group('contract types', () {
    final types = ContractTypes(
      const Contract({
        'types': {
          'Size': {
            'kind': 'enum',
            'members': ['small'],
          },
          'Code': {
            'kind': 'value',
            'wraps': 'string',
            'properties': {
              'value': {'type': 'string'},
            },
          },
          'Point': {
            'kind': 'value',
            'properties': {
              'x': {'type': 'int32'},
            },
          },
          'Part': {
            'kind': 'entity',
            'identity': ['id'],
            'properties': {
              'id': {'type': 'uuid'},
              'size': {'type': 'Size'},
            },
          },
          'Other': {
            'kind': 'entity',
            'identity': ['id'],
            'properties': {
              'id': {'type': 'uuid'},
              'size': {'type': 'Size'},
            },
          },
          'Thing': {
            'kind': 'entity',
            'identity': ['id'],
            'properties': {
              'id': {'type': 'uuid'},
              'code': {'type': 'Code'},
              'parts': {'type': 'list<Part>'},
              'anyParts': {'type': 'list<AnyPart>'},
              'points': {'type': 'list<Point>'},
              'byName': {'type': 'map<string, Part>'},
              'point': {'type': 'Point'},
              'tags': {'type': 'set<string>'},
              'data': {'type': 'json'},
              'bad': {'type': 'not a type'},
            },
          },
          'AnyPart': {
            'kind': 'union',
            'discriminator': 'kind',
            'variants': {'a': 'Part', 'b': 'Other'},
          },
          'Values': {
            'kind': 'union',
            'discriminator': 'kind',
            'variants': {'a': 'Point', 'b': 'Code'},
          },
          'Summary': {
            'kind': 'projection',
            'source': 'Thing',
            'properties': {'id': 'id', 'firstPart': 'parts.id', 'nope': 'missing'},
          },
          'Listed': {
            'kind': 'projection',
            'source': 'Thing',
            'properties': ['id', 'code'],
          },
          'Broken': {
            'kind': 'projection',
            'source': 'Ghost',
            'properties': ['id'],
          },
        },
        'shapes': {
          'ThingInput': {
            'source': 'Thing',
            'properties': {
              'id': {'role': 'caller'},
              'missing': {'role': 'caller'},
            },
          },
        },
      }),
    );

    test('the properties of an entity, a value, a union of entities, a projection and a shape', () {
      expect(types.propertiesOf('Part')!.keys, ['id', 'size']);
      expect(types.propertiesOf('Point')!.keys, ['x']);
      expect(types.propertiesOf('AnyPart')!.keys, ['id']);
      expect(types.propertiesOf('Values'), isNull);
      expect(types.propertiesOf('Summary')!.keys, ['id', 'firstPart']);
      expect(types.propertiesOf('Listed')!.keys, ['id', 'code']);
      expect(types.propertiesOf('Broken'), isNull);
      expect(types.propertiesOf('ThingInput')!.keys, contains('parts'));
      expect(types.propertiesOf('Size'), isNull);
      expect(types.propertiesOf('Ghost'), isNull);
      expect(types.carriedProperties('ThingInput').keys, ['id']);
      expect(types.carriedProperties('Thing').keys, contains('parts'));
      expect(types.carriedProperties('Ghost'), isEmpty);
    });

    test('resolves a path through types and tells whether it crossed a collection', () {
      expect(types.resolvePath('Thing', 'code')!.$2, isFalse);
      expect(types.resolvePath('Thing', 'parts.size')!.$2, isTrue);
      expect(types.resolvePath('Thing', 'point.x')!.$1, {'type': 'int32'});
      expect(types.resolvePath('Thing', 'id.deeper'), isNull);
      expect(types.resolvePath('Thing', 'bad'), isNull);
      expect(types.resolvePath('Thing', 'missing'), isNull);
    });

    test('walks a path as a view reads it, counting collections and maps', () {
      expect(types.walk('Thing', 'parts.size')!.$2, 1);
      final throughMap = types.walk('Thing', 'byName.size')!;
      expect((throughMap.$2, throughMap.$3), (1, true));
      expect(types.walk('ThingInput', 'id')!.$1, {'type': 'uuid'});
      expect(types.walk('ThingInput', 'parts'), isNull, reason: 'the shape does not select it');
      expect(types.walk('Thing', 'missing'), isNull);
      expect(types.walk('Thing', 'bad'), isNull);
    });

    test('tells which properties hold values a view can show', () {
      bool isValue(String property) => types.isValue(asMap(types.propertiesOf('Thing')![property]));
      expect(isValue('id'), isTrue);
      expect(isValue('code'), isTrue);
      expect(isValue('tags'), isTrue);
      expect(isValue('data'), isFalse);
      expect(isValue('point'), isFalse);
      expect(isValue('parts'), isFalse);
      expect(isValue('byName'), isFalse);
      expect(types.isValue(const {'type': 'Size'}), isTrue);
    });

    test('the scalar a property stands for', () {
      String scalar(String type) => types.scalarOf({'type': type});
      expect(scalar('uuid'), 'uuid');
      expect(scalar('Size'), 'enum');
      expect(scalar('Code'), 'string');
      expect(scalar('Point'), 'object');
      expect(scalar('list<int32>'), 'int32');
      expect(scalar('set<Part>'), 'object');
      expect(scalar('map<string, int32>'), 'object');
      expect(scalar('not a type'), 'unknown');
    });

    test('a path through a list ends at the identity of its element (R1.5)', () {
      expect(types.endsAtElementIdentity('Thing', 'parts.id'), isTrue);
      expect(types.endsAtElementIdentity('Thing', 'parts.size'), isFalse);
      expect(types.endsAtElementIdentity('Thing', 'anyParts.id'), isTrue);
      expect(types.endsAtElementIdentity('Thing', 'anyParts.size'), isFalse);
      expect(types.endsAtElementIdentity('Thing', 'points.x'), isFalse);
      expect(types.endsAtElementIdentity('Thing', 'parts.id.deeper'), isFalse);
      expect(types.endsAtElementIdentity('Thing', 'id'), isTrue);
      expect(types.endsAtElementIdentity('Thing', 'point.x'), isTrue);
      expect(types.endsAtElementIdentity('Thing', 'missing.x'), isTrue);
      expect(types.endsAtElementIdentity('Thing', 'tags.x'), isTrue);
    });
  });

  group('OpenAPI schemas', () {
    final document = LocatedDocument.parse('''
paths:
  /things:
    get:
      responses:
        "200": {content: {application/json: {schema: {\$ref: "#/components/schemas/Page"}}}}
        "404": {\$ref: "#/components/responses/Problem"}
    post:
      requestBody:
        content:
          text/plain: {schema: {type: string}}
          application/json: {schema: {\$ref: "#/components/schemas/Thing"}}
      responses:
        "500": {content: {application/problem+json: {schema: {type: object}}}}
components:
  responses:
    Problem: {content: {application/problem+json: {schema: {\$ref: "#/components/schemas/Problem"}}}}
  schemas:
    Base: {type: object, required: [id], properties: {id: {type: integer}}}
    Thing:
      allOf: [{\$ref: "#/components/schemas/Base"}, {missing: {\$ref: "#/nope"}}]
      required: [name]
      properties: {name: {type: [string, "null"]}, owner: {\$ref: "#/components/schemas/Base"}}
    Page: {type: object, properties: {items: {type: array, items: {\$ref: "#/components/schemas/Thing"}}}}
    Problem: {type: object, properties: {status: {type: integer}}}
    Loop: {\$ref: "#/components/schemas/Loop"}
    Remote: {\$ref: "other.json#/x"}
''', 'api.yaml');
    final schemas = OpenApiSchemas(
      Sources({'api': DocumentSource('api', 'api.yaml', document), 'db': SqlSource('db', 'db.sql', const {})}),
      'api',
    );
    Map<String, Object?> at(String pointer) => asMap(document.at(pointer));
    final get = at('/paths/~1things/get');
    final post = at('/paths/~1things/post');
    final thing = at('/components/schemas/Thing');

    test('follow local references, and give up on remote ones and loops', () {
      expect(schemas.resolve(at('/components/schemas/Problem'))!['type'], 'object');
      final element = LocatedDocument.elementAt(document.root, '/components/schemas/Thing');
      expect(identical(schemas.target({r'$ref': '#/components/schemas/Thing'}), element), isTrue);
      expect(identical(schemas.target({r'$ref': '#/components/schemas/Base'}), element), isFalse);
      expect(schemas.resolve(at('/components/schemas/Loop')), isNull);
      expect(schemas.resolve(at('/components/schemas/Remote')), isNull);
      expect(schemas.resolve({r'$ref': '#/components/schemas/Nope'}), isNull);
      expect(schemas.resolve('text'), isNull);
      expect(OpenApiSchemas(Sources(const {}), 'none').resolve({r'$ref': '#/x'}), isNull);
    });

    test('find the success, problem and request schemas of an operation', () {
      expect(schemas.successSchema(get)!.keys, contains('properties'));
      expect(schemas.problemSchema(get)!['properties'], {
        'status': {'type': 'integer'},
      });
      expect(schemas.problemSchema(post), {'type': 'object'});
      expect(schemas.successSchema(post), isNull);
      expect(schemas.requestSchema(post), thing);
      expect(schemas.requestSchema(get), isNull);
    });

    test('read properties, required names and types, also through allOf', () {
      expect(schemas.propertyNames(thing), {'name', 'owner', 'id'});
      expect(schemas.requiredNames(thing), {'name', 'id'});
      expect(schemas.propertyNames({r'$ref': '#/nope'}), isEmpty);
      expect(schemas.requiredNames({r'$ref': '#/nope'}), isEmpty);
      expect(schemas.isObject(thing), isTrue);
      expect(schemas.isObject({'type': 'string'}), isFalse);
      expect(schemas.isObject({r'$ref': '#/nope'}), isFalse);
      expect(schemas.isArray(at('/components/schemas/Page/properties/items')), isTrue);
      expect(
        schemas.isArray({
          'type': ['array', 'null'],
        }),
        isTrue,
      );
      expect(schemas.isArray({'type': 'object'}), isFalse);
      expect(schemas.isInteger(at('/components/schemas/Base/properties/id')), isTrue);
      expect(schemas.isInteger({'type': 'string'}), isFalse);
      expect(schemas.isInteger({r'$ref': '#/nope'}), isFalse);
    });

    test('find the schema of a nested property by pointer', () {
      expect(schemas.property(thing, '/owner/id'), {'type': 'integer'});
      expect(schemas.property(thing, '/id'), {'type': 'integer'});
      expect(schemas.property(thing, ''), thing);
      expect(schemas.property(thing, '/missing'), isNull);
      expect(schemas.property({r'$ref': '#/nope'}, '/id'), isNull);
      expect(
        schemas.property({
          'properties': {
            'a/b': {'type': 'string'},
          },
        }, '/a~1b'),
        {'type': 'string'},
      );
    });
  });

  group('the writer', () {
    late Directory work;

    setUp(() => work = Directory.systemTemp.createTempSync('rialto-writer'));
    tearDown(() => work.deleteSync(recursive: true));

    test('quotes the strings YAML would read otherwise, and drops empty values', () {
      final yaml = ContractWriter.toYaml({
        'plain': 'Thing',
        'version': '1.0.0',
        'reserved': 'yes',
        'comment': 'a #b',
        'trailing': 'a ',
        'colon': 'a: b',
        'number': 3,
        'flag': true,
        'empty': <String, Object?>{},
        'none': null,
        'list': [
          'a',
          {'source': 'Thing', 'target': 'api#/x'},
          [1, 2],
        ],
      });
      expect(
        yaml,
        'plain: Thing\n'
        'version: "1.0.0"\n'
        'reserved: "yes"\n'
        'comment: "a #b"\n'
        'trailing: "a "\n'
        'colon: "a: b"\n'
        'number: 3\n'
        'flag: true\n'
        'list:\n'
        '  - a\n'
        '  -\n'
        '    source: Thing\n'
        '    target: api#/x\n'
        '  - [1,2]\n',
      );
      final file = p.join(work.path, 'deeper/out.yaml');
      ContractWriter.write({'list': yaml}, file);
      expect(LocatedDocument.read(file).root, {'list': yaml});
    });
  });
}
