import 'package:ansiwise_core/src/domain/arguments.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The grammar of a mapping entry's body, and the line between what the framework reads and what
/// belongs to the step.
///
/// **Why this file exists, and what a suite without it does not catch.** A rule built as "a body is
/// `{answer: <name>}` or `{measured: <name>}` and nothing else" reads well and refuses eight rows
/// that ship in a real installation — among them `{ answer: <name>, join: ", " }` and
/// `{ file: <path>, key: <name>, split: ", ", join: "', '" }`. Every one of them is a step reading
/// its own properties beside a source, or resolving a source the framework has no word for.
///
/// So the line is not "these two shapes or nothing". It is: the framework reads TWO WORDS and passes
/// over the rest, because reading the rest would put a step's private vocabulary inside the engine.
///
/// The bodies below are copied SHAPE FOR SHAPE from the programs that carry them — with the paths
/// and answer names generalised, because this framework names no installation of itself — so a rule
/// that would refuse one of them is refused HERE instead of in an installation.
void main() {
  // The loader hands the resolver plain maps, not the YAML node types, so the rows below are turned
  // into the same shape before they are read — otherwise every body would be passed over as a
  // scalar and this file would pass without measuring anything.
  Object? plain(Object? node) => switch (node) {
    final YamlMap map => <String, Object?>{
      for (final MapEntry<Object?, Object?> each in map.entries)
        each.key.toString(): plain(each.value),
    },
    final YamlList list => <Object?>[for (final Object? each in list) plain(each)],
    _ => node,
  };

  MappingEntries entriesOf(String yaml) => mappingEntriesIn(plain(loadYaml(yaml)));

  group('the two words the framework reads', () {
    test('an answer is bound', () {
      final MappingEntries read = entriesOf('name: {answer: fqdn}');
      expect(read.refused, isEmpty);
      expect((read.sources['name']! as FromAnswer).answer, 'fqdn');
    });

    test('a measurement is bound', () {
      final MappingEntries read = entriesOf('run-id: {measured: reading}');
      expect(read.refused, isEmpty);
      expect((read.sources['run-id']! as FromMeasurement).measurement.toString(), 'reading');
    });

    test('a measurement name the grammar does not admit is refused as one', () {
      final MappingEntries read = entriesOf('run-id: {measured: Bad.Name}');
      expect(read.sources, isEmpty);
      expect(read.refused['run-id'], contains('not a measurement name'));
    });

    test('naming both at once is refused, because nothing says which', () {
      final MappingEntries read = entriesOf('x: {answer: a, measured: m}');
      expect(read.sources, isEmpty);
      expect(read.refused['x'], contains('which of them the value comes from'));
    });
  });

  group('THE ROWS THAT SHIP: a step keeps its own properties', () {
    // Each of these is the shape of a row an installation ships. A grammar that refuses one of them
    // stops that installation resolving, and the first anyone would know is a program that no
    // longer runs.
    const Map<String, String> shipped = <String, String>{
      'a source and one separator': 'recipients: { answer: recipients, join: ", " }',
      'a separator with no space': 'RECIPIENTS: { answer: recipients, join: "," }',
      'a separator that is itself quoted': 'recipients: { answer: recipients, join: "\', \'" }',
      'a source the framework has no word for, with two separators':
          'recipients: { file: /srv/map.yaml, key: recipients, split: ", ", join: "\', \'" }',
    };

    shipped.forEach((String where, String row) {
      test('$where resolves', () {
        expect(
          entriesOf(row).refused,
          isEmpty,
          reason:
              'a row of this shape ships in an installation today, and refusing it here would stop '
              'that program resolving',
        );
      });
    });

    test('a source beside its own properties is still read', () {
      final MappingEntries read = entriesOf('r: { answer: recipients, join: ", " }');
      expect((read.sources['r']! as FromAnswer).answer, 'recipients');
    });

    test('a body naming NEITHER word is passed over, not judged', () {
      // The step resolves this one itself. What the framework may not do is guess at it.
      final MappingEntries read = entriesOf(
        'r: { file: /srv/map.yaml, key: recipients, split: ", " }',
      );
      expect(read.refused, isEmpty);
      expect(read.sources, isEmpty);
    });

    test('a written-out scalar is passed over, as it always was', () {
      final MappingEntries read = entriesOf('r: plain-value');
      expect(read.refused, isEmpty);
      expect(read.sources, isEmpty);
    });
  });
}
