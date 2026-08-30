import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A credential that stands in a file on the machine, and the run that spends it.
///
/// **What this is about.** A machine that mints its own credential leaves it in a file and has no
/// caller to carry it back in as an answer. The other derivation rules cannot compose one: they
/// work a value out of text the run already holds, and this value is on disk. So a program declares
/// the answer as the secret in the file another answer names, the RUN reads it before its first
/// step, and the step that needs it reads the answer by name as it always did.
///
/// **The two halves are measured separately.** That the value reaches the step at all — otherwise
/// the record being clean would mean nothing was carried. And that it is in no line of the finished
/// record, which is the promise the file port cannot make on its own: nothing gave the value to the
/// run's redactor, because nothing outside the machine knew it.
void main() {
  const String keyFile = '/tmp/a-staged-credential';
  const String credential = 'a-credential-nobody-typed';
  const RunId id = RunId('20260831T120000Z-1');

  Registry registry() => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'says': ('test/support/example_steps.dart:1', SaysAnAnswer.fromArguments),
    },
    arguments: <String, List<ArgumentSpec>>{'says': SaysAnAnswer.arguments},
  );

  /// A program whose `auth_key` is the secret in the file `key_file` names.
  Program readsItFromTheFile() => programOf(
    'p',
    const <(String, OnFailure, List<String>)>[('says', OnFailure.exit, <String>[])],
    arguments: <String, Arguments>{
      'says': const Arguments(<String, Object>{'answer': 'auth_key'}),
    },
    answers: const DeclaredAnswers(<ArgumentSpec>[
      ArgumentSpec(name: 'key_file', kind: ArgumentKind.text, describes: 'where it stands'),
      ArgumentSpec(
        name: 'auth_key',
        kind: ArgumentKind.text,
        required: false,
        describes: 'the credential standing in that file',
        derivation: Derivation(rule: DerivationRule.secretInFileAt, from: 'key_file'),
      ),
    ]),
  );

  /// The same program with `auth_key` supplied as an ordinary answer nobody hides.
  ///
  /// The innocent neighbour of the redaction test: it proves the record WOULD carry the value, so a
  /// clean record above means it was removed rather than never written.
  Program takesItAsAPlainAnswer() => programOf(
    'p',
    const <(String, OnFailure, List<String>)>[('says', OnFailure.exit, <String>[])],
    arguments: <String, Arguments>{
      'says': const Arguments(<String, Object>{'answer': 'auth_key'}),
    },
    answers: const DeclaredAnswers(<ArgumentSpec>[
      ArgumentSpec(name: 'key_file', kind: ArgumentKind.text, describes: 'where it stands'),
      ArgumentSpec(name: 'auth_key', kind: ArgumentKind.text, describes: 'the same value, typed'),
    ]),
  );

  late Directory temp;
  late RunDirectory directory;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ansiwise-secret-in-file-');
    directory = RunDirectory(temp.path);
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a handle open for a moment after a file is closed.
    }
  });

  /// Runs [program] with [answers] against a machine holding [holds], and returns every line of the
  /// record it left behind — the events and the header, which is what an operator reads.
  Future<({RunRecord closed, List<String> lines})> runAndRead(
    Program program, {
    required Map<String, Object?> answers,
    Map<String, String> holds = const <String, String>{},
  }) async {
    final FakeClock clock = FakeClock();
    final Redactor redactor = Redactor(const <String>[]);
    final FileRecorder recorder = await FileRecorder.open(
      id: id,
      directory: directory,
      clock: clock,
      redactor: redactor,
    );
    final RunRecord header = RunRecord(
      id: id,
      program: const ProgramName('p'),
      mode: Mode.run,
      argv: const <String>['ansiwise', 'p'],
      start: clock.now(),
      stage: const Stage('dev'),
      role: const Role('master'),
      fqdn: const Fqdn('m1.example.com'),
      commit: '0000000',
      fingerprint: 'test-fingerprint',
    );

    final RunRecord closed =
        await Runner(
          machine: fakeMachine(files: FakeFiles(<String, String>{...holds}), clock: clock),
          recorder: recorder,
          redactor: redactor,
        ).run(
          program: ProgramResolver(registry()).resolve(program),
          mode: Mode.run,
          header: header,
          answers: program.answers.validate(answers, program: 'p'),
        );
    await recorder.close();
    await recorder.save(closed);

    return (
      closed: closed,
      lines: <String>[
        ...File(directory.events(id)).readAsLinesSync(),
        ...File(directory.header(id)).readAsLinesSync(),
      ].where((String line) => line.isNotEmpty).toList(growable: false),
    );
  }

  test('the step reads the credential the file held, and the run closes green', () async {
    // The half that has to hold first. A record with no credential in it says nothing at all if the
    // credential never reached the step that was supposed to spend it.
    final ({RunRecord closed, List<String> lines}) ran = await runAndRead(
      readsItFromTheFile(),
      answers: <String, Object?>{'key_file': keyFile},
      holds: <String, String>{keyFile: '$credential\n'},
    );

    expect(ran.closed.exitCode, 0);
    expect(
      ran.lines.where((String line) => line.contains(Redactor.marker)),
      isNotEmpty,
      reason: 'the step wrote SOMETHING where the credential stood, so the value was carried',
    );
  });

  test('the credential is in no line of the finished record', () async {
    final ({RunRecord closed, List<String> lines}) ran = await runAndRead(
      readsItFromTheFile(),
      answers: <String, Object?>{'key_file': keyFile},
      holds: <String, String>{keyFile: '$credential\n'},
    );

    expect(
      ran.lines.where((String line) => line.contains(credential)),
      isEmpty,
      reason:
          'a value that existed only in a file on the machine reached a world-readable record — '
          'nothing outside the machine could have given it to the run\'s redactor, so the run has '
          'to register it itself',
    );
  });

  test('THE INNOCENT NEIGHBOUR: the same value as a plain answer IS in the record', () async {
    // Without this, the test above would pass over a run that never carried the value at all, and a
    // clean record would mean nobody was looking rather than that nothing got through.
    final ({RunRecord closed, List<String> lines}) ran = await runAndRead(
      takesItAsAPlainAnswer(),
      answers: <String, Object?>{'key_file': keyFile, 'auth_key': credential},
    );

    expect(ran.lines.where((String line) => line.contains(credential)), isNotEmpty);
  });

  test('THE PLANTED DEFECT: a file that is not there ends the run before its first step', () async {
    // Not an empty answer and not a default. The run stops where the reason is still legible, with
    // the path in the record's one issue — the alternative is a step refusing about a credential it
    // was handed nothing for, three files away from the mistake.
    final ({RunRecord closed, List<String> lines}) ran = await runAndRead(
      readsItFromTheFile(),
      answers: <String, Object?>{'key_file': keyFile},
    );

    expect(ran.closed.exitCode, 1);
    expect(ran.closed.steps, isEmpty, reason: 'nothing ran against the machine');
    expect(ran.closed.issues.single, allOf(contains('auth_key'), contains(keyFile)));
  });

  test('a file holding only whitespace ends it the same way', () async {
    final ({RunRecord closed, List<String> lines}) ran = await runAndRead(
      readsItFromTheFile(),
      answers: <String, Object?>{'key_file': keyFile},
      holds: <String, String>{keyFile: '\n'},
    );

    expect(ran.closed.exitCode, 1);
    expect(ran.closed.issues.single, allOf(contains(keyFile), contains('whitespace')));
  });
}
