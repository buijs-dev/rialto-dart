import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

final spec = p.normalize(p.join(Directory.current.path, '../../../rialto-spec'));

/// The test contracts of [directory]: single files and contracts over several files (their root).
List<File> testContracts(String directory) {
  final entries = Directory(p.join(spec, 'examples/contracts', directory)).listSync();
  final files = entries.whereType<File>().where((f) => f.path.endsWith('.yaml'));
  final roots = entries
      .whereType<Directory>()
      .map((d) => File(p.join(d.path, 'contract.rialto.yaml')))
      .where((f) => f.existsSync());
  return [...files, ...roots]..sort((a, b) => a.path.compareTo(b.path));
}

const header = 'rialto: "1.0.0"\ninfo: {name: x, version: 1.0.0}\n';

void main() {
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('rialto-contract'));
  tearDown(() => work.deleteSync(recursive: true));

  /// Writes [text] as a contract in the work directory, with [files] next to it.
  String write(String text, {Map<String, String> files = const {}}) {
    files.forEach(
      (name, content) => File(p.join(work.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content),
    );
    return (File(p.join(work.path, 'contract.rialto.yaml'))..writeAsStringSync(text)).path;
  }

  test('the schema is the one of the specification', () {
    final original = File(p.join(spec, 'spec/contract-1.0.0.schema.json')).readAsStringSync();
    expect(jsonDecode(contractSchema), jsonDecode(original));
  });

  test('the code table is the one of the specification', () {
    final table = RegExp(r'^\| `(RIALTO-[A-Z]\d{3})` \|.*\| ([^|]+) \|$', multiLine: true);
    final specified = {
      for (final m in table.allMatches(File(p.join(spec, 'spec/contract.md')).readAsStringSync()))
        m.group(1)!: m.group(2)!.trim().split(', '),
    };
    expect(Code.values.map((it) => it.id).toList(), specified.keys.toList());
    for (final code in Code.values) {
      expect(specified[code.id], contains(code.requirement), reason: code.id);
    }
  });

  group('shared contracts', () {
    for (final file in testContracts('valid')) {
      test('valid ${p.relative(file.path, from: p.join(spec, 'examples/contracts'))}', () {
        final result = ContractValidator.validate(file.path);
        expect(result.valid, isTrue, reason: result.diagnostics.join('\n'));
      });
    }
    for (final file in testContracts('invalid')) {
      test('invalid ${p.relative(file.path, from: p.join(spec, 'examples/contracts'))}', () {
        final expected = RegExp(
          r'# expect: (RIALTO-\w+)',
        ).allMatches(file.readAsStringSync()).map((m) => m.group(1)).toSet();
        expect(expected, isNotEmpty, reason: 'fixture names no expected code');
        final result = ContractValidator.validate(file.path);
        expect(result.valid, isFalse);
        expect(
          result.diagnostics.map((it) => it.code.id).toSet(),
          containsAll(expected),
          reason: result.diagnostics.join('\n'),
        );
      });
    }
  });

  group('contract over several files', () {
    final fragments = p.join(spec, 'examples/contracts/valid/fragments/contract.rialto.yaml');

    test('the fragments bundle to one document without include', () {
      final root = asMap(ContractFiles.read(fragments, Diagnostics())!.root);
      expect(root.containsKey('include'), isFalse);
      expect(asMap(root['types']).keys, containsAll(['Thing', 'Size']));
    });

    test('the bundled form written elsewhere is valid', () {
      final output = p.join(work.path, 'out/fragments.rialto.yaml');
      expect(ContractFiles.bundle(fragments, output, Diagnostics()), isTrue);
      expect(ContractValidator.validate(output).diagnostics, isEmpty);
    });

    test('a diagnostic in a fragment names the fragment', () {
      final result = ContractValidator.validate(
        p.join(spec, 'examples/contracts/invalid/fragment-duplicate/contract.rialto.yaml'),
      );
      final location = result.diagnostics.single.location;
      expect(location.file, endsWith('parts/b.rialto.yaml'));
      expect(location.pointer, '/types/Thing');
      expect(location.line, 3);
    });

    test('include paths match within a segment with * and across segments with **', () {
      expect(ContractFiles.glob('parts/*.rialto.yaml').hasMatch('parts/a.rialto.yaml'), isTrue);
      expect(ContractFiles.glob('parts/*.rialto.yaml').hasMatch('parts/x/a.rialto.yaml'), isFalse);
      expect(ContractFiles.glob('contract/**/*.rialto.yaml').hasMatch('contract/a.rialto.yaml'), isTrue);
      expect(ContractFiles.glob('contract/**/*.rialto.yaml').hasMatch('contract/x/y/a.rialto.yaml'), isTrue);
      expect(ContractFiles.glob('a.b.yaml').hasMatch('aXb.yaml'), isFalse);
    });
  });

  group('type expressions', () {
    test('parses scalars, decimals and collections', () {
      expect(TypeExpression.parse('decimal(10,2)'), const ScalarType('decimal', 10, 2));
      expect(TypeExpression.parse('list<string?>'), const ListType(ScalarType('string'), true));
      expect(
        TypeExpression.parse('map<uuid, Shipment>'),
        const MapType(ScalarType('uuid'), NamedType('Shipment'), false),
      );
    });

    test('rejects invalid expressions', () {
      for (final text in ['decimal(2,3)', 'map<boolean, string>', 'string?', 'list<>', 'shipment']) {
        expect(TypeExpression.parse(text), isNull, reason: text);
      }
    });
  });

  test('a diagnostic carries file, line and pointer', () {
    final result = ContractValidator.validate(
      write('${header}types:\n  A: {kind: value, properties: {b: {type: Missing}}}\n'),
    );
    final diagnostic = result.diagnostics.single;
    expect(diagnostic.code, Code.unresolvedReference);
    expect(diagnostic.toString(), contains('contract.rialto.yaml:4:'));
    expect(diagnostic.location.pointer, '/types/A/properties/b/type');
  });

  group('format checks', () {
    List<(String, String)> findings(String text, {Map<String, String> files = const {}}) => [
      for (final it in ContractValidator.validate(write(text, files: files)).diagnostics)
        (it.code.id, it.location.pointer),
    ];

    test('references to contract elements resolve in every section (K1.2)', () {
      expect(
        findings('''${header}types:
  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}}}
operations:
  getThing: {output: Missing, emits: [Gone]}
views:
  ThingView: {load: nope, tabs: [Other]}
navigation:
  home: Nowhere
'''),
        [
          ('RIALTO-K004', '/operations/getThing/output'),
          ('RIALTO-K004', '/operations/getThing/emits/0'),
          ('RIALTO-K004', '/views/ThingView/load'),
          ('RIALTO-K004', '/views/ThingView/tabs/0'),
          ('RIALTO-K004', '/navigation/home'),
        ],
      );
    });

    test('a shape names properties of its source (K1.2)', () {
      expect(
        findings('''${header}types:
  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}}}
shapes:
  ThingInput: {source: Thing, properties: {name: {role: caller}}}
'''),
        [('RIALTO-K004', '/shapes/ThingInput/properties/name')],
      );
    });

    test('a map key is a scalar or an enum (K2.1)', () {
      expect(
        findings('''${header}types:
  Size: {kind: enum, members: [small]}
  Point: {kind: value, properties: {x: {type: int32}}}
  Thing:
    kind: value
    properties:
      bySize: {type: "map<Size, string>"}
      byPoint: {type: "map<Point, string>"}
'''),
        [('RIALTO-K006', '/types/Thing/properties/byPoint/type')],
      );
    });

    test('references into an SQL source resolve against its tables and columns', () {
      expect(
        findings(
          '''${header}sources:
  db: {kind: sql, path: schema.sql, dialect: postgresql}
types:
  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}, name: {type: string}}}
storage:
  Thing: {table: db#thing, columns: {id: id, name: title}}
''',
          files: {'schema.sql': 'CREATE TABLE thing (id uuid PRIMARY KEY, name text NOT NULL);\n'},
        ),
        [('RIALTO-S002', '/storage/Thing/columns/name')],
      );
    });

    test('a migration path that matches no file is S001, an unknown source K004', () {
      expect(
        findings('''${header}sources:
  db: {kind: sql, path: missing/*.sql, dialect: postgresql}
types:
  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}}}
storage:
  Thing: {table: other#thing}
'''),
        [('RIALTO-S001', '/sources/db/path'), ('RIALTO-K004', '/storage/Thing/table')],
      );
    });

    test('the rules of the profiles are not format checks', () {
      // An identity that is no property breaks a rule of the domain profile (D2.2, RIALTO-P001), not the format.
      expect(
        findings('${header}types:\n  Thing: {kind: entity, identity: [id], properties: {name: {type: string}}}\n'),
        isEmpty,
      );
    });

    test('a profile adds its checks to those of the validator', () {
      final result = ContractValidator.validate(
        write('${header}types:\n  Thing: {kind: entity, identity: [id], properties: {name: {type: string}}}\n'),
        checks: [...ContractValidator.checks, const _IdentityCheck()],
      );
      expect(result.diagnostics.map((it) => (it.code.id, it.requirement, it.location.pointer)), [
        ('RIALTO-P001', 'D2.2', '/types/Thing/identity'),
      ]);
    });
  });

  test('the writer round-trips a contract', () {
    final original = ContractValidator.validate(
      write('''${header}types:
  Size: {kind: enum, members: [small, large]}
  Thing:
    kind: entity
    identity: [id]
    properties:
      id: {type: uuid, description: "The identity: one per thing"}
      size: {type: Size}
'''),
    ).contract!;
    final copy = p.join(work.path, 'roundtrip.rialto.yaml');
    ContractWriter.write(original.json, copy);
    final result = ContractValidator.validate(copy);
    expect(result.valid, isTrue, reason: result.diagnostics.join('\n'));
    expect(result.contract!.json, original.json);
  });
}

/// A check of a profile, as a later slice adds one.
class _IdentityCheck extends ContractCheck {
  const _IdentityCheck();

  @override
  void run(CheckContext context) {
    context.contract.types.forEach((name, value) {
      final type = asMap(value);
      final properties = asMap(type['properties']);
      for (final identity in asList(type['identity']).whereType<String>()) {
        if (!properties.containsKey(identity)) {
          context.error(
            Code.missingIdentity,
            "Identity '$identity' is not a property",
            CheckContext.pointer(['types', name, 'identity']),
          );
        }
      }
    });
  }
}
