import 'dart:convert';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// What a command leaves in the record, and who decides.
///
/// Output is kept where it is evidence: for a command that failed, and for a row that said
/// `keep_output` because its command's answer IS what somebody will need to read — a release tool
/// that exits zero and reports what it did. Everything else leaves only the exit code, the elapsed
/// time and a count of the lines that were not kept, so the record does not grow with every line
/// of every command and an unkept answer still cannot be read as an empty one.
void main() {
  RecordingShell recording(Harness h, {bool keepsOutput = false}) => RecordingShell(
    h.shell,
    recorder: h.recorder,
    redactor: h.redactor,
    step: const StepName('runs'),
    keepsOutput: keepsOutput,
  );

  /// The context one step runs in, for the two tests that ask a step and not a port.
  StepContext contextOn(Harness h) => StepContext(
    shell: h.shell,
    files: h.files,
    http: h.http,
    clock: h.clock,
    entropy: h.entropy,
    log: RecordingLogger(recorder: h.recorder, redactor: h.redactor, step: const StepName('runs')),
    step: const StepName('runs'),
    arguments: Arguments.none,
    facts: Facts.none,
  );

  group('what a command leaves in the record', () {
    test('a failed command keeps its output without being asked', () async {
      final Harness h = Harness();
      h.shell.answer(
        'tool apply',
        const CommandResult(
          exitCode: 1,
          stdout: 'started fine',
          stderr: 'Error: create failed',
          elapsed: Duration.zero,
        ),
      );

      await recording(h).run(const Command('tool', <String>['apply']));

      expect(h.recorder.output, <String>['started fine', 'Error: create failed']);
    });

    test('a succeeded command leaves no output behind unless its row asked', () async {
      final Harness h = Harness();
      h.shell.answers('tool apply', 'line one\nline two');

      await recording(h).run(const Command('tool', <String>['apply']));

      expect(
        h.recorder.only<Output>(),
        isEmpty,
        reason: 'this is what keeps the record from growing for every run',
      );
    });

    test('the record still says how much an unkept command said', () async {
      final Harness h = Harness();
      h.shell.answers('tool apply', 'line one\nline two');

      await recording(h).run(const Command('tool', <String>['apply']));

      final CommandFinished finished = h.recorder.only<CommandFinished>().single;
      expect(finished.exitCode, 0);
      expect(
        finished.stdoutLines,
        2,
        reason: 'without the count, "not kept" would read as "said nothing"',
      );
      expect(finished.stderrLines, 0);
    });

    test('a succeeded command keeps its output where the row asked, '
        'and a secret in it still cannot pass', () async {
      final Harness h = Harness(secrets: <String>['s3cret-value-here']);
      h.shell.answers('tool apply', 'released with token s3cret-value-here\nall good');

      await recording(h, keepsOutput: true).run(const Command('tool', <String>['apply']));

      expect(h.recorder.output, <String>['released with token [redacted]', 'all good']);
      expect(
        jsonEncode(<Object?>[
          for (final RunEvent e in h.recorder.events) const RecordCodec().event(e),
        ]),
        isNot(contains('s3cret-value-here')),
        reason: 'nothing anywhere in the record may carry the value',
      );
    });

    test('the bound holds where the row asked', () async {
      final Harness h = Harness();
      h.shell.answers(
        'tool apply',
        List<String>.generate(60, (int i) => 'line ${i + 1}').join('\n'),
      );

      await recording(h, keepsOutput: true).run(const Command('tool', <String>['apply']));

      expect(h.recorder.output.length, RecordingShell.maxLines + 1);
      expect(h.recorder.output.first, '[dropped 10 lines of output]');
      expect(h.recorder.output[1], 'line 11', reason: 'the tail, because the end says why');
      expect(h.recorder.output.last, 'line 60');
      expect(h.recorder.output, isNot(contains('line 10')));
      expect(
        h.recorder.only<CommandFinished>().single.stdoutLines,
        60,
        reason: 'the count is what the command said, not what the record kept of it',
      );
    });

    test('output that fits is kept whole, with no marker claiming a drop', () async {
      final Harness h = Harness();
      h.shell.answers(
        'tool apply',
        List<String>.generate(RecordingShell.maxLines, (int i) => 'line ${i + 1}').join('\n'),
      );

      await recording(h, keepsOutput: true).run(const Command('tool', <String>['apply']));

      expect(h.recorder.output.length, RecordingShell.maxLines);
      expect(h.recorder.output.where((String l) => l.startsWith('[dropped')), isEmpty);
    });

    test('what was kept survives being written down and read back', () async {
      final Harness h = Harness(secrets: <String>['s3cret-value-here']);
      h.shell.answers('tool apply', 'released with token s3cret-value-here\nall good');
      await recording(h, keepsOutput: true).run(const Command('tool', <String>['apply']));

      const RecordCodec codec = RecordCodec();
      final List<RunEvent> back = <RunEvent>[
        for (final RunEvent e in h.recorder.events)
          codec.eventFrom(jsonDecode(jsonEncode(codec.event(e))) as Map<String, Object?>),
      ];

      expect(back.whereType<Output>().map((Output e) => e.text), <String>[
        'released with token [redacted]',
        'all good',
      ]);
      final CommandFinished finished = back.whereType<CommandFinished>().single;
      expect(finished.stdoutLines, 2);
      expect(finished.stderrLines, 0);
    });
  });

  group('the row is what decides', () {
    test('of two succeeding rows, the one that asked keeps its answer '
        'and the one that did not stays quiet', () async {
      final Harness h = Harness();
      h.shell.answers('tool noise', 'downloading, unpacking, chattering');
      h.shell.answers('tool release', 'release placed: everything it installed listed here');
      h.shell.changes('tool noise', () => h.files.contents['/noise-made'] = '');
      h.shell.changes('tool release', () => h.files.contents['/release-made'] = '');

      final ResolvedProgram program =
          ProgramResolver(
            registryOf(
              steps: <String, (String, Step Function(Arguments))>{
                'noisy': (
                  'x:1',
                  (Arguments a) =>
                      RunsACommand(argv: <String>['tool', 'noise'], leaves: '/noise-made'),
                ),
                'evidence': (
                  'x:2',
                  (Arguments a) =>
                      RunsACommand(argv: <String>['tool', 'release'], leaves: '/release-made'),
                ),
              },
            ),
          ).resolve(
            programOf(
              'p',
              <(String, OnFailure, List<String>)>[
                ('noisy', OnFailure.exit, <String>[]),
                ('evidence', OnFailure.exit, <String>[]),
              ],
              keepOutput: <String>{'evidence'},
            ),
          );

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.exitCode, 0, reason: 'both commands succeeded — that is the point');
      expect(h.recorder.output, <String>['release placed: everything it installed listed here']);
      expect(h.recorder.forStep(const StepName('noisy')).whereType<Output>(), isEmpty);
    });
  });

  group('a command whose output must never be kept', () {
    // The shape this exists for: a command that reads a credential store whole answers with every
    // credential in it, in whatever form that store keeps them. It is not text the redactor was
    // told about, so nothing is looking for it.
    const String heldSecret = 'cGFzc3dvcmQtb2YtZXZlcnl0aGluZw==';

    Command readsTheStore() =>
        const Command.observing('tool', arguments: <String>['read'], secretOutput: true);

    test('a command that failed keeps none of what it wrote', () async {
      final Harness h = Harness();
      h.shell.answer(
        'tool read',
        const CommandResult(
          exitCode: 1,
          stdout: 'field: $heldSecret\nfield2: $heldSecret',
          stderr: 'Error: the store answered halfway',
          elapsed: Duration.zero,
        ),
      );

      await recording(h).run(readsTheStore());

      expect(
        jsonEncode(<Object?>[
          for (final RunEvent e in h.recorder.events) const RecordCodec().event(e),
        ]),
        isNot(contains(heldSecret)),
        reason: 'a failed command is the one case output is kept without anybody asking',
      );
    });

    test(
      'THE INNOCENT NEIGHBOUR: the same failure without the declaration keeps its output',
      () async {
        final Harness h = Harness();
        h.shell.answer(
          'tool read',
          const CommandResult(
            exitCode: 1,
            stdout: 'field: $heldSecret',
            stderr: 'Error: the store answered halfway',
            elapsed: Duration.zero,
          ),
        );

        await recording(h).run(const Command.observing('tool', arguments: <String>['read']));

        expect(h.recorder.output, <String>[
          'field: $heldSecret',
          'Error: the store answered halfway',
        ]);
      },
    );

    test('the record says how many lines were withheld, and still counts them', () async {
      final Harness h = Harness();
      h.shell.answer(
        'tool read',
        const CommandResult(
          exitCode: 1,
          stdout: 'field: $heldSecret\nfield2: $heldSecret',
          stderr: 'Error: the store answered halfway',
          elapsed: Duration.zero,
        ),
      );

      await recording(h).run(readsTheStore());

      expect(h.recorder.output, <String>[
        '[withheld 2 lines: this command answers with a secret]',
        '[withheld 1 line: this command answers with a secret]',
      ], reason: 'without this, a failed command with no output reads as one that said nothing');
      final CommandFinished finished = h.recorder.only<CommandFinished>().single;
      expect(finished.stdoutLines, 2);
      expect(finished.stderrLines, 1);
    });

    test('a row that says keep_output where such a command runs is REFUSED, naming the '
        'step and the flag', () async {
      final Harness h = Harness();
      h.shell.answers('tool read', 'field: $heldSecret');

      expect(
        () => recording(h, keepsOutput: true).run(readsTheStore()),
        throwsA(
          isA<KeepOutputRefused>()
              .having((KeepOutputRefused f) => f.step, 'step', const StepName('runs'))
              .having((KeepOutputRefused f) => f.message, 'message', contains('keep_output'))
              .having((KeepOutputRefused f) => f.message, 'message', contains('tool read')),
        ),
      );
    });

    test('the refusal comes before the command runs and before anything is recorded', () async {
      final Harness h = Harness();
      h.shell.answers('tool read', 'field: $heldSecret');

      await expectLater(
        () => recording(h, keepsOutput: true).run(readsTheStore()),
        throwsA(isA<KeepOutputRefused>()),
      );

      expect(h.shell.ran, isEmpty, reason: 'what was refused did not happen');
      expect(
        h.recorder.events,
        isEmpty,
        reason: 'and a record saying it was started would say that it did',
      );
    });

    test('a failure of such a command reports its exit code and none of its answer', () async {
      final Harness h = Harness();
      h.shell.answer(
        'tool read',
        const CommandResult(
          exitCode: 2,
          stdout: 'field: $heldSecret',
          stderr: 'Error: $heldSecret came back malformed',
          elapsed: Duration.zero,
        ),
      );
      final RunsACommand step = RunsACommand(
        argv: <String>['tool', 'read'],
        leaves: '/never-written',
        secretOutput: true,
      );

      await expectLater(
        () => step.apply(contextOn(h)),
        throwsA(
          isA<CommandFailed>()
              .having((CommandFailed f) => f.exitCode, 'exitCode', 2)
              .having((CommandFailed f) => f.message, 'message', isNot(contains(heldSecret)))
              .having((CommandFailed f) => f.message, 'message', contains('tool read returned 2')),
        ),
      );
    });

    test('THE INNOCENT NEIGHBOUR: an ordinary command still fails with what it wrote', () async {
      final Harness h = Harness();
      h.shell.answer(
        'tool read',
        const CommandResult(
          exitCode: 2,
          stdout: '',
          stderr: 'Error: the store is not there',
          elapsed: Duration.zero,
        ),
      );
      final RunsACommand step = RunsACommand(
        argv: <String>['tool', 'read'],
        leaves: '/never-written',
      );

      await expectLater(
        () => step.apply(contextOn(h)),
        throwsA(
          isA<CommandFailed>().having(
            (CommandFailed f) => f.message,
            'message',
            contains('the store is not there'),
          ),
        ),
      );
    });
  });

  group('the two rows of one program, side by side', () {
    // The counter-probe of the whole mechanism, as a program rather than as a port: one row asks to
    // keep the output of a command that answers with a secret and is refused; the row beside it asks
    // the same thing of an ordinary command and gets it.
    const String heldSecret = 'cGFzc3dvcmQtb2YtZXZlcnl0aGluZw==';

    test('the row running a secret answer is refused, and the ordinary row still keeps its '
        'output', () async {
      final Harness h = Harness();
      h.shell.answers('tool release', 'release placed: everything it installed listed here');
      h.shell.changes('tool release', () => h.files.contents['/release-made'] = '');
      h.shell.answers('tool read', 'field: $heldSecret');

      final ResolvedProgram program =
          ProgramResolver(
            registryOf(
              steps: <String, (String, Step Function(Arguments))>{
                'evidence': (
                  'x:1',
                  (Arguments a) =>
                      RunsACommand(argv: <String>['tool', 'release'], leaves: '/release-made'),
                ),
                'reads_the_store': (
                  'x:2',
                  (Arguments a) => RunsACommand(
                    argv: <String>['tool', 'read'],
                    leaves: '/never-written',
                    secretOutput: true,
                  ),
                ),
              },
            ),
          ).resolve(
            programOf(
              'p',
              <(String, OnFailure, List<String>)>[
                ('evidence', OnFailure.exit, <String>[]),
                ('reads_the_store', OnFailure.exit, <String>[]),
              ],
              keepOutput: <String>{'evidence', 'reads_the_store'},
            ),
          );

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.exitCode, isNot(0));
      final StepRecord refused = record.steps.last;
      expect(refused.step, const StepName('reads_the_store'));
      final Failed verdict = refused.verdict as Failed;
      expect(verdict.reason, contains('reads_the_store'));
      expect(verdict.reason, contains('keep_output'));
      expect(
        h.recorder.output,
        contains('release placed: everything it installed listed here'),
        reason: 'a row that asks for an ordinary command\'s answer still gets it',
      );
      expect(
        '${jsonEncode(<Object?>[for (final RunEvent e in h.recorder.events) const RecordCodec().event(e)])}'
        '${jsonEncode(const RecordCodec().run(record))}',
        isNot(contains(heldSecret)),
      );
    });
  });

  group('the unwind keeps the row\'s word', () {
    ResolvedProgram placesThenFails(Harness h, {required bool keep}) {
      h.shell.answers('tool remove', 'removed cleanly');
      h.shell.changes('tool place', () => h.files.contents['/placed'] = '');
      return ProgramResolver(
        registryOf(
          steps: <String, (String, Step Function(Arguments))>{
            'places': ('x:1', (Arguments a) => const PlacesByCommand()),
            'fails': ('x:2', (Arguments a) => const Blocks('the disk went away')),
          },
        ),
      ).resolve(
        programOf('p', <(String, OnFailure, List<String>)>[
          ('places', OnFailure.exit, <String>[]),
          ('fails', OnFailure.exit, <String>[]),
        ], keepOutput: keep ? <String>{'places'} : const <String>{}),
      );
    }

    test('an undo of a row that asked keeps what its command said', () async {
      final Harness h = Harness();
      await h.runner.run(
        program: placesThenFails(h, keep: true),
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.recorder.output, contains('removed cleanly'));
    });

    test('an undo of a row that did not ask stays quiet', () async {
      final Harness h = Harness();
      await h.runner.run(
        program: placesThenFails(h, keep: false),
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.recorder.output, isNot(contains('removed cleanly')));
    });
  });
}

/// A step whose undo speaks through a command, so what the unwind's shell records can be asserted.
final class PlacesByCommand extends ReversibleStep<Object?> {
  const PlacesByCommand();

  @override
  Future<CheckResult> check(StepContext context) async => await context.files.exists('/placed')
      ? const CheckResult.satisfied('/placed is there')
      : const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('would place it');

  @override
  Future<void> apply(StepContext context) async {
    await context.shell.run(const Command('tool', <String>['place']));
  }

  @override
  Future<Object?> capture(StepContext context) async => null;

  @override
  Future<void> undo(StepContext context, Object? captured) async {
    await context.shell.run(const Command('tool', <String>['remove']));
  }
}
