/// A column of an SQL table. [type] is the type name in lower case without length or precision, such as
/// `varchar` or `timestamp with time zone`; [hasDefault] is true for a `DEFAULT`, a generated column and an
/// identity or serial column.
class SqlColumn {
  const SqlColumn(this.name, this.type, {this.notNull = false, this.primaryKey = false, this.hasDefault = false});

  final String name;
  final String type;
  final bool notNull;
  final bool primaryKey;
  final bool hasDefault;

  /// Whether the column accepts null: it is neither `NOT NULL` nor part of the primary key.
  bool get acceptsNull => !notNull && !primaryKey;

  SqlColumn copyWith({String? name, String? type, bool? notNull, bool? primaryKey, bool? hasDefault}) => SqlColumn(
    name ?? this.name,
    type ?? this.type,
    notNull: notNull ?? this.notNull,
    primaryKey: primaryKey ?? this.primaryKey,
    hasDefault: hasDefault ?? this.hasDefault,
  );

  @override
  String toString() => 'SqlColumn($name, $type, notNull: $notNull, primaryKey: $primaryKey, hasDefault: $hasDefault)';
}

/// A table of an SQL schema, its columns by lower-case name in declaration order.
class SqlTable {
  const SqlTable(this.name, this.columns);

  final String name;
  final Map<String, SqlColumn> columns;
}

/// Reads the schema that results from SQL statements in order (K1.9): `CREATE TABLE`, the `ALTER TABLE`
/// actions on columns, the primary key and the table name, and `DROP TABLE`. Every other statement is
/// skipped. Names are compared in lower case without schema or quotes.
class SqlSchema {
  SqlSchema._();

  /// The tables after running [sql], by lower-case name.
  static Map<String, SqlTable> read(String sql) {
    final tables = <String, Map<String, SqlColumn>>{};
    for (final statement in statements(sql)) {
      _apply(tables, tokens(statement));
    }
    return tables.map((name, columns) => MapEntry(name, SqlTable(name, Map.unmodifiable(columns))));
  }

  /// The names of the tables and their columns, as [read] finds them.
  static Map<String, Set<String>> tables(String sql) =>
      read(sql).map((name, table) => MapEntry(name, table.columns.keys.toSet()));

  // Statements --------------------------------------------------------------------------------

  static void _apply(Map<String, Map<String, SqlColumn>> tables, List<String> tokens) {
    final words = _Words(tokens);
    if (words.accept('create')) {
      _createTable(tables, words);
    } else if (words.accept('alter table')) {
      _alterTable(tables, words);
    } else if (words.accept('drop table')) {
      _dropTable(tables, words);
    }
  }

  static void _createTable(Map<String, Map<String, SqlColumn>> tables, _Words words) {
    // CREATE [GLOBAL | LOCAL] [TEMP | TEMPORARY | UNLOGGED] TABLE
    while (const {'global', 'local', 'temp', 'temporary', 'unlogged'}.contains(words.peek())) {
      words.next();
    }
    if (!words.accept('table')) return;
    final ifNotExists = words.accept('if not exists');
    final first = words.next();
    if (first == null) return;
    final name = _identifier(first);
    final body = words.next();
    if (body == null || !body.startsWith('(')) return;
    if (ifNotExists && tables.containsKey(name)) return;

    final columns = <String, SqlColumn>{};
    for (final definition in _split(body.substring(1, body.length - 1))) {
      final parts = tokens(definition);
      if (parts.isEmpty) continue;
      if (_constraintStart.contains(parts.first.toLowerCase())) {
        for (final key in _primaryKeyOf(parts) ?? const <String>[]) {
          _markPrimaryKey(columns, key);
        }
      } else {
        final column = _column(parts);
        if (column != null) columns[column.name] = column;
      }
    }
    tables[name] = columns;
  }

  static void _alterTable(Map<String, Map<String, SqlColumn>> tables, _Words words) {
    words
      ..accept('if exists')
      ..accept('only');
    final first = words.next();
    if (first == null) return;
    final name = _identifier(first);
    // RENAME TO renames the table itself; it is not combined with other actions.
    if (words.accept('rename to')) {
      final to = words.next();
      if (to == null) return;
      final table = tables.remove(name);
      if (table != null) tables[_identifier(to)] = table;
      return;
    }
    final rest = words.rest();
    final columns = tables[name];
    if (columns == null) return;
    for (final action in _split(rest.join(' '))) {
      _alterAction(columns, _Words(tokens(action)));
    }
  }

  static void _alterAction(Map<String, SqlColumn> columns, _Words words) {
    if (words.accept('add')) {
      final parts = words.rest();
      if (parts.isEmpty) return;
      if (_constraintStart.contains(parts.first.toLowerCase())) {
        for (final key in _primaryKeyOf(parts) ?? const <String>[]) {
          _markPrimaryKey(columns, key);
        }
        return;
      }
      final definition = _Words(parts)..accept('column');
      final ifNotExists = definition.accept('if not exists');
      final column = _column(definition.rest());
      if (column == null) return;
      if (ifNotExists && columns.containsKey(column.name)) return;
      columns[column.name] = column;
    } else if (words.accept('drop')) {
      if (words.peek() == 'constraint') return;
      words
        ..accept('column')
        ..accept('if exists');
      final name = words.next();
      if (name != null) columns.remove(_identifier(name));
    } else if (words.accept('rename')) {
      if (words.peek() == 'constraint') return;
      words.accept('column');
      final from = words.next();
      if (from == null) return;
      if (!words.accept('to')) return;
      final to = words.next();
      if (to == null) return;
      final column = columns.remove(_identifier(from));
      if (column != null) columns[_identifier(to)] = column.copyWith(name: _identifier(to));
    } else if (words.accept('alter')) {
      words.accept('column');
      final first = words.next();
      if (first == null) return;
      final name = _identifier(first);
      final column = columns[name];
      if (column == null) return;
      final altered = _alterColumn(column, words);
      if (altered != null) columns[name] = altered;
    }
  }

  static SqlColumn? _alterColumn(SqlColumn column, _Words words) {
    if (words.accept('set not null')) return column.copyWith(notNull: true);
    if (words.accept('drop not null')) return column.copyWith(notNull: false);
    if (words.accept('set default')) return column.copyWith(hasDefault: true);
    if (words.accept('drop default')) return column.copyWith(hasDefault: false);
    if (words.accept('drop identity')) return column.copyWith(hasDefault: false);
    if (words.accept('add generated')) return column.copyWith(notNull: true, hasDefault: true);
    if (words.accept('set data type') || words.accept('type')) return column.copyWith(type: _typeName(words.rest()));
    return null;
  }

  static void _dropTable(Map<String, Map<String, SqlColumn>> tables, _Words words) {
    words.accept('if exists');
    // DROP TABLE a, b [CASCADE]: the names are separated by commas.
    for (final name in _split(words.rest().join(' '))) {
      final parts = tokens(name);
      if (parts.isNotEmpty) tables.remove(_identifier(parts.first));
    }
  }

  // Columns -----------------------------------------------------------------------------------

  /// A column definition: its name, its type and the column constraints after the type.
  static SqlColumn? _column(List<String> parts) {
    if (parts.length < 2) return null;
    final name = _identifier(parts.first);
    var typeEnd = parts.length;
    for (var i = 1; i < parts.length; i++) {
      if (_columnConstraint.contains(parts[i].toLowerCase())) {
        typeEnd = i;
        break;
      }
    }
    final type = _typeName(parts.sublist(1, typeEnd));
    final constraints = _Words(parts.sublist(typeEnd));

    var notNull = _serial.contains(type);
    var primaryKey = false;
    var hasDefault = _serial.contains(type);
    while (!constraints.done) {
      if (constraints.accept('not null')) {
        notNull = true;
      } else if (constraints.accept('primary key')) {
        primaryKey = true;
        notNull = true;
      } else if (constraints.accept('default')) {
        hasDefault = true;
      } else if (constraints.accept('generated')) {
        hasDefault = true;
        // An identity column is never null; a generated (expression) column can be.
        if (constraints.rest().any((it) => it.toLowerCase() == 'identity')) notNull = true;
      } else {
        constraints.next();
      }
    }
    return SqlColumn(name, type, notNull: notNull, primaryKey: primaryKey, hasDefault: hasDefault);
  }

  /// The type name of [parts] in lower case, without its length, precision or `USING` clause.
  static String _typeName(List<String> parts) => parts
      .takeWhile((it) => it.toLowerCase() != 'using' && !_columnConstraint.contains(it.toLowerCase()))
      .where((it) => !it.startsWith('('))
      .map((it) => it.toLowerCase())
      .join(' ')
      .replaceAll(' [', '[');

  /// The columns of a `PRIMARY KEY (...)` table constraint, optionally named, or null.
  static List<String>? _primaryKeyOf(List<String> parts) {
    final words = _Words(parts);
    if (words.accept('constraint')) words.next();
    if (!words.accept('primary key')) return null;
    final list = words.next();
    if (list == null || !list.startsWith('(')) return null;
    return _split(list.substring(1, list.length - 1)).map((it) => _identifier(it.trim())).toList();
  }

  static void _markPrimaryKey(Map<String, SqlColumn> columns, String name) {
    final key = _identifier(name);
    final column = columns[key];
    if (column != null) columns[key] = column.copyWith(primaryKey: true, notNull: true);
  }

  /// A table or column name in lower case, without schema and quotes.
  static String _identifier(String text) {
    var name = text.trim();
    name = name.substring(name.lastIndexOf('.') + 1);
    var start = 0, end = name.length;
    while (start < end && name[start] == '"') {
      start++;
    }
    while (end > start && name[end - 1] == '"') {
      end--;
    }
    return name.substring(start, end).toLowerCase();
  }

  // Lexing ------------------------------------------------------------------------------------

  /// The statements of [sql], split on `;` outside quotes, comments and dollar-quoted bodies; the comments
  /// themselves are left out.
  static List<String> statements(String sql) {
    final statements = <String>[];
    final current = StringBuffer();
    var index = 0;
    while (index < sql.length) {
      final char = sql[index];
      var end = -1;
      if (sql.startsWith('--', index)) {
        final newline = sql.indexOf('\n', index);
        end = newline < 0 ? sql.length : newline;
      } else if (sql.startsWith('/*', index)) {
        final close = sql.indexOf('*/', index + 2);
        end = close < 0 ? sql.length : close + 2;
      }
      if (end >= 0) {
        current.write(' ');
        index = end;
        continue;
      }
      final quoted = _quotedEnd(sql, index);
      if (quoted > index) {
        current.write(sql.substring(index, quoted));
        index = quoted;
      } else if (char == ';') {
        statements.add(current.toString());
        current.clear();
        index++;
      } else {
        current.write(char);
        index++;
      }
    }
    statements.add(current.toString());
    return statements.map((it) => it.trim()).where((it) => it.isNotEmpty).toList();
  }

  /// The end of a quoted string, identifier or dollar-quoted body starting at [start], or [start].
  static int _quotedEnd(String sql, int start) {
    final char = sql[start];
    if (char == "'" || char == '"') {
      var index = start + 1;
      while (index < sql.length) {
        if (sql[index] == char) {
          // A doubled quote is an escaped quote.
          if (index + 1 < sql.length && sql[index + 1] == char) {
            index += 2;
            continue;
          }
          return index + 1;
        }
        index++;
      }
      return sql.length;
    }
    if (char == r'$') {
      final tag = _dollarTag.matchAsPrefix(sql.substring(start, start + 64 < sql.length ? start + 64 : sql.length));
      if (tag != null) {
        final value = tag.group(0)!;
        final close = sql.indexOf(value, start + value.length);
        return close < 0 ? sql.length : close + value.length;
      }
    }
    return start;
  }

  /// The tokens of one statement or definition: words, quoted strings and identifiers, and each
  /// parenthesized group as one token, including its parentheses.
  static List<String> tokens(String text) {
    final tokens = <String>[];
    var index = 0;
    while (index < text.length) {
      final char = text[index];
      if (_whitespace.hasMatch(char)) {
        index++;
      } else if (char == '(') {
        final end = _groupEnd(text, index);
        tokens.add(text.substring(index, end));
        index = end;
      } else if (char == ',') {
        tokens.add(',');
        index++;
      } else {
        final start = index;
        while (index < text.length) {
          final c = text[index];
          if (_whitespace.hasMatch(c) || c == '(' || c == ',') break;
          final quoted = _quotedEnd(text, index);
          index = quoted > index ? quoted : index + 1;
        }
        tokens.add(text.substring(start, index));
      }
    }
    return tokens;
  }

  /// The end of the parenthesized group that opens at [start].
  static int _groupEnd(String text, int start) {
    var depth = 0;
    var index = start;
    while (index < text.length) {
      final quoted = _quotedEnd(text, index);
      if (quoted > index) {
        index = quoted;
        continue;
      }
      switch (text[index]) {
        case '(':
          depth++;
        case ')':
          if (--depth == 0) return index + 1;
      }
      index++;
    }
    return text.length;
  }

  /// [text] split on commas outside parentheses and quotes.
  static List<String> _split(String text) {
    final parts = <String>[];
    final current = StringBuffer();
    var depth = 0;
    var index = 0;
    while (index < text.length) {
      final quoted = _quotedEnd(text, index);
      if (quoted > index) {
        current.write(text.substring(index, quoted));
        index = quoted;
        continue;
      }
      final char = text[index];
      if (char == '(') depth++;
      if (char == ')') depth--;
      if (char == ',' && depth == 0) {
        parts.add(current.toString());
        current.clear();
      } else {
        current.write(char);
      }
      index++;
    }
    parts.add(current.toString());
    return parts.where((it) => it.trim().isNotEmpty).toList();
  }

  static const _constraintStart = {'primary', 'foreign', 'unique', 'check', 'constraint', 'exclude', 'like'};

  /// The words that end the type of a column definition.
  static const _columnConstraint = {
    'not',
    'null',
    'primary',
    'default',
    'references',
    'check',
    'unique',
    'constraint',
    'generated',
    'collate',
  };

  static const _serial = {'serial', 'bigserial', 'smallserial', 'serial4', 'serial8', 'serial2'};

  static final _dollarTag = RegExp(r'\$[A-Za-z_]*\$');
  static final _whitespace = RegExp(r'\s');
}

/// A cursor over tokens, matching keywords case-insensitively.
class _Words {
  _Words(this._tokens);

  final List<String> _tokens;
  var _index = 0;

  bool get done => _index >= _tokens.length;

  String? peek() => _index < _tokens.length ? _tokens[_index].toLowerCase() : null;

  String? next() => _index < _tokens.length ? _tokens[_index++] : null;

  List<String> rest() => _tokens.sublist(_index < _tokens.length ? _index : _tokens.length);

  /// Consumes [keywords], separated by spaces, when the next tokens are exactly these, in order.
  bool accept(String keywords) {
    final words = keywords.split(' ');
    for (var offset = 0; offset < words.length; offset++) {
      final at = _index + offset;
      if (at >= _tokens.length || _tokens[at].toLowerCase() != words[offset]) return false;
    }
    _index += words.length;
    return true;
  }
}
