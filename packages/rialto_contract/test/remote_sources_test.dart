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

  test('reports a lock it cannot read (RIALTO-K010)', () async {
    File(p.join(work.path, RemoteSources.lockFile)).writeAsStringSync('sources: [oops]\n');
    expect(await codes(), ['RIALTO-K010']);
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

  group('a lock that cannot be used (RIALTO-K010, K4.5)', () {
    String lockPath() => p.join(work.path, RemoteSources.lockFile);

    test(
      'a lock that is no lock is an error on the contract, naming the lock and the sources it does not pin',
      () async {
        for (final (text, reason) in [
          ('sources: [oops\n', 'not valid YAML: '),
          ('- a\n', 'not a mapping'),
          ('sources: [a]\n', 'sources is not a mapping'),
          ('sources: {"$url": 42}\n', '$url is not a URL with a hash'),
        ]) {
          File(lockPath()).writeAsStringSync(text);
          final diagnostic = (await ContractValidator.validateAsync(contract)).diagnostics.single;
          expect(diagnostic.code, Code.lockUnusable, reason: text);
          expect(diagnostic.requirement, 'K4.5');
          expect(diagnostic.message, startsWith('Cannot read the lock ${lockPath()}: $reason'), reason: text);
          expect(diagnostic.message, endsWith('. Not pinned: $url'), reason: text);
          expect(diagnostic.location.file, contract);
          expect(diagnostic.hint, 'Repair or remove rialto.lock, then run `rialto sources update`');
          expect(File(lockPath()).readAsStringSync(), text, reason: 'the lock is left as it is');
        }
      },
    );

    test('a directory named rialto.lock is no lock, not an empty one, and nothing is fetched for it', () async {
      Directory(lockPath()).createSync();
      RemoteSources.fetch = (_) async => throw StateError('must not fetch');
      final diagnostic = (await ContractValidator.validateAsync(contract)).diagnostics.single;
      expect(diagnostic.code, Code.lockUnusable);
      expect(diagnostic.message, 'Cannot read the lock ${lockPath()}: it is a directory. Not pinned: $url');
      expect(Directory(lockPath()).existsSync(), isTrue);

      final diagnostics = Diagnostics();
      expect(await RemoteSources.update(contract, diagnostics), isEmpty);
      expect(diagnostics.all.single.code, Code.lockUnusable);
    });

    test('a lock without read permission', () async {
      final lock = File(lockPath())..writeAsStringSync('sources: {}\n');
      Process.runSync('chmod', ['000', lock.path]);
      addTearDown(() => Process.runSync('chmod', ['644', lock.path]));
      final diagnostic = (await ContractValidator.validateAsync(contract)).diagnostics.single;
      expect(diagnostic.code, Code.lockUnusable);
      expect(diagnostic.message, startsWith('Cannot read the lock ${lockPath()}: '));
    }, testOn: '!windows');

    test('an unreadable lock is reported for a contract without remote sources too, without sources', () async {
      File(p.join(support, 'api.json')).copySync(p.join(work.path, 'api.json'));
      File(contract).writeAsStringSync(contractText('api.json'));
      Directory(lockPath()).createSync();
      final diagnostic = (await ContractValidator.validateAsync(contract)).diagnostics.single;
      expect(diagnostic.message, 'Cannot read the lock ${lockPath()}: it is a directory');
    });

    test('a lock that cannot be written is an error naming the sources it could not pin; nothing crashes', () async {
      Process.runSync('chmod', ['555', work.path]);
      addTearDown(() => Process.runSync('chmod', ['755', work.path]));
      final result = await ContractValidator.validateAsync(contract);
      final diagnostic = result.diagnostics.single;
      expect(diagnostic.code, Code.lockUnusable);
      expect(diagnostic.message, startsWith('Cannot write the lock ${lockPath()}: '));
      expect(diagnostic.message, endsWith('. Not pinned: $url'));
      expect(diagnostic.location.file, contract);
      expect(result.valid, isFalse);
      expect(File(lockPath()).existsSync(), isFalse);

      final diagnostics = Diagnostics();
      expect(await RemoteSources.update(contract, diagnostics), isEmpty);
      expect(diagnostics.all.single.message, startsWith('Cannot write the lock'));
    }, testOn: '!windows');

    test('the other findings are still reported', () async {
      Directory(lockPath()).createSync();
      File(contract).writeAsStringSync(
        '${contractText(url)}  - {source: api#/components/schemas/Nope, target: Ghost, direction: toTarget}\n'
        'storage:\n  Thing: {table: db#thing}\n',
      );
      expect(await codes(), ['RIALTO-K010', 'RIALTO-K004', 'RIALTO-K004']);
    });

    test('an empty lock, one with only comments or without sources, is a lock without entries', () async {
      for (final text in ['', '# nothing yet\n', 'other: 1\n', 'sources:\n']) {
        File(lockPath()).writeAsStringSync(text);
        expect(await codes(), isEmpty, reason: text);
      }
    });
  });

  test('offline, a locked source that is not cached is RIALTO-S003 with its own message', () async {
    await codes();
    cache.deleteSync(recursive: true);
    final diagnostic = (await ContractValidator.validateAsync(contract, remote: RemoteMode.offline)).diagnostics.single;
    expect(diagnostic.code, Code.remoteUnavailable);
    expect(diagnostic.message, '$url is not cached');
    expect(diagnostic.hint, isNotNull);
  });

  test('a fetch that fails is reported with its reason', () async {
    served = null;
    final diagnostic = (await ContractValidator.validateAsync(contract)).diagnostics.single;
    expect(diagnostic.code, Code.remoteUnavailable);
    expect(diagnostic.message, contains('offline'));
    expect(diagnostic.location.pointer, '/sources/api/path');
  });

  test('a cached copy that no longer matches its hash is fetched again', () async {
    await codes();
    final copy = File(p.join(cache.path, 'sha256', RemoteSources.sha256(served!), 'api.json'));
    copy.writeAsStringSync('tampered');
    var fetches = 0;
    final fetch = RemoteSources.fetch;
    RemoteSources.fetch = (uri) {
      fetches++;
      return fetch(uri);
    };
    expect(await codes(), isEmpty);
    expect(fetches, 1);
    expect(copy.readAsBytesSync(), served);
  });

  test('fetches a source that several contracts share once', () async {
    final second = p.join(work.path, 'second', 'remote.rialto.yaml');
    File(second)
      ..parent.createSync()
      ..writeAsStringSync(contractText(url));
    var fetches = 0;
    final fetch = RemoteSources.fetch;
    RemoteSources.fetch = (uri) {
      fetches++;
      return fetch(uri);
    };
    final fetched = await RemoteSources.prefetch([contract, second, p.join(work.path, 'missing.yaml')]);
    expect(fetches, 1);
    expect(fetched.hashes, {url: RemoteSources.sha256(served!)});
    expect(fetched.failures, isEmpty);
    expect((await RemoteSources.prefetch([contract], remote: RemoteMode.offline)).hashes, isEmpty);
  });

  test('leaves an unchanged lock as it is, and drops the entry of a source the contract no longer uses', () async {
    await codes();
    final path = p.join(work.path, RemoteSources.lockFile);
    File(path).writeAsStringSync('# kept\n${lock()}');
    expect(await codes(), isEmpty);
    expect(lock(), startsWith('# kept\n'));

    File(p.join(support, 'api.json')).copySync(p.join(work.path, 'api.json'));
    File(contract).writeAsStringSync(contractText('api.json'));
    expect(await codes(), isEmpty);
    expect(lock(), endsWith('sources: {}\n'));
    expect(RialtoLock.text(const {}), endsWith('sources: {}\n'));
  });

  test('an update locks a new source, drops unused entries and reports what changed', () async {
    File(
      p.join(work.path, RemoteSources.lockFile),
    ).writeAsStringSync(RialtoLock.text({'https://old.example/api.json': 'abc'}));
    final diagnostics = Diagnostics();
    final changes = await RemoteSources.update(contract, diagnostics);
    expect(diagnostics.all, isEmpty);
    final hash = RemoteSources.sha256(served!);
    expect(changes, [SourceChange(url, null, hash)]);
    expect(changes.single.toString(), '$url: new -> $hash');
    expect(changes.single.hashCode, SourceChange(url, null, hash).hashCode);
    expect(changes.single, isNot(SourceChange(url, 'other', hash)));
    expect(lock(), isNot(contains('old.example')));

    expect(await RemoteSources.update(contract, diagnostics), isEmpty, reason: 'nothing changed');
  });

  test('an update reports a contract it cannot read, a source it cannot fetch and plain http', () async {
    final diagnostics = Diagnostics();
    expect(await RemoteSources.update(p.join(work.path, 'missing.yaml'), diagnostics), isEmpty);
    expect(diagnostics.all.single.code, Code.unreadable);

    served = null;
    final failed = Diagnostics();
    expect(await RemoteSources.update(contract, failed), isEmpty);
    expect(failed.all.single.code, Code.remoteUnavailable);
    expect(File(p.join(work.path, RemoteSources.lockFile)).existsSync(), isFalse);

    File(contract).writeAsStringSync(contractText(url.replaceFirst('https://', 'http://')));
    final plain = Diagnostics();
    await RemoteSources.update(contract, plain);
    expect(plain.all.single.code, Code.remoteScheme);
  });

  test('writes the lock without a usable cache directory, and replaces it atomically', () {
    final blocked = File(p.join(work.path, 'not-a-directory'))..writeAsStringSync('');
    RemoteSources.cacheDirectory = blocked.path;
    final path = p.join(work.path, RemoteSources.lockFile);
    expect(RialtoLock.exclusive(path, () => 42), 42);
    RialtoLock.write(path, RialtoLock.text({url: 'abc'}));
    expect(RialtoLock.readSources(path), {url: 'abc'});
    expect(work.listSync().map((it) => p.basename(it.path)).where((it) => it.endsWith('.tmp')), isEmpty);
    expect(RialtoLock.readSources(p.join(work.path, 'none.lock')), isEmpty);
  });

  test('the cache is in the configured directory, else under the home directory', () {
    expect(RemoteSources.cacheDir(), cache.path);
    RemoteSources.cacheDirectory = null;
    final configured = Platform.environment['RIALTO_CACHE'];
    expect(RemoteSources.cacheDir(), configured ?? endsWith(p.join('.cache', 'rialto')));
  });

  test('a remote path is one with a scheme', () {
    expect(RemoteSources.isRemote('https://x.example/a.json'), isTrue);
    expect(RemoteSources.isRemote('file:///a.json'), isTrue);
    expect(RemoteSources.isRemote('../a.json'), isFalse);
  });

  test('keeps cache file names inside their directory', () {
    expect(RemoteSources.fileName('https://x.example/a/openapi.json?v=2'), 'openapi.json');
    expect(RemoteSources.fileName('https://x.example/a/..'), 'source');
    expect(RemoteSources.fileName('https://x.example/'), 'source');
    expect(RemoteSources.fileName('https://x.example/a%2F..%2Fb'), 'a_2F.._2Fb');
    expect(RemoteSources.fileName('https://x.example/api.yaml#/components'), 'api.yaml');
  });
}
