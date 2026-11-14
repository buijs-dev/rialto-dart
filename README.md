# rialto-dart

Rialto tooling for Dart: loading and validating [Rialto contracts](https://github.com/buijs-dev/rialto-spec), and the
`rialto` command line. It follows [rialto-jvm](https://github.com/buijs-dev/rialto-jvm) and reports the same
diagnostic codes, at the same JSON Pointers.

**Status:** slice 0 of the way to 1.0.0, the foundation: the contract format itself. The rules of the profiles follow
one slice per profile; see [Roadmap](#roadmap).

## Packages

| Package | Purpose |
|---|---|
| `rialto_contract` | Loading YAML and JSON with positions; validation against the JSON Schema of contract format 1.0.0; `include` and the bundled form of a contract over several files; local and remote sources (OpenAPI, AsyncAPI, SQL and migrations), with `rialto.lock`; the format checks (names, type expressions and references); the writer; `Code`, the standard diagnostic codes |
| `rialto_cli` | The `rialto` command line |

## Commands

```text
rialto validate [--offline] [--format json] <contract>...
rialto bundle --output <file> <contract>
rialto sources update <contract>
```

- `validate` checks each contract and prints each finding as
  `error[RIALTO-K004] <file>:<line>:<column> #<pointer>: <message> (<requirement>)`. With `--format json` it prints
  one JSON document, in the form of the [standard diagnostic codes](https://github.com/buijs-dev/rialto-spec/blob/develop/spec/contract.md#standard-diagnostic-codes).
- `bundle` writes the bundled form of a contract over several files: one document, without `include`.
- `sources update` fetches every remote (`https`) source again and writes its new hash to `rialto.lock`. `validate`
  pins a new remote source there on first use, and `--offline` reads remote sources only from the cache.

The exit code is 0 on success, 1 when a contract has errors, and 64 on wrong usage.

## Validation

`ContractValidator.validate` reads a contract in this order; the first two steps stop the run at an error:

1. the document, or the root and its fragments (`RIALTO-K001`, `K007`–`K009`, `K005` across fragments);
2. the format version (`RIALTO-K003`) and the JSON Schema (`RIALTO-K002`);
3. the sources (`RIALTO-S001`, `S003`–`S005`);
4. the checks of `ContractValidator.checks`. In slice 0 that is `FormatChecks`: unique names (`RIALTO-K005`), type
   expressions (`RIALTO-K006`), references to contract elements (`RIALTO-K004`) and into sources (`RIALTO-S002`), in
   every section.

The rules of each profile are a `ContractCheck` of their own, which the slice of that profile adds to
`ContractValidator.checks`. `Code` already holds the whole table of the specification, the `P` codes too.

## Building and testing

The tests read the test contracts and the JSON Schema of [rialto-spec](https://github.com/buijs-dev/rialto-spec), from
a checkout next to this one (`../rialto-spec`).

```sh
dart pub get
dart analyze --fatal-infos
(cd packages/rialto_contract && dart test)
(cd packages/rialto_cli && dart test)
dart run rialto_cli:rialto validate ../rialto-spec/examples/contracts/valid/minimal.yaml
```

`dart run` compiles the command line on every start. For many runs, such as the conformance runner, compile it once
with `tool/build_cli.sh`, which writes `build/rialto`:

```sh
cd ../rialto-spec && python3 tools/conformance.py --jobs 8 -- "$(../rialto-dart/tool/build_cli.sh)" validate {contract}
```

CI runs the analysis and tests per package, builds the command line, and runs conformance against rialto-spec, at the
branch with the same name as this one when it exists, otherwise at `develop`.

## Roadmap

| Slice | Adds |
|---|---|
| 0 | The contract format (this) |
| 1 | The domain and mapping checks; `rialto_annotations` and `rialto_export` (a contract from annotated Dart) |
| 2–8 | The checks of REST and errors, persistence, query, lifecycle, auth, events and presentation |
| 9 | `rialto_compat` and `rialto diff` (versions and compatibility) |
| 10 | `rialto_generator`, `rialto generate` and `rialto generators`, generator pins in `rialto.lock`, the registry |

## License

Apache License 2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
