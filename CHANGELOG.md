# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Towards 1.0.0, built in slices. This section holds slice 0, the foundation: the contract format.

### Added

- The workspace: `rialto_contract` and `rialto_cli`, the recommended lints with `--fatal-infos`, and
  `tool/build_cli.sh`, which compiles the command line to `build/rialto`.
- `rialto_contract`:
  - loading YAML and JSON with line and column per JSON Pointer (`LocatedDocument`);
  - validation against the JSON Schema of contract format 1.0.0, a copy of `spec/contract-1.0.0.schema.json` of
    rialto-spec (`$id` `https://rialto.buijs.dev/spec/contract-1.0.0.schema.json`); a test checks that the copy is
    identical;
  - a contract over several files: `include` with `*` and `**`, fragments, and the bundled form (`ContractFiles`);
  - sources: OpenAPI, AsyncAPI and SQL, also as migrations in version order; remote `https` sources with a cache and
    their hashes in the `sources` section of `rialto.lock`;
  - `FormatChecks`: unique names, type expressions, and references to contract elements and into sources, in every
    section;
  - `ContractCheck` and `ContractValidator.checks`, where each profile adds its checks;
  - `Code`, the standard diagnostic codes of the specification (`K`, `S` and `P`), each with its requirement; a test
    checks the table against `spec/contract.md`;
  - the writer (`ContractWriter`).
- `rialto_cli`: `rialto validate` (with `--offline` and `--format json`), `rialto bundle` and
  `rialto sources update`.
- CI: analysis and tests per package, the compiled command line, and conformance against the test contracts of
  rialto-spec.
