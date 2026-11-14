import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

final spec = p.normalize(p.join(Directory.current.path, '../../../rialto-spec'));
final support = p.join(spec, 'examples/contracts/support');
const url = 'https://api.example.com/things/api.json';

/// A contract whose OpenAPI source is [path], with a mapping that refers into it.
String contractText(String path) =>
    '''rialto: "1.0.0"
info: {name: remote, version: 1.0.0}
sources:
  api: {kind: openapi, path: "$path", version: 2.0.0, status: current}
types:
  Thing: {kind: entity, identity: [id], properties: {id: {type: uuid}}}
mappings:
  - {source: api#/components/schemas/Thing, target: Thing, direction: toTarget}
''';

void main() {
  late Directory work;
  late Directory cache;
  late String contract;
  List<int>? served;

  setUp(() {
    work = Directory.systemTemp.createTempSync('rialto-work');
    cache = Directory.systemTemp.createTempSync('rialto-cache');
    RemoteSources.cacheDirectory = cache.path;
    served = File(p.join(support, 'api.json')).readAsBytesSync();
    RemoteSources.fetch = (uri) async =>
        uri.toString() == url ? (served ?? (throw StateError('offline'))) : throw StateError('404');
    contract = p.join(work.path, 'remote.rialto.yaml');
    File(contract).writeAsStringSync(contractText(url));
  });

  tearDown(() {
    RemoteSources.cacheDirectory = null;
    RemoteSources.fetch = (_) async => throw StateError('no network in tests');
    work.deleteSync(recursive: true);
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  Future<List<String>> codes([RemoteMode remote = RemoteMode.locked]) async =>
      (await ContractValidator.validateAsync(contract, remote: remote)).diagnostics.map((it) => it.code.id).toList();

  String lock() => File(p.join(work.path, RemoteSources.lockFile)).readAsStringSync();

  test('fetches a new remote source, locks it and reads it offline from the cache (K4.1, K4.3)', () async {
    expect(await codes(), isEmpty);
    expect(lock(), contains('"$url": "${RemoteSources.sha256(served!)}"'));

    served = null;
    expect(await codes(RemoteMode.offline), isEmpty);
    expect(await codes(), isEmpty);
  });

  test('writes the lock deterministically, in the format of the JVM tooling', () async {
    await codes();
    expect(
      lock(),
      '# Written by Rialto: the SHA-256 of every remote source of the contract (K4). Commit this file;\n'
      '# `rialto sources update` accepts new versions.\n'
      'sources:\n'
      '  "$url": "${RemoteSources.sha256(served!)}"\n',
    );
    expect(File(p.join(cache.path, 'sha256', RemoteSources.sha256(served!), 'api.json')).existsSync(), isTrue);
  });

  test('reports a lock it cannot read', () async {
    File(p.join(work.path, RemoteSources.lockFile)).writeAsStringSync('sources: [oops]\n');
    expect(await codes(), ['RIALTO-K001']);
  });

  test('reads a locked source from the cache without fetching it', () async {
    await codes();
    RemoteSources.fetch = (_) async => throw StateError('must not fetch');
    expect(await codes(), isEmpty);
  });

  test('rejects a changed source until it is updated on purpose (K4.2)', () async {
    await codes();
    final before = lock();
    cache.deleteSync(recursive: true);
    served = [...served!, ...utf8.encode(' ')];

    expect(await codes(), ['RIALTO-S004']);
    expect(lock(), before);

    final diagnostics = Diagnostics();
    final changes = await RemoteSources.update(contract, diagnostics);
    expect(diagnostics.all, isEmpty);
    expect(changes, hasLength(1));
    expect(changes.single.url, url);
    expect(changes.single.after, RemoteSources.sha256(served!));
    expect(lock(), isNot(before));

    expect(await codes(), isEmpty);
  });

  test('rejects a source that is neither cached nor fetchable, and plain http (K4.3, K4.4)', () async {
    expect(await codes(RemoteMode.offline), ['RIALTO-S003']);
    served = null;
    expect(await codes(), ['RIALTO-S003']);
    File(
      contract,
    ).writeAsStringSync(File(contract).readAsStringSync().replaceAll(url, url.replaceFirst('https://', 'http://')));
    expect(await codes(), ['RIALTO-S005']);
  });

  test('synchronous validation reads a locked source from the cache, and reports one it would have to fetch', () async {
    expect(ContractValidator.validate(contract).diagnostics.map((it) => it.code.id), ['RIALTO-S003']);
    await codes();
    expect(ContractValidator.validate(contract).diagnostics, isEmpty);
  });

  test('keeps a contract with only local sources free of a lock file', () {
    File(p.join(support, 'api.json')).copySync(p.join(work.path, 'api.json'));
    final local = p.join(work.path, 'local.rialto.yaml');
    File(local).writeAsStringSync(contractText('api.json'));
    final result = ContractValidator.validate(local);
    expect(result.valid, isTrue, reason: result.diagnostics.join('\n'));
    expect(File(p.join(work.path, RemoteSources.lockFile)).existsSync(), isFalse);
  });

  test('keeps cache file names inside their directory', () {
    expect(RemoteSources.fileName('https://x.example/a/openapi.json?v=2'), 'openapi.json');
    expect(RemoteSources.fileName('https://x.example/a/..'), 'source');
    expect(RemoteSources.fileName('https://x.example/'), 'source');
    expect(RemoteSources.fileName('https://x.example/a%2F..%2Fb'), 'a_2F.._2Fb');
  });
}
