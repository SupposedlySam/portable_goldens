/// A document a command writes with `--json`, for tools to read.
///
/// Every document starts with its `schema` and `version`, so a reader can
/// refuse a version it does not know rather than misread one. Raise
/// [version] when a field is removed or changes meaning; a new field leaves
/// it as it is.
enum JsonFormat {
  /// `report --json`: the failed goldens and the ones this branch changed.
  report(1),

  /// `verify --json`: each golden's check, and whether verify passed.
  verify(1);

  new(this.version);

  /// The version of this format's fields.
  final int version;

  /// The schema name a document of this format carries.
  String get schema => 'portable_goldens.$name';

  /// [body] as a document: the schema and version first, then [body].
  Map<String, Object?> document(Map<String, Object?> body) => {
    'schema': schema,
    'version': version,
    ...body,
  };
}
