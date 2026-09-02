import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// One value a program gives to every step that takes it.
///
/// Several steps of one program regularly need the same value, and writing it on thirty rows is not
/// the problem — the day it changes and twenty-nine rows are edited is. So a program may write it
/// once, and everything below reads the value as though the row carried it.
///
/// The whole path is exercised here, from the text of a file down to the fingerprint a run is gated
/// against, because a default that only some of that path can see is worse than none: it makes two
/// parts of the engine disagree about what a step was given.
void main() {
  /// Two steps: one takes `path` and `content`, the other takes `path` alone.
  ///
  /// The second is what proves a default is offered by DECLARATION and not by presence — a step that
  /// does not take `content` must not be handed it, or the argument check would refuse the row for a
  /// key nobody wrote.
  Registry registry() => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'writes_a_file': (
        'x:1',
        (Arguments a) => WritesAFile(path: a.text('path'), content: a.text('content')),
      ),
      'touches_a_file': ('x:2', (Arguments a) => WritesAFile(path: a.text('path'), content: '')),
      'signs_a_file': (
        'x:3',
        (Arguments a) => WritesAFile(path: a.text('path'), content: a.text('signing_key')),
      ),
    },
    arguments: <String, List<ArgumentSpec>>{
      'writes_a_file': const <ArgumentSpec>[
        ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file to write'),
        ArgumentSpec(name: 'content', kind: ArgumentKind.text, describes: 'what goes in it'),
      ],
      'touches_a_file': const <ArgumentSpec>[
        ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file to touch'),
      ],
      'signs_a_file': const <ArgumentSpec>[
        ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file to sign'),
        ArgumentSpec(
          name: 'signing_key',
          kind: ArgumentKind.text,
          describes: 'the key it is signed with',
          secret: true,
        ),
      ],
    },
  );

  ResolvedProgram resolve(String yaml) =>
      ProgramResolver(registry()).resolve(loadProgram(yaml, where: 'p.yaml'));

  String argumentOf(ResolvedProgram program, int row, String name) =>
      program.steps[row].entry.arguments.text(name);

  group('a value written once reaches every step that takes it', () {
    const String twoRows = '''
name: p
roles: [master]
defaults:
  content: from the program
steps:
  - step: writes_a_file
    path: /one
    on_failure: exit
  - step: writes_a_file
    path: /two
    on_failure: exit
''';

    test('a row keeps its own flags when a default is folded into it', () {
      // THE REBUILD. Folding a default means building the row again, and a field the rebuild forgets
      // arrives as its default with nothing saying so: the file states it, the loader parses it, and
      // the run behaves as though the line were never written. The search for it then starts at the
      // engine that reads the flag rather than at the copy that dropped it.
      final ResolvedProgram program = resolve('''
name: p
roles: [master]
defaults:
  content: from the program
steps:
  - step: writes_a_file
    path: /one
    on_failure: exit
    rests_on_an_earlier_step: true
    undo: false
    keep_output: true
''');

      final ProgramStep row = program.steps.single.entry;
      expect(
        row.arguments.text('content'),
        'from the program',
        reason:
            'the default really was folded in, so this row really was rebuilt — without that '
            'the rest of this test passes over a row nothing touched',
      );
      expect(row.restsOnAnEarlierStep, isTrue);
      expect(row.undo, isFalse, reason: 'its neighbour, so a rebuild that dropped both is caught');
      expect(row.keepsOutput, isTrue, reason: 'the third flag of the row, carried the same way');
    });

    test('both rows carry it, and neither wrote it', () {
      final ResolvedProgram program = resolve(twoRows);

      expect(argumentOf(program, 0, 'content'), 'from the program');
      expect(argumentOf(program, 1, 'content'), 'from the program');
    });

    test('a row that wrote its own keeps it', () {
      final ResolvedProgram program = resolve('''
name: p
roles: [master]
defaults:
  content: from the program
steps:
  - step: writes_a_file
    path: /one
    content: from the row
    on_failure: exit
  - step: writes_a_file
    path: /two
    on_failure: exit
''');

      expect(argumentOf(program, 0, 'content'), 'from the row');
      expect(
        argumentOf(program, 1, 'content'),
        'from the program',
        reason: 'one row deciding for itself says nothing about the next',
      );
    });

    test('a step that does not take it is not given it', () {
      // The refusal this would otherwise produce is an unknown argument on a row that wrote none,
      // which sends whoever reads it looking in the file for a key that is not there.
      final ResolvedProgram program = resolve('''
name: p
roles: [master]
defaults:
  content: from the program
steps:
  - step: writes_a_file
    path: /one
    on_failure: exit
  - step: touches_a_file
    path: /two
    on_failure: exit
''');

      expect(argumentOf(program, 0, 'content'), 'from the program');
      expect(program.steps[1].entry.arguments.raw('content'), isNull);
    });

    test('it satisfies an argument the step requires, so the row may leave it out', () {
      // `content` is required and no row writes it. Without the default reaching the argument check
      // this refuses, which is the failure that would make the feature useless for what it is for.
      expect(() => resolve(twoRows), returnsNormally);
    });
  });

  group('what is refused', () {
    test('a secret answer of a kind the redactor cannot read', () {
      // What reads a secret answer reads it as text - that is how a value gets into the redactor,
      // the one thing standing between a credential and a world-readable record. Declared on
      // another kind it passed every check and then threw where the redactor is built, after
      // validation, with a message naming a type rather than the declaration that caused it.
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: writes_a_file
    path: /one
    content: x
    on_failure: exit
answers:
  - name: token
    kind: integer
    secret: true
    describes: the credential
''', where: 'p.yaml'),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid it) => it.message,
            'message',
            allOf(contains('token'), contains('holds text')),
          ),
        ),
      );
    });

    test('a secret answer of text is accepted', () {
      // The other half: the refusal is about the KIND and not about the word secret.
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: writes_a_file
    path: /one
    content: x
    on_failure: exit
answers:
  - name: token
    kind: text
    secret: true
    describes: the credential
''', where: 'p.yaml'),
        returnsNormally,
      );
    });

    test('a default no step of the program declares', () {
      // The failure this catches is a misspelling. The key sits in the file filling nothing, every
      // step runs on its own default, and the file says something else — with nothing reporting it.
      expect(
        () => resolve('''
name: p
roles: [master]
defaults:
  contnet: from the program
steps:
  - step: writes_a_file
    path: /one
    content: written out
    on_failure: exit
'''),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid it) => it.message,
            'message',
            allOf(contains('contnet'), contains('fills nothing')),
          ),
        ),
      );
    });

    test('a default of the wrong kind, named as the argument it is wrong for', () {
      expect(
        () => resolve('''
name: p
roles: [master]
defaults:
  content: 7
steps:
  - step: writes_a_file
    path: /one
    on_failure: exit
'''),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid it) => it.message,
            'message',
            // The KIND, not just the name. An implementation that never folded defaults at all
            // would refuse this row for a missing required argument, which also names "content" —
            // so a test asserting the name alone could not tell the two apart.
            allOf(contains('content'), contains('holds text')),
          ),
        ),
      );
    });

    test('a default every row overrides, because it then decides nothing', () {
      // Dead configuration, and it reads from the file exactly like a key that decides something.
      // The day somebody removes the value from one row, what takes over is this — so it has to be
      // the value they expect, not one nothing has exercised since it was written.
      expect(
        () => resolve('''
name: p
roles: [master]
defaults:
  content: never used
steps:
  - step: writes_a_file
    path: /one
    content: from the row
    on_failure: exit
'''),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid it) => it.message,
            'message',
            allOf(contains('content'), contains('writes its own')),
          ),
        ),
      );
    });

    test('a default that would fill a secret argument', () {
      // A program file ships inside the binary to every installation, so a credential written into
      // one is the same credential everywhere. The loader already refuses this for a declared
      // ANSWER; without the same refusal here, this block would be the way around it.
      expect(
        () => resolve('''
name: p
roles: [master]
defaults:
  signing_key: hunter2
steps:
  - step: signs_a_file
    path: /one
    on_failure: exit
'''),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid it) => it.message,
            'message',
            allOf(contains('signing_key'), contains('secret')),
          ),
        ),
      );
    });

    test('the same name is fine on a step that does not call it secret', () {
      // The refusal is about the DECLARATION, not the word. A step declaring an ordinary argument
      // that happens to share the name is filled as any other would be.
      final ResolvedProgram program = resolve('''
name: p
roles: [master]
defaults:
  content: from the program
steps:
  - step: writes_a_file
    path: /one
    on_failure: exit
''');
      expect(argumentOf(program, 0, 'content'), 'from the program');
    });

    test('a defaults block that is not a map', () {
      expect(
        () => resolve('''
name: p
roles: [master]
defaults:
  - content
steps:
  - step: writes_a_file
    path: /one
    content: written out
    on_failure: exit
'''),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid it) => it.message,
            'message',
            contains('map of argument names'),
          ),
        ),
      );
    });
  });

  group('the gate a run is measured against sees it', () {
    // A run is allowed only where a dry run of the SAME input came back green, and the same input
    // means the same fingerprint. A default the fingerprint could not see would let a run pass the
    // gate of a dry run made under another value — a green verdict from a check that cannot go red.
    String fingerprintFor(String content) => fingerprintOf(
      program: resolve('''
name: p
roles: [master]
defaults:
  content: $content
steps:
  - step: writes_a_file
    path: /one
    on_failure: exit
'''),
      commit: 'abc',
      answers: Arguments.none,
    );

    test('changing a program default changes the fingerprint', () {
      expect(fingerprintFor('one thing'), isNot(fingerprintFor('another thing')));
    });

    test('the same default twice is the same fingerprint', () {
      expect(fingerprintFor('one thing'), fingerprintFor('one thing'));
    });

    test('a default and the same value written on the row are one input', () {
      // They are the same run, so they are gated as one. A fingerprint that told them apart would
      // make an operator repeat a dry run for moving a value they did not change.
      final String written = fingerprintOf(
        program: resolve('''
name: p
roles: [master]
steps:
  - step: writes_a_file
    path: /one
    content: the same
    on_failure: exit
'''),
        commit: 'abc',
        answers: Arguments.none,
      );

      expect(fingerprintFor('the same'), written);
    });
  });
}
