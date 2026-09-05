import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A skipped step names the condition that skipped it.
///
/// A run that quietly does less on one machine than on another is a run nobody can reason about.
/// Every condition is measured once, before the first step, and the answer is in the record — so
/// the plan printed before anything happens is the plan that is followed.
void main() {
  ResolvedProgram programGuardedBy({required bool holds, required String because}) =>
      ProgramResolver(
        registryOf(
          steps: <String, (String, Step Function(Arguments))>{
            'writes': ('x:1', (Arguments a) => WritesAFile(path: '/x', content: 'x')),
          },
          predicates: <String, Predicate>{'has_two_nics': Says(answer: holds, because: because)},
        ),
      ).resolve(
        programOf('p', <(String, OnFailure, List<String>)>[
          ('writes', OnFailure.exit, <String>['has_two_nics']),
        ]),
      );

  test('a step whose condition does not hold is skipped, and the record says which', () async {
    final Harness h = Harness();
    final RunRecord record = await h.runner.run(
      program: programGuardedBy(holds: false, because: 'this machine has one network interface'),
      mode: Mode.run,
      header: h.header(),
    );

    expect(record.steps.single.verdict, isA<Skipped>());
    expect((record.steps.single.verdict as Skipped).predicate, 'has_two_nics');
    expect(h.files.written, isEmpty);
    expect(record.exitCode, 0, reason: 'a skipped step is not a failure');
  });

  test('a step whose condition holds runs', () async {
    final Harness h = Harness();
    final RunRecord record = await h.runner.run(
      program: programGuardedBy(holds: true, because: 'two interfaces are up'),
      mode: Mode.run,
      header: h.header(),
    );

    expect(record.steps.single.verdict, isA<Succeeded>());
    expect(h.files.written, <String>['/x']);
  });

  test('what a condition found is in the record, in its own words', () async {
    final Harness h = Harness();
    await h.runner.run(
      program: programGuardedBy(holds: false, because: 'this machine has one network interface'),
      mode: Mode.run,
      header: h.header(),
    );

    final List<PredicateEvaluated> measured = h.recorder.only<PredicateEvaluated>();
    expect(measured, hasLength(1));
    expect(measured.single.predicate.value, 'has_two_nics');
    expect(measured.single.held, isFalse);
    expect(measured.single.because, 'this machine has one network interface');
  });

  test('a condition is measured once even when several steps use it', () async {
    final Harness h = Harness();
    int asked = 0;
    final ResolvedProgram program =
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'a': ('x:1', (Arguments _) => WritesAFile(path: '/a', content: 'a')),
              'b': ('x:2', (Arguments _) => WritesAFile(path: '/b', content: 'b')),
            },
            predicates: <String, Predicate>{'counted': Counting(() => asked++)},
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('a', OnFailure.exit, <String>['counted']),
            ('b', OnFailure.exit, <String>['counted']),
          ]),
        );

    await h.runner.run(program: program, mode: Mode.run, header: h.header());
    expect(asked, 1, reason: 'a machine measured twice can answer twice');
  });

  test(
    'a program that does not apply to this role is refused before anything is measured',
    () async {
      final Harness h = Harness();
      await expectLater(
        h.runner.run(
          program: programGuardedBy(holds: true, because: 'x'),
          mode: Mode.run,
          header: h.header(role: 'slave'),
        ),
        throwsA(isA<RoleMismatch>()),
      );
      expect(h.recorder.events, isEmpty);
    },
  );

  test('a role that carries several parts is admitted where any one of them applies', () async {
    // The machine IS each of its parts: a program declared for `master` runs against a machine
    // whose role is `master+slave`, because that machine is a master — beside being a slave.
    // Refused instead, the one machine doing both jobs could run nothing declared for either.
    final Harness h = Harness();
    final RunRecord record = await h.runner.run(
      program: programGuardedBy(holds: true, because: 'x'),
      mode: Mode.run,
      header: h.header(role: 'master+slave'),
    );
    expect(record.exitCode, 0);
    expect(h.files.written, isNot(isEmpty));
  });

  group('a condition that cannot be answered', () {
    // The THIRD outcome. Both cases of PredicateResult assert something about the machine, so a
    // condition that could not read its input has to leave the run rather than pick one — answering
    // "it does not hold" would switch off every step waiting on that name, in silence.
    ResolvedProgram programThatCannotAsk() =>
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'writes': ('x:1', (Arguments a) => WritesAFile(path: '/x', content: 'x')),
            },
            predicates: <String, Predicate>{
              'feature_enabled': const CannotSay('/etc/subject/settings is not on this machine'),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('writes', OnFailure.exit, <String>['feature_enabled']),
          ]),
        );

    test('THE RECORD IS CLOSED, with an end and an exit code', () async {
      // A record left with no end and no exit code makes everything reading records afterwards
      // show a run still going while the process is gone.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: programThatCannotAsk(),
        mode: Mode.test,
        header: h.header(),
      );

      expect(record.exitCode, isNot(0));
      expect(record.end, isNotNull);
    });

    test('it names what could not be read, so an operator can act on it', () async {
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: programThatCannotAsk(),
        mode: Mode.test,
        header: h.header(),
      );

      expect(record.issues.single, contains('/etc/subject/settings'));
    });

    test('nothing ran, and the record says so rather than leaving it to be inferred', () async {
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: programThatCannotAsk(),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps, isEmpty);
      expect(h.files.written, isEmpty, reason: 'the refusal lands before the first step');
    });

    test('AND SO DOES ANY OTHER FAILURE, which is what makes the record trustworthy', () async {
      // The general case, found the same way as the one above and one step further along: a step
      // whose restart never comes back throws a plain state error, and a record left open by it has
      // no end and no exit code. Every reader of records then shows a run still going while the
      // process is gone — for ever, since nothing is left to correct it.
      //
      // A throw out of a step is the ROW's failure, whatever its Dart type, so what was thrown is
      // read where an operator looks for it: the last row of the record, and not the run's single
      // issue over a record holding no rows at all — which is where it lands wherever a catch in
      // the engine asks for an Exception, since a StateError is not one.
      final Harness h = Harness();
      final ResolvedProgram program =
          ProgramResolver(
            registryOf(
              steps: <String, (String, Step Function(Arguments))>{
                'throws': ('x:1', (Arguments a) => const ThrowsSomethingElse()),
              },
            ),
          ).resolve(
            programOf('p', <(String, OnFailure, List<String>)>[
              ('throws', OnFailure.exit, <String>[]),
            ]),
          );

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.end, isNotNull);
      expect(record.exitCode, isNot(0));
      expect(
        (record.steps.single.verdict as Failed).reason,
        contains('the machine did not come back'),
      );
    });

    test('THE INNOCENT NEIGHBOUR: a condition that CAN answer still closes normally', () async {
      // Without this, a runner that treated every condition as unanswerable would pass all three
      // assertions above and no program with a `when:` would ever run.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: programGuardedBy(holds: true, because: 'two interfaces are up'),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.exitCode, 0);
      expect(record.issues, isEmpty);
      expect(h.files.written, isNotEmpty);
    });
  });
}

final class Counting implements Predicate {
  const Counting(this.onAsk);

  final void Function() onAsk;

  @override
  Future<PredicateResult> evaluate(PredicateContext context) async {
    onAsk();
    return const PredicateResult.holds('counted');
  }
}
