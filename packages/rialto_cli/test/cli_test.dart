import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_cli/rialto_cli.dart';
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

final spec = p.normalize(p.join(Directory.current.path, '../../../rialto-spec'));
final contracts = p.join(spec, 'examples/contracts');

void main() {
  test('validates a valid contract', () async {
    final out = StringBuffer();
    final code = await runRialto(['validate', p.join(contracts, 'valid/minimal.yaml')], out: out, err: StringBuffer());
    expect(code, 0);
    expect(out.toString(), contains('minimal.yaml: valid'));
  });

  test('reports an invalid contract with its code and exit code 1', () async {
    final err = StringBuffer();
    final code = await runRialto(
      ['validate', p.join(contracts, 'invalid/unknown-type.yaml')],
      out: StringBuffer(),
      err: err,
    );
    expect(code, 1);
    expect(err.toString(), contains('error[RIALTO-K004] unknown-type.yaml:'));
  });

  test('validate --format json prints one document with the diagnostics', () async {
    final out = StringBuffer();
    final code = await runRialto(
      ['validate', '--format', 'json', p.join(contracts, 'invalid/unknown-type.yaml')],
      out: out,
      err: StringBuffer(),
    );
    final json = jsonDecode(out.toString()) as Map<String, Object?>;
    final contract = (json['contracts'] as List).single as Map<String, Object?>;
    final diagnostic = (contract['diagnostics'] as List).cast<Map<String, Object?>>().single;
    expect(code, 1);
    expect(json['valid'], false);
    expect(contract['valid'], false);
    expect(diagnostic['severity'], 'error');
    expect(diagnostic['code'], 'RIALTO-K004');
    expect(diagnostic['requirement'], 'K1.2');
    expect(diagnostic['line'], isA<int>());
    expect(diagnostic['pointer'], '/types/Thing/properties/owner/type');
    expect(
      await runRialto(
        ['validate', '--format', 'xml', p.join(contracts, 'valid/minimal.yaml')],
        out: StringBuffer(),
        err: StringBuffer(),
      ),
      64,
    );
  });

  test('bundles a contract over several files into one valid document', () async {
    final work = Directory.systemTemp.createTempSync('rialto-cli');
    addTearDown(() => work.deleteSync(recursive: true));
    final output = p.join(work.path, 'fragments.rialto.yaml');
    final code = await runRialto(
      ['bundle', '--output', output, p.join(contracts, 'valid/fragments/contract.rialto.yaml')],
      out: StringBuffer(),
      err: StringBuffer(),
    );
    expect(code, 0);
    expect(File(output).readAsStringSync(), isNot(contains('include')));
    expect(await runRialto(['validate', output], out: StringBuffer(), err: StringBuffer()), 0);
  });

  test('rejects wrong usage with exit code 64', () async {
    for (final args in [
      ['frobnicate'],
      ['validate'],
      ['bundle', 'x.yaml'],
      ['sources'],
      ['generate', '--output', 'out', 'x.yaml'],
    ]) {
      expect(
        await runRialto(args, out: StringBuffer(), err: StringBuffer()),
        64,
        reason: '$args',
      );
    }
  });

  group('validate', () {
    test('validates several contracts, reports the missing one on stderr and fails', () async {
      final out = StringBuffer(), err = StringBuffer();
      final missing = p.join(contracts, 'valid/missing.yaml');
      final code = await runRialto(['validate', p.join(contracts, 'valid/minimal.yaml'), missing], out: out, err: err);
      expect(code, 1);
      expect(out.toString(), contains('minimal.yaml: valid'));
      expect(err.toString(), 'error: $missing not found\n');
    });

    test('--format text is the default output', () async {
      final file = p.join(contracts, 'invalid/unknown-type.yaml');
      final text = StringBuffer(), plain = StringBuffer();
      expect(await runRialto(['validate', '--format', 'text', file], out: StringBuffer(), err: text), 1);
      expect(await runRialto(['validate', file], out: StringBuffer(), err: plain), 1);
      expect(text.toString(), plain.toString());
    });

    test('--format json reports a valid contract and a missing file in one document', () async {
      final out = StringBuffer(), err = StringBuffer();
      final valid = p.join(contracts, 'valid/minimal.yaml');
      final code = await runRialto(['validate', valid, '--format', 'json', 'missing.yaml'], out: out, err: err);
      expect(code, 1);
      expect(err.toString(), isEmpty);
      final json = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(json['valid'], false);
      expect(json['contracts'], [
        {'file': valid, 'valid': true, 'diagnostics': <Object?>[]},
        {
          'file': 'missing.yaml',
          'valid': false,
          'diagnostics': [
            {'severity': 'error', 'code': null, 'message': 'missing.yaml not found'},
          ],
        },
      ]);

      final only = StringBuffer();
      expect(await runRialto(['validate', '--format', 'json', valid], out: only, err: StringBuffer()), 0);
      expect((jsonDecode(only.toString()) as Map)['valid'], true);
    });

    test('--format json carries every field of a diagnostic', () async {
      final out = StringBuffer();
      final file = p.join(contracts, 'invalid/unsupported-version.yaml');
      await runRialto(['validate', '--format', 'json', file], out: out, err: StringBuffer());
      final contract = ((jsonDecode(out.toString()) as Map)['contracts'] as List).single as Map;
      final diagnostic = (contract['diagnostics'] as List).single as Map;
      expect(diagnostic.keys, [
        'severity',
        'code',
        'requirement',
        'file',
        'line',
        'column',
        'pointer',
        'message',
        'hint',
      ]);
      expect(diagnostic['code'], 'RIALTO-K003');
      expect(diagnostic['file'], file);
      expect(diagnostic['pointer'], '/rialto');
      expect(diagnostic['hint'], contains('1.0.0'));
    });

    test('rejects --format without a value or without contracts, and prints the usage', () async {
      final valid = p.join(contracts, 'valid/minimal.yaml');
      for (final args in [
        ['validate', valid, '--format'],
        ['validate', '--format', 'json'],
        ['validate', '--offline'],
      ]) {
        final err = StringBuffer();
        expect(
          await runRialto(args, out: StringBuffer(), err: err),
          64,
          reason: '$args',
        );
        expect(err.toString(), '$usage\n');
      }
    });
  });

  group('bundle', () {
    late Directory work;

    setUp(() => work = Directory.systemTemp.createTempSync('rialto-cli'));
    tearDown(() => work.deleteSync(recursive: true));

    test('reports where it bundled to', () async {
      final out = StringBuffer();
      final input = p.join(contracts, 'valid/fragments/contract.rialto.yaml');
      final output = p.join(work.path, 'out.rialto.yaml');
      expect(await runRialto(['bundle', input, '--output', output], out: out, err: StringBuffer()), 0);
      expect(out.toString(), '$input: bundled into $output\n');
    });

    test('writes nothing for a contract with errors, and fails', () async {
      final err = StringBuffer();
      final output = p.join(work.path, 'out.rialto.yaml');
      final input = p.join(contracts, 'invalid/fragment-include-missing/contract.rialto.yaml');
      expect(await runRialto(['bundle', '--output', output, input], out: StringBuffer(), err: err), 1);
      expect(err.toString(), contains('error[RIALTO-K007]'));
      expect(File(output).existsSync(), isFalse);
    });

    test('rejects a missing output or more than one contract', () async {
      for (final args in [
        ['bundle', 'a.yaml', '--output'],
        ['bundle', '--output', 'out.yaml'],
        ['bundle', '--output', 'out.yaml', 'a.yaml', 'b.yaml'],
      ]) {
        expect(
          await runRialto(args, out: StringBuffer(), err: StringBuffer()),
          64,
          reason: '$args',
        );
      }
    });
  });

  group('sources update', () {
    late Directory work;

    setUp(() => work = Directory.systemTemp.createTempSync('rialto-cli'));
    tearDown(() => work.deleteSync(recursive: true));

    test('updates nothing for a contract without remote sources', () async {
      final out = StringBuffer();
      expect(
        await runRialto(['sources', 'update', p.join(contracts, 'valid/minimal.yaml')], out: out, err: StringBuffer()),
        0,
      );
      expect(out.toString(), '0 remote source(s) updated in rialto.lock\n');
    });

    test('fails on a contract it cannot read', () async {
      final err = StringBuffer(), out = StringBuffer();
      final file = File(p.join(work.path, 'broken.yaml'))..writeAsStringSync('- a\n');
      expect(await runRialto(['sources', 'update', file.path], out: out, err: err), 1);
      expect(err.toString(), contains('error[RIALTO-K001]'));
      expect(out.toString(), isEmpty);
    });

    test('rejects another subcommand', () async {
      expect(await runRialto(['sources', 'list', 'x.yaml'], out: StringBuffer(), err: StringBuffer()), 64);
    });
  });

  test('the executable exits with the code of the run and prints to stdout and stderr', () async {
    final valid = await Process.run(Platform.resolvedExecutable, [
      'bin/rialto.dart',
      'validate',
      p.join(contracts, 'valid/minimal.yaml'),
    ]);
    expect(valid.exitCode, 0, reason: '${valid.stderr}');
    expect(valid.stdout, contains('minimal.yaml: valid'));
    final usage = await Process.run(Platform.resolvedExecutable, ['bin/rialto.dart']);
    expect(usage.exitCode, 64);
    expect(usage.stderr, contains('Usage:'));
  });

  group('remote sources', () {
    const url = 'https://api.example.com/things/api.json';
    late Directory work;
    late String contract;
    late List<int> served;

    setUp(() {
      work = Directory.systemTemp.createTempSync('rialto-cli');
      RemoteSources.cacheDirectory = p.join(work.path, 'cache');
      served = File(p.join(contracts, 'support/api.json')).readAsBytesSync();
      RemoteSources.fetch = (uri) async => uri.toString() == url ? served : throw StateError('404');
      contract = p.join(work.path, 'remote.rialto.yaml');
      File(contract).writeAsStringSync('''rialto: "1.0.0"
info: {name: remote, version: 1.0.0}
sources:
  api: {kind: openapi, path: "$url", version: 2.0.0, status: current}
types:
  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}}}
mappings:
  - {source: api#/components/schemas/Thing, target: Thing, direction: toTarget}
''');
    });

    tearDown(() {
      RemoteSources.cacheDirectory = null;
      RemoteSources.fetch = (_) async => throw StateError('no network in tests');
      work.deleteSync(recursive: true);
    });

    String lock() => File(p.join(work.path, RemoteSources.lockFile)).readAsStringSync();

    test('a lock that cannot be read fails validate with RIALTO-K010 and still reports the other findings', () async {
      Directory(p.join(work.path, RemoteSources.lockFile)).createSync();
      File(contract).writeAsStringSync('${File(contract).readAsStringSync()}storage:\n  Thing: {table: db#thing}\n');
      for (final format in [
        <String>[],
        ['--format', 'json'],
      ]) {
        final out = StringBuffer(), err = StringBuffer();
        expect(
          await runRialto(['validate', ...format, contract], out: out, err: err),
          1,
          reason: '$format',
        );
        final codes = format.isEmpty
            ? RegExp(r'error\[(RIALTO-\w+)\]').allMatches(err.toString()).map((m) => m.group(1)).toList()
            : [
                for (final d
                    in (((jsonDecode(out.toString()) as Map)['contracts'] as List).single as Map)['diagnostics']
                        as List)
                  (d as Map)['code'],
              ];
        expect(codes, ['RIALTO-K010', 'RIALTO-K004'], reason: '$format');
      }
      final err = StringBuffer();
      expect(await runRialto(['sources', 'update', contract], out: StringBuffer(), err: err), 1);
      expect(err.toString(), contains('error[RIALTO-K010]'));
    });

    test('a lock that cannot be written fails validate with RIALTO-K010 instead of crashing', () async {
      Directory(RemoteSources.cacheDir()).createSync();
      Process.runSync('chmod', ['555', work.path]);
      addTearDown(() => Process.runSync('chmod', ['755', work.path]));
      final err = StringBuffer();
      expect(await runRialto(['validate', contract], out: StringBuffer(), err: err), 1);
      expect(err.toString(), contains('error[RIALTO-K010]'));
      expect(err.toString(), contains('Cannot write the lock'));
      expect(err.toString(), contains('Not pinned: $url'));
    }, testOn: '!windows');

    test('validate --offline needs the cache, validate fetches and locks', () async {
      final err = StringBuffer();
      expect(await runRialto(['validate', '--offline', contract], out: StringBuffer(), err: err), 1);
      expect(err.toString(), contains('RIALTO-S003'));
      expect(await runRialto(['validate', contract], out: StringBuffer(), err: StringBuffer()), 0);
      expect(lock(), contains('"$url": "${RemoteSources.sha256(served)}"'));
      RemoteSources.fetch = (_) async => throw StateError('offline');
      expect(await runRialto(['validate', '--offline', contract], out: StringBuffer(), err: StringBuffer()), 0);
    });

    test('sources update accepts a changed source and reports the change', () async {
      expect(await runRialto(['validate', contract], out: StringBuffer(), err: StringBuffer()), 0);
      final before = RemoteSources.sha256(served);
      served = [...served, 32];
      // A cached copy of the locked version is still read; without it the changed version is fetched.
      Directory(RemoteSources.cacheDir()).deleteSync(recursive: true);
      final err = StringBuffer();
      expect(await runRialto(['validate', contract], out: StringBuffer(), err: err), 1);
      expect(err.toString(), contains('RIALTO-S004'));
      expect(lock(), contains(before));

      final out = StringBuffer();
      expect(await runRialto(['sources', 'update', contract], out: out, err: StringBuffer()), 0);
      final after = RemoteSources.sha256(served);
      expect(out.toString(), '$url: $before -> $after\n1 remote source(s) updated in rialto.lock\n');
      expect(lock(), contains('"$url": "$after"'));
      expect(await runRialto(['validate', contract], out: StringBuffer(), err: StringBuffer()), 0);
      expect(await runRialto(['sources', 'update'], out: StringBuffer(), err: StringBuffer()), 64);
    });
  });
}
