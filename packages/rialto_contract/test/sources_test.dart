import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

const header = 'rialto: "1.0.0"\ninfo: {name: x, version: 1.0.0}\n';

void main() {
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('rialto-sources'));
  tearDown(() => work.deleteSync(recursive: true));

  void file(String name, String content) => File(p.join(work.path, name))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  ValidationResult validate(String text) {
    file('contract.rialto.yaml', text);
    return ContractValidator.validate(p.join(work.path, 'contract.rialto.yaml'));
  }

  group('local sources (RIALTO-S001)', () {
    test('a source file that does not exist', () {
      final diagnostic = validate(
        '${header}sources:\n  api: {kind: openapi, path: missing.json, version: 1.0.0, status: current}\n',
      ).diagnostics.single;
      expect(
        (diagnostic.code, diagnostic.location.pointer, diagnostic.location.line),
        (Code.sourceUnreadable, '/sources/api/path', 4),
      );
      expect(diagnostic.message, "Source 'api' not found: missing.json");
    });

    test('a source file that cannot be parsed', () {
      file('api.yaml', 'openapi: [3.1.0\n');
      final diagnostic = validate(
        '${header}sources:\n  api: {kind: openapi, path: api.yaml, version: 1.0.0, status: current}\n',
      ).diagnostics.single;
      expect(diagnostic.code, Code.sourceUnreadable);
      expect(diagnostic.message, startsWith("Source 'api' cannot be read"));
    });

    test('a migration path that matches no file, in an existing directory or not', () {
      file('db/notes.txt', 'none');
      for (final path in ['db/*.sql', 'nowhere/**/*.sql']) {
        final diagnostic = validate(
          '${header}sources:\n  db: {kind: sql, path: "$path", dialect: postgresql}\n',
        ).diagnostics.single;
        expect((diagnostic.code, diagnostic.location.pointer), (Code.sourceUnreadable, '/sources/db/path'));
        expect(diagnostic.message, "Source 'db' matches no migration: $path");
      }
    });
  });

  group('migrations (K1.9)', () {
    test('are applied in version order, part by part, unversioned files last in code point order', () {
      for (final name in ['V1.10__c.sql', 'V1.9__b.sql', 'V1__a.sql', 'V1_9_1__x.sql', 'b.sql', 'a.sql', 'V2__d.sql']) {
        file('db/$name', '');
      }
      file('db/nested/V3__e.sql', '');
      expect(migrations(work.path, 'db/*.sql').map(p.basename), [
        'V1__a.sql',
        'V1.9__b.sql',
        'V1_9_1__x.sql',
        'V1.10__c.sql',
        'V2__d.sql',
        'a.sql',
        'b.sql',
      ]);
      expect(migrations(work.path, 'db/**/*.sql').map(p.basename), contains('V3__e.sql'));
      expect(migrations(work.path, 'nowhere/*.sql'), isEmpty);
    });

    test('the schema is the result of all of them, and references into it resolve', () {
      file('db/V1__create.sql', 'CREATE TABLE thing (id uuid PRIMARY KEY)');
      file('db/V2__alter.sql', 'ALTER TABLE thing ADD COLUMN name text');
      final result = validate('''${header}sources:
  db: {kind: sql, path: "db/*.sql", dialect: postgresql}
types:
  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}, name: {type: string}}}
storage:
  Thing: {table: db#thing, columns: {id: id, name: name}}
''');
      expect(result.diagnostics, isEmpty);
    });
  });

  group('resolving references', () {
    late Sources sources;

    setUp(() {
      final document = LocatedDocument.parse('{"components": {"schemas": {"Thing": {}}}}', 'api.json');
      sources = Sources({
        'api': DocumentSource('api', 'api.json', document),
        'db': SqlSource('db', 'schema.sql', SqlSchema.read('CREATE TABLE thing (id uuid, name text)')),
      });
    });

    test('into a document by JSON Pointer and into an SQL schema by table and column, in any case', () {
      const declared = {'api', 'db', 'broken'};
      expect(sources.resolve('api#/components/schemas/Thing', declared).$1, Resolution.resolved);
      expect(sources.resolve('api#/components/schemas/Nope', declared).$1, Resolution.missing);
      expect(sources.resolve('db#THING', declared).$1, Resolution.resolved);
      expect(sources.resolve('db#thing.Name', declared).$1, Resolution.resolved);
      expect(sources.resolve('db#thing.missing', declared).$1, Resolution.missing);
      expect(sources.resolve('db#other', declared).$1, Resolution.missing);
      expect(sources.resolve('broken#/x', declared), (Resolution.unloaded, null));
      expect(sources.resolve('nope#/x', declared), (Resolution.unknownSource, null));
      expect(sources.resolve('api', declared).$1, Resolution.resolved);
    });

    test('gives the table and the element a reference names', () {
      expect(sources.table('db#Thing')!.columns.keys, ['id', 'name']);
      expect(sources.table('db#nope'), isNull);
      expect(sources.table('api#/components'), isNull);
      expect(sources.element('api#/components/schemas/Thing'), isEmpty);
      expect(sources.element('api'), isNull);
      expect(sources.element('db#thing'), isNull);
      expect((sources.loaded['db']! as SqlSource).tables, {
        'thing': {'id', 'name'},
      });
    });
  });
}
