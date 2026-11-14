import 'package:rialto_contract/rialto_contract.dart';
import 'package:test/test.dart';

void main() {
  Map<String, SqlColumn> columns(String sql, [String table = 't']) => SqlSchema.read(sql)[table]!.columns;

  test('reads type names without length or precision, also of several words', () {
    final read = columns('''
CREATE TABLE public."T" (
    a VARCHAR(40),
    b character varying(10),
    c DOUBLE PRECISION,
    d numeric(8, 3),
    e timestamp(3) with time zone,
    f TEXT[],
    g int COLLATE "C",
    h VARCHAR(50)[]
);
''');
    expect(read.map((name, column) => MapEntry(name, column.type)), {
      'a': 'varchar',
      'b': 'character varying',
      'c': 'double precision',
      'd': 'numeric',
      'e': 'timestamp with time zone',
      'f': 'text[]',
      'g': 'int',
      'h': 'varchar[]',
    });
    expect(read.keys, ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']);
  });

  test('reads not null, primary keys, defaults and generated columns', () {
    final read = columns('''
CREATE TABLE t (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    code TEXT NOT NULL DEFAULT 'x',
    note TEXT NULL CHECK (note <> ''),
    seq BIGSERIAL,
    total INT GENERATED ALWAYS AS (1 + 1) STORED,
    a INT,
    b INT,
    CONSTRAINT pk PRIMARY KEY (a, b)
);
''');
    final id = read['id']!, code = read['code']!, note = read['note']!, seq = read['seq']!, total = read['total']!;
    expect(id.notNull && id.hasDefault && !id.primaryKey, isTrue);
    expect(code.notNull && code.hasDefault, isTrue);
    expect(note.acceptsNull && !note.hasDefault, isTrue);
    expect(seq.notNull && seq.hasDefault, isTrue);
    expect(total.acceptsNull && total.hasDefault, isTrue);
    expect(read['a']!.primaryKey && !read['a']!.acceptsNull, isTrue);
    expect(read['b']!.primaryKey, isTrue);
  });

  test('applies the alter table actions of later migrations in order (K1.9)', () {
    const sql = '''
CREATE TABLE t (id UUID PRIMARY KEY, a TEXT, b TEXT NOT NULL, c INT DEFAULT 1, d INT);
ALTER TABLE t ADD COLUMN e TEXT NOT NULL, ADD f INT;
ALTER TABLE IF EXISTS ONLY t ADD COLUMN IF NOT EXISTS a INT;
ALTER TABLE t DROP COLUMN IF EXISTS d CASCADE;
ALTER TABLE t RENAME COLUMN f TO g;
ALTER TABLE t ALTER COLUMN a SET NOT NULL, ALTER b DROP NOT NULL;
ALTER TABLE t ALTER COLUMN c DROP DEFAULT;
ALTER TABLE t ALTER COLUMN e SET DEFAULT 'x';
ALTER TABLE t ALTER COLUMN g TYPE BIGINT USING g::bigint;
ALTER TABLE t ALTER COLUMN b SET DATA TYPE varchar(10);
ALTER TABLE t ADD CONSTRAINT t_unique UNIQUE (a);
ALTER TABLE t RENAME TO u;
''';
    final read = columns(sql, 'u');
    expect(SqlSchema.read(sql).containsKey('t'), isFalse);
    expect(read.keys, ['id', 'a', 'b', 'c', 'e', 'g']);
    expect(read['a']!.type == 'text' && read['a']!.notNull, isTrue);
    expect(read['b']!.type == 'varchar' && read['b']!.acceptsNull, isTrue);
    expect(read['c']!.hasDefault, isFalse);
    expect(read['e']!.notNull && read['e']!.hasDefault, isTrue);
    expect(read['g']!.name == 'g' && read['g']!.type == 'bigint', isTrue);
  });

  test('adds a primary key constraint and drops tables', () {
    final tables = SqlSchema.read('''
CREATE TABLE t (id UUID);
ALTER TABLE t ADD CONSTRAINT t_pk PRIMARY KEY (id);
CREATE TABLE a (id INT); CREATE TABLE b (id INT);
DROP TABLE IF EXISTS a, b CASCADE;
CREATE TABLE IF NOT EXISTS t (other INT);
''');
    expect(tables.keys, ['t']);
    expect(tables['t']!.columns['id']!.primaryKey, isTrue);
  });

  test('skips comments, unknown statements and semicolons in strings and function bodies', () {
    final tables = SqlSchema.read(r'''
-- a comment; with a semicolon
/* CREATE TABLE ghost (id INT); */
CREATE EXTENSION IF NOT EXISTS citext;
CREATE FUNCTION touch() RETURNS trigger AS $$
BEGIN NEW.at := now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;
CREATE TABLE t (note TEXT DEFAULT 'a;b', "Mixed" INT);
CREATE INDEX t_note ON t (note);
INSERT INTO t (note) VALUES ('x; y');
''');
    expect(tables.keys, ['t']);
    expect(tables['t']!.columns.keys, ['note', 'mixed']);
  });
}
