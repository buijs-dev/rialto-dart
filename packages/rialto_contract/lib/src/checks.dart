import 'contract.dart';
import 'diagnostics.dart';
import 'located_document.dart';
import 'sources.dart';

/// What a check reads and where it reports: a contract that conforms to the JSON Schema, the document it was read
/// from (for positions), its loaded sources and the findings of the run.
class CheckContext {
  const CheckContext(this.contract, this.document, this.sources, this.diagnostics);

  final Contract contract;
  final LocatedDocument document;
  final Sources sources;
  final Diagnostics diagnostics;

  /// The JSON Pointer of [segments], each escaped (RFC 6901).
  static String pointer(List<Object> segments) =>
      segments.map((it) => '/${LocatedDocument.segment(it.toString())}').join();

  void error(Code code, String message, String pointer, {String? hint, String? requirement}) =>
      diagnostics.error(code, message, document.locate(pointer), hint: hint, requirement: requirement);
}

/// One set of checks that needs the whole contract, after loading and the JSON Schema. The checks of the contract
/// format itself are [FormatChecks]; each profile adds its own checks to [ContractValidator.checks].
abstract class ContractCheck {
  const ContractCheck();

  void run(CheckContext context);
}
