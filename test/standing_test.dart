import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A run never claims more than it has.
///
/// A record that says "succeeded" answers a different question from the one an operator is asking
/// after a real run. They can see it did not fail. What they cannot see, and what this file makes
/// the record say, is HOW MUCH OF IT ANYTHING LOOKED AT — because a run that skipped half its steps
/// and a run that measured every one of them return the same zero.
///
/// THREE STATES, and the point is that they never mix. Proven is what the framework measured;
/// declared is what something claimed and nothing verified; skipped did not run. **Skipped is not
/// passed**, and a waived gate is not a proof.
///
/// AND PROVEN IS ABOUT THIS RUN'S ROW, not about the kind of step that produced it. The shape of a
/// step says whether a row of it can ever be proven; whether the reading came back says whether
/// this one was. WHICH reading follows the mode — the check in a test, the plan in a dry run, the
/// postcondition after the apply in a real one — and a row that never reached its own is declared,
/// however ordinary the step. The last three groups are one such row each, so a rule that held for
/// the check and not for the plan or the apply cannot pass this file.
void main() {
  /// The work of the row whose APPLY needs root, and not its reading.
  ///
  /// Its check asks the file system, which needs no privilege at all, so a machine that can raise
  /// nothing to root refuses this command and leaves the check already answered — which is where an
  /// installation program keeps its root work: restart a unit, write under a directory only root
  /// may write.
  const List<String> restartArgv = <String>['systemctl', 'restart', 'example'];

  /// What that restart is supposed to leave behind, and so what a real run judges the row by.
  const String restartLeaves = '/run/example.pid';

  /// A registry holding one of each kind of row this file is about.
  Registry registry() => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'measures': ('x:1', (Arguments a) => const Measures('the machine is as it should be')),
      'verifies': ('x:2', (Arguments a) => const VerifiesWhatRanBefore()),
      'waits': ('x:3', (Arguments a) => WaitsOnTheRowsWord(command: a.text('command'))),
      'measures_as_root': ('x:4', (Arguments a) => const MeasuresAsRoot()),
      'plans_as_root': ('x:5', (Arguments a) => const PlansAsRoot(content: 'the new text')),
      'applies_as_root': (
        'x:6',
        (Arguments a) => RunsACommand(argv: restartArgv, leaves: restartLeaves, elevated: true),
      ),
    },
    predicates: <String, Predicate>{
      'never': const Says(answer: false, because: 'this machine is not that kind'),
    },
    arguments: <String, List<ArgumentSpec>>{
      'waits': const <ArgumentSpec>[
        ArgumentSpec(
          name: 'command',
          kind: ArgumentKind.text,
          describes: 'what is run each time this looks',
        ),
      ],
    },
  );

  ResolvedProgram resolve(
    List<(String, OnFailure, List<String>)> entries, {
    Map<String, Arguments> arguments = const <String, Arguments>{},
  }) => ProgramResolver(registry()).resolve(programOf('p', entries, arguments: arguments));

  /// A runner on a machine that can raise nothing to root, which is what an installation naming no
  /// elevation password is.
  ///
  /// THE REAL SHELL AND NOT A FAKE ONE, because the refusal is the thing under test: it is raised
  /// INSTEAD of starting the process, so nothing on the machine this suite runs on is reached and
  /// what the check meets is the same object a real run meets. Everything else stays the harness's
  /// fakes.
  Runner cannotElevate(Harness h) => Runner(
    machine: Machine(
      shell: const RealShell(elevation: Elevation.unconfigured()),
      files: h.files,
      http: h.http,
      clock: h.clock,
      entropy: h.entropy,
    ),
    recorder: h.recorder,
    redactor: h.redactor,
  );

  group('a row the framework measured', () {
    test('is proven', () async {
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures', OnFailure.exit, <String>[]),
        ]),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.steps.single.standing, StepStanding.proven);
      expect(record.standings, const Standings(proven: 1));
      expect(record.fullyProven, isTrue);
    });
  });

  group('a row nothing measured', () {
    test('is declared, not proven', () async {
      // The gate verifies an earlier step, and in a dry run that step has not run — so its check
      // cannot hold and the engine carries the run past it on what it SAYS it would check.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('verifies', OnFailure.exit, <String>[]),
        ]),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.steps.single.verdict, isA<Succeeded>());
      expect(
        record.steps.single.standing,
        StepStanding.declared,
        reason: 'the row came back a success, and nothing verified it',
      );
    });

    test('keeps the whole run from reporting as fully proven', () async {
      // THE PROPERTY THIS TICKET EXISTS FOR, and the reason the assertion is on a run with a
      // measured row beside the declared one: a run that was declared THROUGHOUT would fail this
      // too, and would not show that one bad row is enough.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures', OnFailure.exit, <String>[]),
          ('verifies', OnFailure.exit, <String>[]),
        ]),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.exitCode, 0, reason: 'nothing failed, which is exactly the trap');
      expect(record.standings, const Standings(proven: 1, declared: 1));
      expect(
        record.fullyProven,
        isFalse,
        reason: 'a green run holding one row nothing looked at is not a proven run',
      );
    });
  });

  group('a row whose command the row itself supplies', () {
    /// The wait's row, carrying the command the way a program file would.
    final Map<String, Arguments> rowCommand = <String, Arguments>{
      'waits': const Arguments(<String, Object>{'command': 'asks-the-machine'}),
    };

    test('is declared while an ordinary row beside it stays proven', () async {
      // The framework did not choose what this wait runs, so it cannot verify the row's claim that
      // the command only looks — and a run holding such a row must say it rests on trust.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures', OnFailure.exit, <String>[]),
          ('waits', OnFailure.exit, <String>[]),
        ], arguments: rowCommand),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.steps.first.standing, StepStanding.proven);
      expect(record.steps.last.standing, StepStanding.declared);
      expect(record.standings, const Standings(proven: 1, declared: 1));
      expect(
        record.fullyProven,
        isFalse,
        reason: 'the wait answered through a command only the row vouches for',
      );
    });

    test(
      'stays declared when the wait fails, because the failure was measured on trust too',
      () async {
        // Every branch of the engine stamps it, not only the green one: what a reached deadline saw
        // came out of the same unverified command as a yes would have.
        final Harness h = Harness();
        final RunRecord record = await h.runner.run(
          program: resolve(<(String, OnFailure, List<String>)>[
            ('waits', OnFailure.exit, <String>[]),
          ], arguments: rowCommand),
          mode: Mode.run,
          header: h.header(),
        );

        expect(record.steps.single.verdict, isA<Failed>());
        expect(record.steps.single.standing, StepStanding.declared);
        expect(record.fullyProven, isFalse);
      },
    );
  });

  group('a row that did not run', () {
    test('is skipped, and is never added to the proven ones', () async {
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures', OnFailure.exit, <String>[]),
          ('measures', OnFailure.exit, <String>['never']),
        ]),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.standings, const Standings(proven: 1, skipped: 1));
      expect(
        record.standings.proven,
        1,
        reason:
            'skipped is not passed — the second row ran nothing and must not be counted as if '
            'it had',
      );
      expect(record.fullyProven, isFalse);
    });
  });

  group('a row that failed', () {
    test('is proven, because the framework watched it fail', () async {
      // Standing is not the verdict. A failure the framework measured is a measurement, and reading
      // one off the other is what would let a run report a row nothing looked at as green.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures', OnFailure.exit, <String>[]),
        ]),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.single.standing, StepStanding.proven);
    });
  });

  group('a row whose check could not be taken at all', () {
    /// The one row, run on the machine each test names.
    List<(String, OnFailure, List<String>)> readsAsRoot(OnFailure onFailure) =>
        <(String, OnFailure, List<String>)>[('measures_as_root', onFailure, <String>[])];

    test('is declared, and not proven', () async {
      // Its check looks for a path only root may see, on an installation that names no elevation
      // password: the shell refuses before a process starts, so the check never reached the machine
      // it was asked about. The step is an ordinary measuring one — nothing about its SHAPE says it
      // cannot be proven — and the shape was all the engine consulted.
      final Harness h = Harness();
      final RunRecord record = await cannotElevate(
        h,
      ).run(program: resolve(readsAsRoot(OnFailure.exit)), mode: Mode.run, header: h.header());

      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.steps.single.standing, StepStanding.declared);
      expect(record.fullyProven, isFalse);
    });

    test('is counted apart from the measured rows in the line an operator reads first', () async {
      // THE LINE AND NOT ONLY THE ROW. Two such rows, both carrying the run past their own failure,
      // closed "2 proven, 0 declared, 0 skipped" — and that line is the one that travels into a
      // report saying the install went through.
      final Harness h = Harness();
      final RunRecord record = await cannotElevate(h).run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures_as_root', OnFailure.continueRun, <String>[]),
          ('measures_as_root', OnFailure.continueRun, <String>[]),
        ]),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.exitCode, 2);
      expect(record.standings, const Standings(declared: 2));
      expect(
        h.recorder.events.whereType<RunFinished>().single.standings,
        record.standings,
        reason: 'the number somebody tailing the run sees is the number the record keeps',
      );
    });

    test('THE INNOCENT NEIGHBOUR: a check that ANSWERS blocked stays proven', () async {
      // The same step and the same command, on a machine that let the reading be taken. It came
      // back no, the row failed, and the framework watched that happen — which is a measurement.
      // Anything that stamped every blocked row declared would pass the two tests above and fail
      // this one.
      final Harness h = Harness()..shell.fails(MeasuresAsRoot.looks.argv.join(' '));
      final RunRecord record = await h.runner.run(
        program: resolve(readsAsRoot(OnFailure.exit)),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.steps.single.standing, StepStanding.proven);
    });

    test('THE SECOND INNOCENT NEIGHBOUR: a check that answers satisfied stays proven', () async {
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(readsAsRoot(OnFailure.exit)),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.single.verdict, isA<Succeeded>());
      expect(record.standings, const Standings(proven: 1));
      expect(record.fullyProven, isTrue);
    });
  });

  group('a row whose plan could not be composed', () {
    /// The one row, planned on the machine each test names.
    final List<(String, OnFailure, List<String>)> writesAsRoot =
        <(String, OnFailure, List<String>)>[('plans_as_root', OnFailure.exit, <String>[])];

    test('is declared, and not proven', () async {
      // The other place a reading is taken. This step's check answers without touching anything;
      // what needs root is the plan, which describes the change out of what stands in the file now.
      // In a dry run the plan IS the reading the row is judged by, and there is none.
      final Harness h = Harness();
      final RunRecord record = await cannotElevate(h).run(
        program: resolve(writesAsRoot),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.steps.single.standing, StepStanding.declared);
      expect(record.fullyProven, isFalse);
    });

    test('THE INNOCENT NEIGHBOUR: the same row where the reading comes back is proven', () async {
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(writesAsRoot),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.steps.single.verdict, isA<Succeeded>());
      expect(record.steps.single.standing, StepStanding.proven);
      expect(
        record.steps.single.plan,
        isNotNull,
        reason: 'the plan is what a dry run measured, so a proven row has to hold one',
      );
    });
  });

  group('a row whose postcondition was never read', () {
    /// The one row, run on the machine each test names.
    List<(String, OnFailure, List<String>)> restartsAsRoot(OnFailure onFailure) =>
        <(String, OnFailure, List<String>)>[('applies_as_root', onFailure, <String>[])];

    test('is declared, and not proven', () async {
      // THE OTHER HALF OF THE SAME REFUSAL. An installation program's root work sits in the APPLY —
      // restart a unit, write under a directory only root may write — and this row's check asks the
      // file system, which needs nothing. So the check answers, the shell refuses to raise the
      // command before a process starts, and the reading a real run judges a row by is never taken.
      // Whether the row measured anything cannot depend on which of the engine's two catch blocks
      // saw the throw, and this is the row where it did.
      final Harness h = Harness();
      final RunRecord record = await cannotElevate(
        h,
      ).run(program: resolve(restartsAsRoot(OnFailure.exit)), mode: Mode.run, header: h.header());

      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.steps.single.standing, StepStanding.declared);
      expect(record.fullyProven, isFalse);
    });

    test('is counted apart from the measured rows in the line an operator reads first', () async {
      // THE ISSUE'S OWN LINE, on the half of its scenario the first fix did not reach. Two such
      // rows, both carrying the run past their own failure, closed "2 proven, 0 declared,
      // 0 skipped" on a run that exited 2 and read nothing.
      final Harness h = Harness();
      final RunRecord record = await cannotElevate(h).run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('applies_as_root', OnFailure.continueRun, <String>[]),
          ('applies_as_root', OnFailure.continueRun, <String>[]),
        ]),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.exitCode, 2);
      expect(record.standings.summary, '0 proven, 2 declared, 0 skipped');
      expect(
        h.recorder.events.whereType<RunFinished>().single.standings,
        record.standings,
        reason: 'the number somebody tailing the run sees is the number the record keeps',
      );
    });

    test('is declared as well where the command ran and the machine answered', () async {
      // THE EDGE OF THE RULE, written down so it is a decision rather than an accident. This
      // command reached the machine and the machine answered — with an exit code that is not
      // zero — and the row is still declared, because a real run is judged by the postcondition
      // after the apply and the apply never returned. WHY the work stopped is the verdict's answer
      // and it is there; the standing says only that nothing read what the machine holds now.
      final Harness h = Harness()..shell.fails(restartArgv.join(' '), exitCode: 3);
      final RunRecord record = await h.runner.run(
        program: resolve(restartsAsRoot(OnFailure.exit)),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.steps.single.standing, StepStanding.declared);
    });

    test('THE INNOCENT NEIGHBOUR: a postcondition read that did not hold stays proven', () async {
      // The same row on a machine where the command runs and leaves nothing behind. The engine read
      // the postcondition, it did not hold, and the row failed on a reading — which is a
      // measurement. Anything that stamped every failed row declared would pass the three tests
      // above and fail this one.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(restartsAsRoot(OnFailure.exit)),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.steps.single.standing, StepStanding.proven);
    });

    test('THE SECOND INNOCENT NEIGHBOUR: a postcondition that holds is proven', () async {
      final Harness h = Harness();
      h.shell.changes(restartArgv.join(' '), () => h.files.contents[restartLeaves] = '');
      final RunRecord record = await h.runner.run(
        program: resolve(restartsAsRoot(OnFailure.exit)),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.single.verdict, isA<Succeeded>());
      expect(record.standings, const Standings(proven: 1));
      expect(record.fullyProven, isTrue);
    });
  });

  group('the closing line', () {
    test('states the three separately, including the zeroes', () async {
      final Harness h = Harness();
      await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures', OnFailure.exit, <String>[]),
          ('verifies', OnFailure.exit, <String>[]),
          ('measures', OnFailure.exit, <String>['never']),
        ]),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      final RunFinished closing = h.recorder.events.whereType<RunFinished>().single;
      expect(closing.standings, const Standings(proven: 1, declared: 1, skipped: 1));
      expect(closing.standings.summary, '1 proven, 1 declared, 1 skipped');
    });

    test('says every state even where one is empty', () {
      // A line that dropped the zeroes would read as though those states did not exist, and the
      // reader could not tell "nothing was skipped" from "skipping is not counted here".
      expect(const Standings(proven: 4).summary, '4 proven, 0 declared, 0 skipped');
    });

    test('is what the record says too', () async {
      // Two places state these numbers — the event somebody tails and the record they open
      // afterwards — and a disagreement between them is a disagreement about what a run proved.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: resolve(<(String, OnFailure, List<String>)>[
          ('measures', OnFailure.exit, <String>[]),
          ('verifies', OnFailure.exit, <String>[]),
        ]),
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      final RunFinished closing = h.recorder.events.whereType<RunFinished>().single;
      expect(closing.standings, record.standings);
    });
  });
}
