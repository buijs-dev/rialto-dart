import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

const root = 'rialto: "1.0.0"\ninfo: {name: x, version: 1.0.0}\n';
const fragment = 'rialto: "1.0.0"\n';

void main() {
  late Directory work;
  late String contract;

  setUp(() {
    work = Directory.systemTemp.createTempSync('rialto-include');
    contract = p.join(work.path, 'contract.rialto.yaml');
  });
  tearDown(() => work.deleteSync(recursive: true));

  /// Writes the root [text] and the [files] next to it.
  void write(String text, [Map<String, String> files = const {}]) {
    File(contract).writeAsStringSync(text);
    files.forEach(
      (name, content) => File(p.join(work.path, name))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content),
    );
  }

  List<Diagnostic> validate() => ContractValidator.validate(contract).diagnostics;

  /// The code, the file relative to the work directory, the pointer and the line of each finding.
  List<(String, String, String, int?)> findings() => [
    for (final it in validate())
      (it.code.id, p.relative(it.location.file, from: work.path), it.location.pointer, it.location.line),
  ];

  const thing = 'types:\n  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}}}\n';

  group('include (K5)', () {
    test('merges keyed sections and mappings from every fragment, in path order', () {
      write('${root}include: ["parts/**/*.rialto.yaml"]\n', {
        'parts/a.rialto.yaml': '$fragment$thing',
        'parts/deeper/b.rialto.yaml':
            '${fragment}types:\n  Size: {kind: enum, members: [small]}\n'
            'mappings:\n  - {source: Thing, target: Thing, direction: toTarget}\n',
        'parts/c.rialto.yaml': '${fragment}mappings:\n  - {source: Thing, target: Thing, direction: both}\n',
        'parts/ignored.yaml': 'not: [a fragment\n',
      });
      final diagnostics = Diagnostics();
      final document = ContractFiles.read(contract, diagnostics)!;
      expect(diagnostics.all, isEmpty);
      final json = asMap(document.root);
      expect(json.keys, containsAll(['rialto', 'info', 'types', 'mappings']));
      expect(json.containsKey('include'), isFalse);
      expect(asMap(json['types']).keys, ['Thing', 'Size']);
      // parts/c sorts before parts/deeper/b.
      expect(asList(json['mappings']).map((it) => asMap(it)['direction']), ['both', 'toTarget']);
      final mapping = document.locate('/mappings/1/direction');
      expect((p.basename(mapping.file), mapping.line), ('b.rialto.yaml', 5));
      expect(p.basename(document.locate('/types/Size').file), 'b.rialto.yaml');
      expect(p.basename(document.locate('/info').file), 'contract.rialto.yaml');
      expect(ContractValidator.validate(contract).valid, isTrue);
    });

    test('lists its fragments for build tools, and none without include or when the root cannot be read', () {
      write('${root}include: [parts/*.yaml]\n', {'parts/b.yaml': fragment, 'parts/a.yaml': fragment});
      expect(ContractFiles.fragments(contract).map(p.basename), ['a.yaml', 'b.yaml']);
      write(root);
      expect(ContractFiles.fragments(contract), isEmpty);
      write('include: [');
      expect(ContractFiles.fragments(contract), isEmpty);
    });

    test('a root without include is read as it is', () {
      write('$root$thing');
      final document = ContractFiles.read(contract, Diagnostics())!;
      expect(document.positions['/types/Thing'], (contract, 4, 3));
    });

    test('an include that does not conform to the JSON Schema is RIALTO-K002', () {
      for (final (include, pointer) in [
        ('"parts/*.yaml"', '/include'),
        ('[]', '/include'),
        ('[42]', '/include/0'),
        ('[a.yaml, a.yaml]', '/include'),
      ]) {
        write('${root}include: $include\n', {'a.yaml': '$fragment$thing'});
        expect(findings().map((it) => (it.$1, it.$3)), [('RIALTO-K002', pointer)], reason: include);
      }
    });

    test('a path that matches no file is RIALTO-K007, at its entry', () {
      write('${root}include: [parts/*.yaml, missing/*.yaml, "**/none.yaml"]\n', {'parts/a.yaml': '$fragment$thing'});
      expect(findings(), [
        ('RIALTO-K007', 'contract.rialto.yaml', '/include/1', 3),
        ('RIALTO-K007', 'contract.rialto.yaml', '/include/2', 3),
      ]);
    });

    test('the root never includes itself', () {
      write('${root}include: ["*.yaml"]\n');
      expect(findings().map((it) => it.$1), ['RIALTO-K007']);
    });

    test('a fragment that declares info, sources or include is RIALTO-K008, once per key', () {
      write('${root}include: [parts/*.yaml]\n', {
        'parts/a.yaml':
            '${fragment}info: {name: y, version: 1.0.0}\n'
            'sources:\n  api: {kind: openapi, path: api.json}\n'
            'include: [other.yaml]\n$thing',
      });
      expect(findings(), [
        ('RIALTO-K008', 'parts/a.yaml', '/info', 2),
        ('RIALTO-K008', 'parts/a.yaml', '/sources', 3),
        ('RIALTO-K008', 'parts/a.yaml', '/include', 5),
      ]);
    });

    test('a section that belongs in one file appears in two: RIALTO-K009, naming the first file', () {
      const navigation = 'navigation: {home: Home}\n';
      write('${root}include: [parts/*.yaml]\n', {
        'parts/a.yaml': '$fragment$navigation',
        'parts/b.yaml': '$fragment$navigation',
      });
      final diagnostic = validate().single;
      expect(diagnostic.code, Code.sectionTwice);
      expect(diagnostic.message, contains('parts/a.yaml'));
      expect((p.basename(diagnostic.location.file), diagnostic.location.pointer), ('b.yaml', '/navigation'));

      write('$root${navigation}include: [parts/a.yaml]\n');
      expect(validate().single.message, contains('contract.rialto.yaml'));
    });

    test('a name declared in two files is RIALTO-K005, in the later file', () {
      write('$root${thing}include: [parts/*.yaml]\n', {'parts/a.yaml': '$fragment$thing'});
      final diagnostic = validate().single;
      expect(diagnostic.code, Code.duplicateName);
      expect(diagnostic.message, "'Thing' is already declared under types in contract.rialto.yaml");
      expect((p.basename(diagnostic.location.file), diagnostic.location.pointer), ('a.yaml', '/types/Thing'));
    });

    test('a fragment of another format version is RIALTO-K003, and one without a version too', () {
      write('${root}include: [parts/*.yaml]\n', {'parts/a.yaml': 'rialto: "2.0.0"\n$thing', 'parts/b.yaml': thing});
      expect(findings(), [
        ('RIALTO-K003', 'parts/a.yaml', '/rialto', 1),
        ('RIALTO-K003', 'parts/b.yaml', '/rialto', 1),
      ]);
      expect(validate().first.message, "Fragment has format '2.0.0', the root '1.0.0'");
    });

    test('a fragment that does not conform to the JSON Schema is RIALTO-K002, in the fragment', () {
      write('${root}include: [parts/*.yaml]\n', {'parts/a.yaml': '${fragment}types:\n  Size: {kind: enum}\n'});
      final found = findings();
      expect(found, isNotEmpty);
      expect(found.every((it) => it.$1 == 'RIALTO-K002' && it.$2 == 'parts/a.yaml'), isTrue, reason: '$found');
    });

    test('a fragment that cannot be read or is no mapping is RIALTO-K001', () {
      write('${root}include: [parts/*.yaml]\n', {'parts/a.yaml': 'types: [\n', 'parts/b.yaml': '- a\n'});
      expect(findings().map((it) => (it.$1, it.$2)), [
        ('RIALTO-K001', 'parts/a.yaml'),
        ('RIALTO-K001', 'parts/b.yaml'),
      ]);
    });

    test('a finding of a later check names the fragment it is in (K5.5)', () {
      write('${root}include: [parts/*.yaml]\n', {
        'parts/a.yaml': '${fragment}types:\n  A: {kind: value, properties: {b: {type: Missing}}}\n',
      });
      expect(findings(), [('RIALTO-K004', 'parts/a.yaml', '/types/A/properties/b/type', 3)]);
    });
  });

  group('bundle', () {
    test('writes the bundled form, with local source paths relative to the new place', () {
      File(p.join(work.path, 'api.json')).writeAsStringSync('{"openapi": "3.1.0", "components": {"schemas": {}}}');
      write(
        '${root}sources:\n'
        '  api: {kind: openapi, path: api.json}\n'
        '  remote: {kind: openapi, path: "https://x.example/api.json"}\n'
        'include: [parts/*.yaml]\n',
        {'parts/a.yaml': '$fragment$thing'},
      );
      final output = p.join(work.path, 'out/deeper/bundled.rialto.yaml');
      final diagnostics = Diagnostics();
      expect(ContractFiles.bundle(contract, output, diagnostics), isTrue);
      expect(diagnostics.all, isEmpty);
      final bundled = asMap(LocatedDocument.read(output).root);
      expect(bundled.containsKey('include'), isFalse);
      expect(asMap(bundled['types']).keys, ['Thing']);
      final sources = asMap(bundled['sources']);
      expect(asMap(sources['api'])['path'], '../../api.json');
      expect(asMap(sources['remote'])['path'], 'https://x.example/api.json');
    });

    test('writes a contract without sources or include as it is', () {
      write('$root$thing');
      final output = p.join(work.path, 'copy.rialto.yaml');
      expect(ContractFiles.bundle(contract, output, Diagnostics()), isTrue);
      expect(LocatedDocument.read(output).root, LocatedDocument.read(contract).root);
    });

    test('writes nothing when the contract has errors or cannot be read', () {
      final output = p.join(work.path, 'out.rialto.yaml');
      write('${root}include: [missing/*.yaml]\n');
      final diagnostics = Diagnostics();
      expect(ContractFiles.bundle(contract, output, diagnostics), isFalse);
      expect(diagnostics.all.single.code, Code.includeNoMatch);
      expect(ContractFiles.bundle(p.join(work.path, 'missing.yaml'), output, Diagnostics()), isFalse);
      expect(File(output).existsSync(), isFalse);
    });
  });

  test('include patterns: * within a segment, ** over any number of segments, everything else literal', () {
    final cases = {
      ('*.yaml', 'a.yaml'): true,
      ('*.yaml', 'x/a.yaml'): false,
      ('**/a.yaml', 'a.yaml'): true,
      ('**/a.yaml', 'x/y/a.yaml'): true,
      ('x/**', 'x/a.yaml'): true,
      ('x/**', 'x/a/b.yaml'): true,
      ('x/**', 'y/a.yaml'): false,
      ('**', 'a/b.yaml'): true,
      ('a/**/b/*.yaml', 'a/b/c.yaml'): true,
      ('a+b(c).yaml', 'a+b(c).yaml'): true,
      ('a?.yaml', 'ab.yaml'): false,
      ('[ab].yaml', 'a.yaml'): false,
    };
    cases.forEach((input, matches) {
      expect(ContractFiles.glob(input.$1).hasMatch(input.$2), matches, reason: '$input');
    });
  });
}
