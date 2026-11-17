import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'diagnostics.dart';
import 'located_document.dart';

/// How remote sources are read (K4).
enum RemoteMode {
  /// Locked sources from the cache or fetched and checked; new sources fetched and locked.
  locked,

  /// Only the cache; a source that is not cached, or not locked, is rejected.
  offline,

  /// Every remote source fetched again and locked with its current hash.
  update,
}

/// A remote source whose locked hash an update changed.
class SourceChange {
  const SourceChange(this.url, this.before, this.after);

  final String url;
  final String? before;
  final String after;

  @override
  bool operator ==(Object other) =>
      other is SourceChange && other.url == url && other.before == before && other.after == after;

  @override
  int get hashCode => Object.hash(url, before, after);

  @override
  String toString() => '$url: ${before ?? 'new'} -> $after';
}

/// The remote sources fetched before a run, by URL: the hash of what was stored in the cache, or why the fetch failed.
///
/// Dart cannot wait for the network synchronously, so the asynchronous [RemoteSources.prefetch] fetches what a
/// run needs and the synchronous validation reads it from here and from the cache.
class RemoteFetches {
  RemoteFetches();

  final hashes = <String, String>{};
  final failures = <String, String>{};
}

/// Remote sources (K4): documents at an `https` URL, pinned by SHA-256 in `rialto.lock` next to the
/// contract and kept in a content-addressed cache, `~/.cache/rialto/sha256/<hash>/<file name>`
/// ([cacheDirectory] or the environment variable `RIALTO_CACHE` move it).
class RemoteSources {
  static const lockFile = 'rialto.lock';

  /// Fetches the body of a URL; throws on a failure or a status other than 200. Replaceable in tests.
  static Future<List<int>> Function(Uri url) fetch = _httpFetch;

  /// Fetches the body of a URL as [fetch] does, but fails as soon as it is longer than [maxBytes] (also by its
  /// Content-Length). Replaceable in tests.
  static Future<List<int>> Function(Uri url, int maxBytes) fetchBounded = _httpFetchBounded;

  /// Moves the cache, before `RIALTO_CACHE`; the counterpart of the JVM system property `rialto.cache`.
  static String? cacheDirectory;

  static bool isRemote(String path) => path.contains('://');

  static String cacheDir() {
    final configured = cacheDirectory ?? Platform.environment['RIALTO_CACHE'];
    if (configured != null) return configured;
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return p.join(home, '.cache', 'rialto');
  }

  /// Fetches the remote sources of [contractFiles] that a run in [remote] mode needs from the network,
  /// stores them in the cache and returns the outcome for [ContractValidator.validate]. Nothing is
  /// reported here: the validation reports a contract or lock that cannot be read, and every failure.
  static Future<RemoteFetches> prefetch(List<String> contractFiles, {RemoteMode remote = RemoteMode.locked}) async {
    final fetched = RemoteFetches();
    if (remote == RemoteMode.offline) return fetched;
    for (final contractFile in contractFiles) {
      // An unreadable lock pins nothing, so nothing is fetched for it (K4.5); the run reports it.
      final locked = _readLock(contractFile);
      if (locked == null) continue;
      for (final (url, _) in _remotePaths(contractFile)) {
        if (!url.startsWith('https://') || fetched.hashes.containsKey(url) || fetched.failures.containsKey(url)) {
          continue;
        }
        final pinned = locked[url];
        if (remote != RemoteMode.update && pinned != null && _cached(pinned, fileName(url)) != null) continue;
        try {
          final body = await fetch(Uri.parse(url));
          final hash = sha256(body);
          // A body that differs from its lock is rejected by the run and kept out of the cache (K4.2).
          if (remote == RemoteMode.update || pinned == null || hash == pinned) _store(hash, fileName(url), body);
          fetched.hashes[url] = hash;
        } catch (e) {
          fetched.failures[url] = errorText(e);
        }
      }
    }
    return fetched;
  }

  /// Fetches every remote source of [contractFile] and locks its current hash; returns what changed.
  static Future<List<SourceChange>> update(String contractFile, Diagnostics diagnostics) async {
    final LocatedDocument document;
    try {
      document = LocatedDocument.readMapping(contractFile);
    } catch (e) {
      diagnostics.error(Code.unreadable, errorText(e), Location(contractFile));
      return const [];
    }
    final fetched = await prefetch([contractFile], remote: RemoteMode.update);
    final session = RemoteSession(contractFile, RemoteMode.update, diagnostics, fetched);
    for (final (url, pointer) in _remotePaths(contractFile, document)) {
      session.resolve(url, document.locate(pointer));
    }
    return session.finish();
  }

  /// The remote source paths of a contract, with the JSON Pointer of each; none when it cannot be read.
  static List<(String, String)> _remotePaths(String contractFile, [LocatedDocument? read]) {
    final LocatedDocument document;
    try {
      document = read ?? LocatedDocument.readMapping(contractFile);
    } catch (_) {
      return const [];
    }
    final sources = (document.root as Map)['sources'];
    if (sources is! Map) return const [];
    return [
      for (final MapEntry(:key, :value) in sources.entries)
        if (value is Map && value['path'] is String && isRemote(value['path'] as String))
          (value['path'] as String, '/sources/${LocatedDocument.segment('$key')}/path'),
    ];
  }

  /// The file name the cache keeps a document under: the last path segment, made safe for any file system.
  static String fileName(String url) {
    var segment = url;
    final hash = segment.indexOf('#');
    if (hash >= 0) segment = segment.substring(0, hash);
    final query = segment.indexOf('?');
    if (query >= 0) segment = segment.substring(0, query);
    segment = segment.substring(segment.lastIndexOf('/') + 1).replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    return segment.isEmpty || RegExp(r'^\.+$').hasMatch(segment) ? 'source' : segment;
  }

  /// The SHA-256 of [bytes] in lowercase hexadecimal.
  static String sha256(List<int> bytes) => crypto.sha256.convert(bytes).toString();

  static String? _cached(String hash, String name) {
    final file = File(p.join(cacheDir(), 'sha256', hash, name));
    return file.existsSync() && sha256(file.readAsBytesSync()) == hash ? file.path : null;
  }

  static String _store(String hash, String name, List<int> body) {
    final directory = Directory(p.join(cacheDir(), 'sha256', hash))..createSync(recursive: true);
    final file = p.join(directory.path, name);
    File(p.join(directory.path, '$name.${DateTime.now().microsecondsSinceEpoch}.$pid.part'))
      ..writeAsBytesSync(body, flush: true)
      ..renameSync(file);
    return file;
  }

  /// The locked hashes next to [contractFile], or null when the lock exists but cannot be read; [failure] receives
  /// the reason.
  static Map<String, String>? _readLock(String contractFile, [void Function(String reason)? failure]) {
    try {
      return RialtoLock.readSources(lockPath(contractFile));
    } on FormatException catch (e) {
      failure?.call(e.message);
    } on FileSystemException catch (e) {
      failure?.call(e.osError?.message ?? e.message);
    }
    return null;
  }

  /// The path of the lock of [contractFile]: `rialto.lock` in its directory.
  static String lockPath(String contractFile) => p.join(p.dirname(p.absolute(contractFile)), lockFile);

  static Future<List<int>> _httpFetch(Uri url) => _httpFetchBounded(url, null);

  static Future<List<int>> _httpFetchBounded(Uri url, int? maxBytes) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      var current = url;
      // Redirects are followed by hand, and never from https to http (K4.4).
      for (var redirects = 0; redirects <= 5; redirects++) {
        final request = await client.getUrl(current).timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        final response = await request.close().timeout(const Duration(seconds: 30));
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) throw HttpException('HTTP ${response.statusCode} without a location', uri: current);
          current = current.resolve(location);
          if (current.scheme != 'https') throw HttpException('redirect to $current does not use https', uri: url);
          continue;
        }
        if (maxBytes != null && response.contentLength > maxBytes) {
          await response.drain<void>().catchError((_) {});
          throw HttpException('larger than $maxBytes bytes (Content-Length ${response.contentLength})', uri: current);
        }
        final body = await response
            .fold<List<int>>(<int>[], (all, chunk) {
              all.addAll(chunk);
              if (maxBytes != null && all.length > maxBytes) {
                throw HttpException('larger than $maxBytes bytes', uri: current);
              }
              return all;
            })
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}', uri: current);
        return body;
      }
      throw HttpException('too many redirects', uri: url);
    } finally {
      client.close(force: true);
    }
  }
}

/// One run over the remote sources of a contract: reads `rialto.lock`, writes it in [finish].
class RemoteSession {
  RemoteSession(String contractFile, this.mode, this.diagnostics, [RemoteFetches? fetched])
    : _contractFile = contractFile,
      _fetched = fetched ?? RemoteFetches() {
    final locked = RemoteSources._readLock(contractFile, (reason) => _lockFailure = reason);
    _locked = locked ?? const {};
  }

  final RemoteMode mode;
  final Diagnostics diagnostics;
  final String _contractFile;
  final RemoteFetches _fetched;
  late final Map<String, String> _locked;
  final _hashes = <String, String>{};

  /// Why the lock cannot be read, or null when it was read or does not exist.
  String? _lockFailure;

  /// The remote sources that could not be read because the lock cannot be read.
  final _unpinned = <String>[];

  String get _lockPath => RemoteSources.lockPath(_contractFile);

  /// The cached copy of [url], fetched before the run when needed, or null (reported at [location]).
  String? resolve(String url, Location location) {
    if (!url.startsWith('https://')) {
      diagnostics.error(Code.remoteScheme, 'Remote source $url does not use https', location);
      return null;
    }
    // An unreadable lock is no empty lock: nothing it would pin is read (K4.5); [finish] reports it.
    if (_lockFailure != null) {
      if (!_unpinned.contains(url)) _unpinned.add(url);
      return null;
    }
    final pinned = _locked[url];
    final name = RemoteSources.fileName(url);
    if (mode != RemoteMode.update && pinned != null) {
      final cached = RemoteSources._cached(pinned, name);
      if (cached != null) {
        _hashes[url] = pinned;
        return cached;
      }
    }
    if (mode == RemoteMode.offline) {
      diagnostics.error(
        Code.remoteUnavailable,
        pinned == null
            ? '$url is not in ${RemoteSources.lockFile} and cannot be fetched offline'
            : '$url is not cached',
        location,
        hint: 'Build once without offline mode',
      );
      return null;
    }
    final hash = _fetched.hashes[url];
    if (hash != null && mode != RemoteMode.update && pinned != null && hash != pinned) {
      diagnostics.error(
        Code.remoteChanged,
        '$url changed since it was locked in ${RemoteSources.lockFile}',
        location,
        hint: 'Run `rialto sources update` to accept the new version',
      );
      return null;
    }
    final file = hash == null ? null : RemoteSources._cached(hash, name);
    if (hash == null || file == null) {
      final reason = _fetched.failures[url] ?? 'not fetched before the run (RemoteSources.prefetch)';
      diagnostics.error(Code.remoteUnavailable, 'Cannot fetch $url: $reason', location);
      return null;
    }
    _hashes[url] = hash;
    return file;
  }

  /// Writes `rialto.lock` when a source was added or updated; returns the changed hashes. Reports a lock that cannot
  /// be read or written (RIALTO-K010).
  List<SourceChange> finish() {
    final failure = _lockFailure;
    if (failure != null) {
      _lockError('Cannot read the lock', failure, _unpinned);
      return const [];
    }
    if (diagnostics.hasErrors) return const [];
    final changes = [
      for (final MapEntry(key: url, value: hash) in _hashes.entries)
        if (_locked[url] != hash) SourceChange(url, _locked[url], hash),
    ];
    // Entries of sources the contract no longer uses are dropped with any other change.
    final next = mode == RemoteMode.update
        ? _hashes
        : {
            for (final entry in _locked.entries)
              if (_hashes.containsKey(entry.key)) entry.key: entry.value,
            ..._hashes,
          };
    final same = next.length == _locked.length && next.entries.every((entry) => _locked[entry.key] == entry.value);
    if (!same && mode != RemoteMode.offline) {
      try {
        _writeLock(next);
      } on FileSystemException catch (e) {
        _lockError('Cannot write the lock', e.osError?.message ?? e.message, [
          for (final change in changes) change.url,
        ]);
        return const [];
      }
    }
    return changes;
  }

  /// RIALTO-K010 on the contract: the lock, why, and the remote sources it does not pin.
  void _lockError(String what, String reason, List<String> unpinned) {
    final sources = unpinned.isEmpty ? '' : '. Not pinned: ${unpinned.join(', ')}';
    diagnostics.error(
      Code.lockUnusable,
      '$what $_lockPath: $reason$sources',
      Location(_contractFile),
      hint: 'Repair or remove ${RemoteSources.lockFile}, then run `rialto sources update`',
    );
  }

  /// Writes the sources section under the lock rialto-jvm takes too ([RialtoLock.exclusive]); the file is replaced
  /// atomically.
  void _writeLock(Map<String, String> hashes) {
    final path = _lockPath;
    RialtoLock.exclusive(path, () => RialtoLock.write(path, RialtoLock.text(hashes)));
  }
}

/// `rialto.lock` as rialto-jvm reads and writes it (its `RialtoLock`): the same text, the same lock.
abstract final class RialtoLock {
  /// The `sources` section of the lock at [path], hash by URL; empty without one. Throws a [FormatException] when it
  /// cannot be read.
  static Map<String, String> readSources(String path) {
    final root = _root(path);
    if (root == null) return const {};
    final sources = root['sources'];
    if (sources == null) return const {};
    if (sources is! Map) throw const FormatException('sources is not a mapping');
    final hashes = <String, String>{};
    for (final MapEntry(:key, :value) in sources.entries) {
      if (key is! String || value is! String) throw FormatException('$key is not a URL with a hash');
      hashes[key] = value;
    }
    return hashes;
  }

  static Map<Object?, Object?>? _root(String path) {
    switch (FileSystemEntity.typeSync(path)) {
      case FileSystemEntityType.notFound:
        return null;
      case FileSystemEntityType.directory:
        throw const FormatException('it is a directory');
      default:
        break;
    }
    final Object? root;
    try {
      root = loadYaml(File(path).readAsStringSync());
    } on YamlException catch (e) {
      throw FormatException('not valid YAML: ${e.message}');
    }
    if (root == null) return null;
    if (root is! Map) throw const FormatException('not a mapping');
    return root;
  }

  /// The text of a lock with [sources], as rialto-jvm writes it.
  static String text(Map<String, String> sources) {
    final text = StringBuffer()
      ..writeln('# Written by Rialto: the SHA-256 of every remote source of the contract (K4). Commit this file;')
      ..writeln('# `rialto sources update` accepts new versions.')
      ..writeln(sources.isEmpty ? 'sources: {}' : 'sources:');
    for (final url in sources.keys.toList()..sort()) {
      text.writeln('  "$url": "${sources[url]}"');
    }
    return text.toString();
  }

  /// Writes [text] to [path] atomically: to a temporary file next to it, then renamed over it.
  static void write(String path, String text) {
    final temporary = File(
      p.join(p.dirname(path), '.${p.basename(path)}.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp'),
    );
    try {
      temporary.writeAsStringSync(text, flush: true);
      temporary.renameSync(path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  /// Runs [action] holding the lock of the file at [path]: an exclusive lock on
  /// `<cache>/locks/<sha256 of its real path>.lck`, the same file rialto-jvm locks. Without a writable cache,
  /// the atomic rename is the only protection.
  static T exclusive<T>(String path, T Function() action) {
    final absolute = p.absolute(path);
    final directory = Directory(p.dirname(absolute));
    final real = p.join(
      directory.existsSync() ? directory.resolveSymbolicLinksSync() : directory.path,
      p.basename(absolute),
    );
    RandomAccessFile? handle;
    try {
      final locks = Directory(p.join(RemoteSources.cacheDir(), 'locks'))..createSync(recursive: true);
      handle = File(
        p.join(locks.path, '${RemoteSources.sha256(utf8.encode(real))}.lck'),
      ).openSync(mode: FileMode.append);
      handle.lockSync(FileLock.blockingExclusive);
    } on FileSystemException {
      handle?.closeSync();
      handle = null;
    }
    try {
      return action();
    } finally {
      handle?.unlockSync();
      handle?.closeSync();
    }
  }
}
