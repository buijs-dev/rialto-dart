import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

final spec = p.normalize(p.join(Directory.current.path, '../../../rialto-spec'));

/// Sources of every kind, and types that are valid on their own: each test adds the sections it checks.
const base = '''rialto: "1.0.0"
info: {name: x, version: 1.0.0}
sources:
  api: {kind: openapi, path: api.json, version: 2.0.0, status: current}
  bus: {kind: asyncapi, path: events.yaml, version: 1.0.0, status: current}
  db: {kind: sql, path: schema.sql, dialect: postgresql}
types:
  Status: {kind: enum, members: [open, closed]}
  Thing:
    kind: entity
    identity: [id]
    properties:
      id: {type: uuid}
      status: {type: Status}
      parts: {type: "list<Part>"}
      tags: {type: "set<Tag>"}
      photo: {type: binary}
  Part: {kind: entity, identity: [id], properties: {id: {type: uuid}}}
  Tag: {kind: entity, identity: [id], properties: {id: {type: uuid}, label: {type: string}, things: {type: "list<Thing>"}}}
''';

const asyncApi = '''asyncapi: 3.0.0
info: {title: Events, version: 1.0.0}
channels:
  things: {address: things}
''';

const sql =
    '''CREATE TABLE thing (id uuid PRIMARY KEY, status text NOT NULL, version int NOT NULL, deleted boolean NOT NULL,
  deleted_by text, storage_key text, photo_key text, photo_type text, photo_size int);
CREATE TABLE part (id uuid PRIMARY KEY, thing_id uuid NOT NULL, position int NOT NULL);
CREATE TABLE tag (id uuid PRIMARY KEY, label text, thing_id uuid);
CREATE TABLE thing_tag (thing_id uuid NOT NULL, tag_id uuid NOT NULL, position int);
''';

void main() {
  late Directory work;

  setUp(() {
    work = Directory.systemTemp.createTempSync('rialto-format');
    File(p.join(spec, 'examples/contracts/support/api.json')).copySync(p.join(work.path, 'api.json'));
    File(p.join(work.path, 'events.yaml')).writeAsStringSync(asyncApi);
    File(p.join(work.path, 'schema.sql')).writeAsStringSync(sql);
  });
  tearDown(() => work.deleteSync(recursive: true));

  /// The code and pointer of every finding on [base] with [sections] added.
  List<(String, String)> findings(String sections) {
    final file = p.join(work.path, 'contract.rialto.yaml');
    File(file).writeAsStringSync('$base$sections');
    return [for (final it in ContractValidator.validate(file).diagnostics) (it.code.id, it.location.pointer)];
  }

  test('the base contract is valid', () {
    expect(findings(''), isEmpty);
  });

  test('names: a type and a shape with one name (RIALTO-K005)', () {
    expect(findings('shapes:\n  Thing: {source: Thing, properties: {id: {role: caller}}}\n'), [
      ('RIALTO-K005', '/shapes/Thing'),
    ]);
  });

  group('types', () {
    test('property types are valid expressions over declared types (RIALTO-K004, RIALTO-K006)', () {
      expect(
        findings('''  Bad:
    kind: value
    properties:
      a: {type: "decimal(2,3)"}
      b: {type: "list<Unknown>"}
      c: {type: "map<Status, Missing>"}
      d: {type: "map<Part, string>"}
      e: {type: "map<Nowhere, string>"}
'''),
        [
          ('RIALTO-K006', '/types/Bad/properties/a/type'),
          ('RIALTO-K004', '/types/Bad/properties/b/type'),
          ('RIALTO-K004', '/types/Bad/properties/c/type'),
          ('RIALTO-K006', '/types/Bad/properties/d/type'),
          ('RIALTO-K004', '/types/Bad/properties/e/type'),
        ],
      );
    });

    test('union variants are declared types', () {
      expect(findings('  Either: {kind: union, discriminator: kind, variants: {a: Part, b: Nowhere}}\n'), [
        ('RIALTO-K004', '/types/Either/variants/b'),
      ]);
    });

    test('projection paths resolve against the source, in the list form by index and the map form by name', () {
      expect(
        findings('''  Summary: {kind: projection, source: Thing, properties: [id, nope]}
  Mapped: {kind: projection, source: Thing, properties: {first: id, second: parts.missing, third: status.deeper}}
  Deep: {kind: projection, source: Thing, properties: {partId: parts.id}}
  Orphan: {kind: projection, source: Ghost, properties: [id]}
'''),
        [
          ('RIALTO-K004', '/types/Summary/properties/1'),
          ('RIALTO-K004', '/types/Mapped/properties/second'),
          ('RIALTO-K004', '/types/Mapped/properties/third'),
          ('RIALTO-K004', '/types/Orphan/source'),
        ],
      );
    });

    test('the events a transition rule emits are declared', () {
      expect(
        findings('''  Ticket:
    kind: entity
    identity: [id]
    properties: {id: {type: uuid}, status: {type: Status}}
    transitions:
      property: status
      rules:
        close: {from: [open], to: closed, emits: [Gone]}
'''),
        [('RIALTO-K004', '/types/Ticket/transitions/rules/close/emits/0')],
      );
    });
  });

  test('shapes: the source is a type, its properties are properties of the source, a nested shape is a shape', () {
    expect(
      findings('''shapes:
  ThingInput: {source: Thing, properties: {id: {role: caller}, parts: {role: caller, as: command, shape: Nope}}}
  Orphan: {source: Missing, properties: {id: {role: caller}}}
  ByName: {source: Thing, properties: {name: {role: caller}}}
'''),
      [
        ('RIALTO-K004', '/shapes/ThingInput/properties/parts/shape'),
        ('RIALTO-K004', '/shapes/Orphan/source'),
        ('RIALTO-K004', '/shapes/ByName/properties/name'),
      ],
    );
  });

  test('operations: rest, input, output, subject, successor, emits and the count operation', () {
    expect(
      findings('''operations:
  getThing:
    rest: api#/paths/~1things~1{thingId}/get
    input: Nope
    output: "list<Missing>"
    subject: {type: Ghost, by: actor}
    deprecated: {since: "2026-01-01", successor: oldThing}
    emits: [Gone]
  listThings:
    rest: {api: "api#/paths/~1nowhere/get"}
    output: Thing
    subject: Ghost
    list:
      fields: {id: {sort: true}}
      pagination: {strategy: cursor, limit: {default: 10, max: 50}}
      count: {strategy: operation, operation: countNope, response: /count}
  other:
    rest: other#/paths
'''),
      [
        ('RIALTO-K004', '/operations/getThing/input'),
        ('RIALTO-K004', '/operations/getThing/output'),
        ('RIALTO-K004', '/operations/getThing/subject/type'),
        ('RIALTO-K004', '/operations/getThing/deprecated/successor'),
        ('RIALTO-K004', '/operations/getThing/emits/0'),
        ('RIALTO-S002', '/operations/listThings/rest'),
        ('RIALTO-K004', '/operations/listThings/subject'),
        ('RIALTO-K004', '/operations/listThings/list/count/operation'),
        ('RIALTO-K004', '/operations/other/rest'),
      ],
    );
  });

  test('events, streams and subscriptions: data, events and channels', () {
    expect(
      findings('''events:
  ThingClosed: {type: x.closed, source: /things, subject: id, data: Thing, channel: bus#/channels/things, mode: binary}
  Lost: {type: x.lost, source: /things, subject: id, data: Nothing, channel: bus#/channels/nowhere, mode: structured}
streams:
  live: {events: [ThingClosed, Gone], channel: bus#/channels/none, transport: sse, replay: PT1H}
subscriptions:
  onClosed: {event: Unknown, handler: authored, delivery: {attempts: 3, deadLetter: bus#/channels/dead}}
  onLost: {event: Lost, handler: authored, delivery: {attempts: 1, deadLetter: bus#/channels/things}}
'''),
      [
        ('RIALTO-K004', '/events/Lost/data'),
        ('RIALTO-S002', '/events/Lost/channel'),
        ('RIALTO-K004', '/streams/live/events/1'),
        ('RIALTO-S002', '/streams/live/channel'),
        ('RIALTO-K004', '/subscriptions/onClosed/event'),
        ('RIALTO-S002', '/subscriptions/onClosed/delivery/deadLetter'),
      ],
    );
  });

  test('mappings: a side is a type, a shape or a reference into a source', () {
    expect(
      findings('''mappings:
  - {source: api#/components/schemas/Thing, target: Thing, direction: toTarget}
  - {source: api#/components/schemas/Nope, target: Ghost, direction: toTarget}
  - {source: Thing, target: elsewhere#/x, direction: toSource}
'''),
      [
        ('RIALTO-S002', '/mappings/1/source'),
        ('RIALTO-K004', '/mappings/1/target'),
        ('RIALTO-K004', '/mappings/2/target'),
      ],
    );
  });

  group('storage', () {
    test('a stored type, its table and every column resolve against the SQL source', () {
      expect(
        findings('''storage:
  Thing:
    table: db#thing
    columns: {id: id, status: state}
    version: rev
    delete: {soft: removed, by: remover}
    storageKey: skey
    blobs: {photo: {store: db, key: pkey, mediaType: photo_type, size: psize}}
    children: {parts: {ownerKey: owner, order: pos}}
    links: {tags: {table: db#thing_tag, ownerKey: owner, targetKey: target, order: pos}}
  Part:
    table: db#part
    columns:
      label: {join: thing_ref, table: db#thing, key: nope}
      name: {join: [{column: thing_id, table: db#thing}, {column: id, table: db#part}], key: nothing}
  Tag:
    table: db#tag
    links: {things: {ownerKey: tag_ref}}
  Ghost: {table: db#nowhere}
'''),
        [
          ('RIALTO-S002', '/storage/Thing/columns/status'),
          ('RIALTO-S002', '/storage/Thing/children/parts/ownerKey'),
          ('RIALTO-S002', '/storage/Thing/children/parts/order'),
          ('RIALTO-S002', '/storage/Thing/links/tags/ownerKey'),
          ('RIALTO-S002', '/storage/Thing/links/tags/targetKey'),
          ('RIALTO-S002', '/storage/Thing/links/tags/order'),
          ('RIALTO-S002', '/storage/Thing/version'),
          ('RIALTO-S002', '/storage/Thing/delete/soft'),
          ('RIALTO-S002', '/storage/Thing/delete/by'),
          ('RIALTO-S002', '/storage/Thing/storageKey'),
          ('RIALTO-S002', '/storage/Thing/blobs/photo/key'),
          ('RIALTO-S002', '/storage/Thing/blobs/photo/size'),
          ('RIALTO-S002', '/storage/Part/columns/label/join'),
          ('RIALTO-S002', '/storage/Part/columns/label/key'),
          ('RIALTO-S002', '/storage/Part/columns/name/key'),
          ('RIALTO-S002', '/storage/Tag/links/things/ownerKey'),
          ('RIALTO-K004', '/storage/Ghost'),
          ('RIALTO-S002', '/storage/Ghost/table'),
        ],
      );
    });

    test(
      'storage that matches the SQL source is valid, its table and column names in any case; a read-only link names a column of the target table',
      () {
        expect(
          findings('''storage:
  Thing:
    table: db#THING
    columns: {id: ID, status: status}
    version: version
    delete: {soft: deleted, by: deleted_by}
    storageKey: storage_key
    blobs: {photo: {store: db, key: photo_key, mediaType: photo_type, size: photo_size}}
    children: {parts: {ownerKey: id, order: position}}
    links: {tags: {table: db#thing_tag, ownerKey: thing_id, targetKey: tag_id, order: position}}
  Part:
    table: db#part
    columns: {id: {join: thing_id, table: db#thing, key: id}}
  Tag:
    table: db#tag
    links: {things: {ownerKey: storage_key}}
'''),
          isEmpty,
        );
      },
    );
  });

  test('views: load, fields, actions, tabs, the list and refreshOn', () {
    expect(
      findings('''operations:
  getThing: {output: Thing}
views:
  ThingView:
    load: getThing
    fields: {name: {edit: editNope, link: NoView, options: {operation: optNope, label: label}}}
    actions: {close: {operation: closeNope}}
    tabs: [ThingView, Other]
    list: {operation: listNope, open: NoView, actions: {open: {operation: openNope}}}
    refreshOn: [Unknown]
'''),
      [
        ('RIALTO-K004', '/views/ThingView/fields/name/edit'),
        ('RIALTO-K004', '/views/ThingView/fields/name/link'),
        ('RIALTO-K004', '/views/ThingView/fields/name/options/operation'),
        ('RIALTO-K004', '/views/ThingView/actions/close/operation'),
        ('RIALTO-K004', '/views/ThingView/tabs/1'),
        ('RIALTO-K004', '/views/ThingView/list/operation'),
        ('RIALTO-K004', '/views/ThingView/list/open'),
        ('RIALTO-K004', '/views/ThingView/list/actions/open/operation'),
        ('RIALTO-K004', '/views/ThingView/refreshOn/0'),
      ],
    );
  });

  test('navigation: home, and the view and badge of every menu entry', () {
    expect(
      findings('''operations:
  countThings: {output: Thing}
views:
  Home: {}
navigation:
  home: Away
  primary: [{view: Home, badge: countThings}, {view: Missing, badge: countNope}]
  secondary: [{view: Lost}]
'''),
      [
        ('RIALTO-K004', '/navigation/home'),
        ('RIALTO-K004', '/navigation/primary/1/view'),
        ('RIALTO-K004', '/navigation/primary/1/badge'),
        ('RIALTO-K004', '/navigation/secondary/0/view'),
      ],
    );
  });

  test('auth: the provider of a client, and the schemes of scopes and API keys', () {
    expect(
      findings('''auth:
  providers: {main: {issuer: "https://id.example"}}
  clients:
    web: {provider: other, clientId: web, flow: authorizationCode}
    app: {provider: main, clientId: app, flow: clientCredentials}
  scopes:
    read: {scheme: api#/components/securitySchemes/nope}
    write: {scheme: api#/components/securitySchemes/bearer}
  apiKeys:
    svc: {scheme: api#/components/securitySchemes/key, lookup: x}
'''),
      [
        ('RIALTO-K004', '/auth/clients/web/provider'),
        ('RIALTO-S002', '/auth/scopes/read/scheme'),
        ('RIALTO-S002', '/auth/apiKeys/svc/scheme'),
      ],
    );
  });

  test('sources: a successor is a declared source', () {
    final file = p.join(work.path, 'successor.rialto.yaml');
    File(file).writeAsStringSync('''rialto: "1.0.0"
info: {name: x, version: 1.0.0}
sources:
  old: {kind: openapi, path: api.json, version: 1.0.0, status: deprecated, deprecated: "2026-01-01", successor: api}
  api: {kind: openapi, path: api.json, version: 2.0.0, status: deprecated, deprecated: "2026-01-01", successor: nope}
''');
    expect(ContractValidator.validate(file).diagnostics.map((it) => (it.code.id, it.location.pointer)), [
      ('RIALTO-K004', '/sources/api/successor'),
    ]);
  });

  test('a reference into a source that cannot be read reports only the source (RIALTO-S001)', () {
    File(p.join(work.path, 'api.json')).deleteSync();
    expect(findings('mappings:\n  - {source: api#/components/schemas/Nope, target: Thing, direction: toTarget}\n'), [
      ('RIALTO-S001', '/sources/api/path'),
    ]);
  });
}
