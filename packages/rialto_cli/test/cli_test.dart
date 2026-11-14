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
