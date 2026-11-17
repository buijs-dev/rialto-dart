/// The `rialto` command line: validate and bundle contracts, and update remote sources.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rialto_contract/rialto_contract.dart';

const usage = '''Usage:
  rialto validate [--offline] [--format json] <contract>...
  rialto bundle --output <file> <contract>
  rialto sources update <contract>
Remote sources (https) are pinned in rialto.lock next to the contract; --offline reads them only from the cache.
--format json (validate): one JSON document on stdout instead of text, as rialto-jvm prints it.
Exit code 0 on success, 1 when a contract has errors, 64 on wrong usage.''';

/// Runs the command line and returns the exit code.
Future<int> runRialto(List<String> args, {StringSink? out, StringSink? err}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final offline = args.contains('--offline');
  final remote = offline ? RemoteMode.offline : RemoteMode.locked;
  final command = args.where((it) => it != '--offline').toList();
  final rest = command.skip(1).toList();
  return switch (command.firstOrNull) {
    'validate' => await _validateCommand(rest, remote, output, errors),
    'bundle' => _bundle(rest, output, errors),
    'sources' => await _sources(rest, output, errors),
    _ => _usage(errors),
  };
}

int _usage(StringSink err) {
  err.writeln(usage);
  return 64;
}

void _print(List<Diagnostic> diagnostics, StringSink out, StringSink err) {
  for (final diagnostic in diagnostics) {
    (diagnostic.severity == Severity.error ? err : out).writeln(diagnostic);
  }
}

/// Fetches every remote source of a contract again and locks its current hash (K4.2).
Future<int> _sources(List<String> args, StringSink out, StringSink err) async {
  if (args.length != 2 || args[0] != 'update') return _usage(err);
  final diagnostics = Diagnostics();
  final changes = await RemoteSources.update(args[1], diagnostics);
  _print(diagnostics.all, out, err);
  changes.forEach(out.writeln);
  if (!diagnostics.hasErrors) out.writeln('${changes.length} remote source(s) updated in ${RemoteSources.lockFile}');
  return diagnostics.hasErrors ? 1 : 0;
}

/// `rialto validate`, as text or, with `--format json`, as one JSON document.
Future<int> _validateCommand(List<String> args, RemoteMode remote, StringSink out, StringSink err) async {
  final index = args.indexOf('--format');
  if (index < 0) return _validate(args, remote, out, err);
  final value = index + 1 < args.length ? args[index + 1] : null;
  if (value != 'json' && value != 'text') return _usage(err);
  final files = [...args.take(index), ...args.skip(index + 2)];
  return value == 'json' ? _validateJson(files, remote, out, err) : _validate(files, remote, out, err);
}

/// One JSON document for all contracts, in the informative form of the specification (contract.md).
Future<int> _validateJson(List<String> files, RemoteMode remote, StringSink out, StringSink err) async {
  if (files.isEmpty) return _usage(err);
  final contracts = <Map<String, Object?>>[];
  var failed = false;
  for (final file in files) {
    if (!File(file).existsSync()) {
      contracts.add({
        'file': file,
        'valid': false,
        'diagnostics': [
          {'severity': 'error', 'code': null, 'message': '$file not found'},
        ],
      });
      failed = true;
      continue;
    }
    final result = await ContractValidator.validateAsync(file, remote: remote);
    if (!result.valid) failed = true;
    contracts.add({
      'file': file,
      'valid': result.valid,
      'diagnostics': [for (final diagnostic in result.diagnostics) _json(diagnostic)],
    });
  }
  out.writeln(const JsonEncoder.withIndent('  ').convert({'contracts': contracts, 'valid': !failed}));
  return failed ? 1 : 0;
}

Map<String, Object?> _json(Diagnostic diagnostic) => {
  'severity': diagnostic.severity == Severity.error ? 'error' : 'warning',
  'code': diagnostic.id,
  'requirement': diagnostic.requirement,
  'file': diagnostic.location.file,
  'line': diagnostic.location.line,
  'column': diagnostic.location.column,
  'pointer': diagnostic.location.pointer,
  'message': diagnostic.message,
  'hint': diagnostic.hint,
};

Future<int> _validate(List<String> files, RemoteMode remote, StringSink out, StringSink err) async {
  if (files.isEmpty) return _usage(err);
  var failed = false;
  for (final file in files) {
    if (!File(file).existsSync()) {
      err.writeln('error: $file not found');
      failed = true;
      continue;
    }
    final result = await ContractValidator.validateAsync(file, remote: remote);
    _print(result.diagnostics, out, err);
    if (result.valid) {
      out.writeln('$file: valid');
    } else {
      failed = true;
    }
  }
  return failed ? 1 : 0;
}

/// Writes the bundled form of a contract over several files (K5).
int _bundle(List<String> args, StringSink out, StringSink err) {
  final index = args.indexOf('--output');
  if (index < 0 || index + 1 >= args.length) return _usage(err);
  final output = args[index + 1];
  final rest = [...args.take(index), ...args.skip(index + 2)];
  if (rest.length != 1) return _usage(err);
  final diagnostics = Diagnostics();
  final written = ContractFiles.bundle(rest.single, output, diagnostics);
  _print(diagnostics.all, out, err);
  if (written) out.writeln('${rest.single}: bundled into $output');
  return written ? 0 : 1;
}
