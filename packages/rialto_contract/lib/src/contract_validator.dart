import 'dart:convert';

import 'package:json_schema/json_schema.dart';

import 'checks.dart';
import 'contract.dart';
import 'contract_files.dart';
import 'diagnostics.dart';
import 'located_document.dart';
import 'remote_sources.dart';
import 'schema.dart';
import 'format_checks.dart';
import 'sources.dart';

/// The outcome of validating one contract: the contract when it is usable, and every finding.
class ValidationResult {
  const ValidationResult(this.contract, this.diagnostics);

  final Contract? contract;
  final List<Diagnostic> diagnostics;

  bool get valid => contract != null && diagnostics.every((it) => it.severity != Severity.error);
}

/// Loads and validates a contract: format version (K1.1), JSON Schema (K1.7), its sources (K1.9, K4), and then
/// [checks] over the whole contract.
class ContractValidator {
  static const supportedVersion = '1.0.0';

  /// The checks that run on a contract that conforms to the JSON Schema, in order: those of the contract format
  /// (names, type expressions and references), then those of each profile, which a profile adds here.
  static const List<ContractCheck> checks = [FormatChecks()];

  static final JsonSchema _schema = JsonSchema.create(
    jsonDecode(contractSchema),
    schemaVersion: SchemaVersion.draft2020_12,
  );

  /// Validates [file]. A remote source (K4) is read from the cache, or from what [fetched] holds; a source
  /// that has to come from the network needs [validateAsync], or [RemoteSources.prefetch] first.
  /// [checks] replaces [ContractValidator.checks], for a tool or test that runs other checks.
  static ValidationResult validate(
    String file, {
    RemoteMode remote = RemoteMode.locked,
    RemoteFetches? fetched,
    List<ContractCheck> checks = ContractValidator.checks,
  }) {
    final diagnostics = Diagnostics();
    // The bundled form of a contract over several files (K5); a single file is read as it is.
    final document = ContractFiles.read(file, diagnostics);
    if (document == null || diagnostics.hasErrors) return ValidationResult(null, diagnostics.all);

    final version = asMap(document.root)['rialto'];
    if (version != supportedVersion) {
      diagnostics.error(
        Code.unsupportedVersion,
        "Contract format '${version ?? ''}' is not supported",
        document.locate('/rialto'),
        hint: 'This tool reads format $supportedVersion',
      );
      return ValidationResult(null, diagnostics.all);
    }

    final results = _schema.validate(document.root, validateFormats: true);
    final errors = [...results.errors]..sort((a, b) => a.instancePath.compareTo(b.instancePath));
    // json_schema reports a missing required property twice: at the object and at the property's pointer. The object
    // is the place, as in every other tool.
    final reported = <String, String>{};
    for (final error in errors) {
      final first = reported[error.message];
      if (first != null && error.instancePath.startsWith('$first/')) continue;
      reported.putIfAbsent(error.message, () => error.instancePath);
      diagnostics.error(Code.schema, error.message, document.locate(error.instancePath));
    }
    if (diagnostics.hasErrors) return ValidationResult(null, diagnostics.all);

    final contract = Contract(asMap(document.root));
    final sources = Sources.load(contract, document, diagnostics, remote: remote, fetched: fetched);
    final context = CheckContext(contract, document, sources, diagnostics);
    for (final check in checks) {
      check.run(context);
    }
    return ValidationResult(contract, diagnostics.all);
  }

  /// Validates [file] like [validate], after fetching the remote sources it needs (K4).
  static Future<ValidationResult> validateAsync(
    String file, {
    RemoteMode remote = RemoteMode.locked,
    List<ContractCheck> checks = ContractValidator.checks,
  }) async => validate(
    file,
    remote: remote,
    fetched: await RemoteSources.prefetch([file], remote: remote),
    checks: checks,
  );
}
