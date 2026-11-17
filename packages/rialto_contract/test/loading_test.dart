import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

const header = 'rialto: "1.0.0"\ninfo: {name: x, version: 1.0.0}\n';

void main() {
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('rialto-loading'));
  tearDown(() => work.deleteSync(recursive: true));

  String write(String name, String text) => (File(p.join(work.path, name))..writeAsStringSync(text)).path;

  List<Diagnostic> diagnostics(String name, String text) => ContractValidator.validate(write(name, text)).diagnostics;

  group('located documents', () {
    test('YAML keeps the line and column of every key and list element', () {
      final document = LocatedDocument.parse('a:\n  b: [x, y]\n  "c/d~e": 1\n', 'doc.yaml');
      expect(document.root, {
        'a': {
          'b': ['x', 'y'],
          'c/d~e': 1,
        },
      });
      expect(document.positions[''], ('doc.yaml', 1, 1));
      expect(document.positions['/a'], ('doc.yaml', 1, 1));
      expect(document.positions['/a/b'], ('doc.yaml', 2, 3));
      expect(document.positions['/a/b/1'], ('doc.yaml', 2, 10));
      expect(document.positions['/a/c~1d~0e'], ('doc.yaml', 3, 3));
    });

    test('JSON is read as YAML, with positions', () {
      final file = write('doc.json', '{\n  "types": {\n    "A": {"kind": "enum", "members": ["a"]}\n  }\n}\n');
      final document = LocatedDocument.read(file);
      expect(document.at('/types/A/members/0'), 'a');
      expect(document.locate('/types/A').line, 3);
      expect(document.locate('/types/A').column, 5);
    });

    test('a pointer without a position is located at its nearest ancestor', () {
      final document = LocatedDocument.parse('a:\n  b: 1\n', 'doc.yaml');
      final location = document.locate('/a/b/missing/deeper');
      expect((location.line, location.column, location.pointer), (2, 3, '/a/b/missing/deeper'));
      final empty = LocatedDocument.bundled('root.yaml', const {}, const {}).locate('/x');
      expect((empty.file, empty.line, empty.pointer), ('root.yaml', null, '/x'));
    });

    test('elementAt follows maps and list indexes, and returns null for anything that does not exist', () {
      final root = {
        'a': [
          {'b': 1},
          'c',
        ],
        'x/y': {'~': true},
      };
      expect(LocatedDocument.elementAt(root, ''), root);
      expect(LocatedDocument.elementAt(root, '/a/0/b'), 1);
      expect(LocatedDocument.elementAt(root, '/a/1'), 'c');
      expect(LocatedDocument.elementAt(root, '/x~1y/~0'), true);
      for (final pointer in ['a', '/missing', '/a/2', '/a/-1', '/a/first', '/a/1/deeper']) {
        expect(LocatedDocument.elementAt(root, pointer), isNull, reason: pointer);
      }
    });

    test('readMapping reads an empty file as an empty mapping and rejects anything else', () {
      expect(LocatedDocument.readMapping(write('empty.yaml', '  \n')).root, isEmpty);
      for (final (text, found) in [('- a\n', 'a list'), ('just text\n', 'a single value'), ('null\n', 'null')]) {
        expect(
          () => LocatedDocument.readMapping(write('doc.yaml', text)),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(found))),
        );
      }
    });

    test('the JSON value helpers give empty values for anything of another type', () {
      expect(asMap([1]), isEmpty);
      expect(asList({'a': 1}), isEmpty);
      expect(asString(1), isNull);
      expect(asMap({'a': 1}), {'a': 1});
      expect(asList([1]), [1]);
      expect(asString('a'), 'a');
    });
  });

  group('unreadable contracts (RIALTO-K001)', () {
    test('malformed YAML, malformed JSON, a missing file and a document that is no mapping', () {
      for (final (name, text) in [
        ('broken.yaml', 'rialto: "1.0.0"\ninfo: {name: x\n'),
        ('broken.json', '{"rialto": "1.0.0", "info": {"name": "x"'),
        ('list.yaml', '- rialto\n'),
        ('scalar.yaml', 'rialto\n'),
        ('duplicate.yaml', 'rialto: "1.0.0"\nrialto: "1.0.0"\n'),
      ]) {
        final result = ContractValidator.validate(write(name, text));
        expect(result.contract, isNull, reason: name);
        expect(result.valid, isFalse, reason: name);
        expect(result.diagnostics.map((it) => it.code), [Code.unreadable], reason: name);
        expect(result.diagnostics.single.location.file, endsWith(name));
      }
      final missing = ContractValidator.validate(p.join(work.path, 'missing.yaml'));
      expect(missing.diagnostics.single.code, Code.unreadable);
    });

    test('the message says what is wrong, without the name of an exception type', () {
      final list = ContractValidator.validate(write('list.yaml', '- rialto\n')).diagnostics.single;
      expect(list.message, 'The document is not a mapping but a list');
      final missingPath = p.join(work.path, 'missing.yaml');
      final missing = ContractValidator.validate(missingPath).diagnostics.single;
      expect(missing.message, endsWith(': $missingPath'));
      expect(missing.message, isNot(contains('Exception')));
      final broken = ContractValidator.validate(write('broken.yaml', 'a: [\n')).diagnostics.single;
      expect(broken.message, startsWith('Error on line'));
      expect(errorText(const FormatException('plain')), 'plain');
      expect(errorText(const FileSystemException('Cannot open file')), 'Cannot open file');
      expect(errorText(const HttpException('HTTP 404')), 'HTTP 404');
      expect(errorText(StateError('offline')), 'Bad state: offline');
    });

    test('an empty file is an empty mapping, which lacks rialto (RIALTO-K003)', () {
      expect(diagnostics('empty.yaml', '').map((it) => it.code), [Code.unsupportedVersion]);
    });
  });

  group('format version (RIALTO-K003)', () {
    test('another version is reported at rialto, with the version this tool reads', () {
      final diagnostic = diagnostics('v2.yaml', 'rialto: "2.0.0"\ninfo: {name: x, version: 1.0.0}\n').single;
      expect(diagnostic.code, Code.unsupportedVersion);
      expect(diagnostic.message, contains("'2.0.0'"));
      expect(diagnostic.hint, contains(ContractValidator.supportedVersion));
      expect((diagnostic.location.pointer, diagnostic.location.line), ('/rialto', 1));
    });

    test('a missing version is reported too, before the JSON Schema', () {
      final diagnostic = diagnostics('none.yaml', 'info: {name: x, version: 1.0.0}\n').single;
      expect(diagnostic.code, Code.unsupportedVersion);
      expect(diagnostic.message, "Contract format '' is not supported");
    });
  });

  group('JSON Schema (RIALTO-K002)', () {
    test('an unknown key is reported at the object that has it, with its line and column', () {
      final diagnostic = diagnostics('unknown.yaml', '# a comment\n${header}entities: {}\n').single;
      expect(diagnostic.code, Code.schema);
      expect(diagnostic.requirement, 'K1.7');
      expect(diagnostic.message, contains('entities'));
      expect((diagnostic.location.pointer, diagnostic.location.line, diagnostic.location.column), ('', 2, 1));
      expect(diagnostic.location.file, endsWith('unknown.yaml'));
    });

    test('a value of the wrong type is located at the value', () {
      final diagnostic = diagnostics('wrong.yaml', '${header}types:\n  Size: {kind: enum, members: small}\n').single;
      expect(diagnostic.code, Code.schema);
      expect(diagnostic.location.pointer, startsWith('/types/Size'));
      expect(diagnostic.location.line, 4);
    });

    test('a missing required property is reported once, at the object that lacks it', () {
      final found = diagnostics('required.yaml', 'rialto: "1.0.0"\ninfo: {name: x}\n');
      expect(found.map((it) => (it.code, it.location.pointer)), [(Code.schema, '/info')]);
      expect(found.single.message, contains('version'));
      expect(found.single.location.line, 2);
    });

    test('every violation is reported, ordered by pointer', () {
      final found = diagnostics('many.yaml', '${header}zeta: 1\ntypes:\n  bad name: {kind: enum, members: [a]}\n');
      expect(found, hasLength(greaterThanOrEqualTo(2)));
      expect(found.every((it) => it.code == Code.schema), isTrue);
      final pointers = found.map((it) => it.location.pointer).toList();
      expect(pointers, [...pointers]..sort());
    });

    test('a contract that conforms is valid and gives typed access to its sections', () {
      final result = ContractValidator.validate(
        write('ok.yaml', '${header}types:\n  Size: {kind: enum, members: [small]}\n'),
      );
      expect(result.valid, isTrue, reason: result.diagnostics.join('\n'));
      final contract = result.contract!;
      expect((contract.rialto, contract.version, contract.info['name']), ('1.0.0', '1.0.0', 'x'));
      expect(contract.types.keys, ['Size']);
      for (final section in [
        contract.sources,
        contract.shapes,
        contract.operations,
        contract.events,
        contract.streams,
        contract.subscriptions,
        contract.storage,
        contract.views,
        contract.navigation,
        contract.errors,
        contract.auth,
      ]) {
        expect(section, isEmpty);
      }
      expect(contract.mappings, isEmpty);
    });
  });

  group('diagnostics', () {
    test('print severity, code, file, position, pointer, message, requirement and hint', () {
      const location = Location('/a/b/contract.yaml', line: 3, column: 7, pointer: '/types/A');
      expect(
        const Diagnostic(Severity.error, Code.schema, 'wrong', location, hint: 'fix it').toString(),
        'error[RIALTO-K002] contract.yaml:3:7 #/types/A: wrong (K1.7)\n  hint: fix it',
      );
      expect(
        const Diagnostic(
          Severity.warning,
          Code.missingIdentity,
          'odd',
          Location('c.yaml'),
          requirement: 'X9.9',
        ).toString(),
        'warning[RIALTO-P001] c.yaml: odd (X9.9)',
      );
      expect(const Location('c.yaml', line: 2).toString(), 'c.yaml:2:1');
    });

    test('a warning does not fail a run, an error does', () {
      final diagnostics = Diagnostics()..warning(Code.schema, 'careful', const Location('c.yaml'), hint: 'h');
      expect(diagnostics.hasErrors, isFalse);
      expect(diagnostics.all.single.severity, Severity.warning);
      expect(diagnostics.all.single.hint, 'h');
      diagnostics.add(const Diagnostic(Severity.error, Code.schema, 'wrong', Location('c.yaml')));
      expect(diagnostics.hasErrors, isTrue);
      expect(() => diagnostics.all.add(diagnostics.all.first), throwsUnsupportedError);
      expect(
        const ValidationResult(Contract({}), [Diagnostic(Severity.warning, Code.schema, 'w', Location('c'))]).valid,
        isTrue,
      );
    });

    test('every code has a unique identifier, a requirement and a summary', () {
      expect(Code.values.map((it) => it.id).toSet(), hasLength(Code.values.length));
      for (final code in Code.values) {
        expect(code.id, matches(RegExp(r'^RIALTO-[KSP]\d{3}$')));
        expect(code.requirement, isNotEmpty);
        expect(code.summary, isNotEmpty);
      }
    });

    test('a check pointer escapes each segment', () {
      expect(CheckContext.pointer(['types', 'a/b', 'c~d', 0]), '/types/a~1b/c~0d/0');
    });
  });
}
