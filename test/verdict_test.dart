import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A verdict comes from a checked postcondition, never from an exit code.
///
/// The shell this replaces had eleven phases that reported success over a real failure, every one of
/// them by trusting what a command returned: a wait whose bar was "more than zero pods running", a
/// version reader that printed `not installed` and returned zero, an upgrade that fell back to an
/// unpinned install. These tests are the general answer to all eleven.
void main() {
  ResolvedProgram programWith(
    Step Function(Arguments) step,
    OnFailure onFailure, {
    String name = 'the_step',
  }) => ProgramResolver(
    registryOf(steps: <String, (String, Step Function(Arguments))>{name: ('x:1', step)}),
  ).resolve(programOf('p', <(String, OnFailure, List<String>)>[(name, onFailure, <String>[])]));

  test('a step whose command succeeds but whose postcondition does not holds fails', () async {
    final Harness h = Harness();
    final RunRecord record = await h.runner.run(
      program: programWith((Arguments a) => const ClaimsSuccessWithout(), OnFailure.exit),
      mode: Mode.run,
      header: h.header(),
    );

    expect(h.shell.ran, <String>['true'], reason: 'the command ran and returned zero');
    expect(record.steps.single.verdict, isA<Failed>());
    expect((record.steps.single.verdict as Failed).reason, contains('still not in the state'));
    expect(record.exitCode, 1);
  });

  test('a step whose postcondition holds afterwards succeeds', () async {
    final Harness h = Harness();
    final RunRecord record = await h.runner.run(
      program: programWith(
        (Arguments a) => WritesAFile(path: '/etc/thing', content: 'x'),
        OnFailure.exit,
      ),
      mode: Mode.run,
      header: h.header(),
    );

    expect(record.steps.single.verdict, isA<Succeeded>());
    expect(h.files.contents['/etc/thing'], 'x');
    expect(record.exitCode, 0);
  });

  group('what a failure costs is what the program declared', () {
    test('die ends the run', () async {
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: programWith((Arguments a) => const Blocks('no disk'), OnFailure.exit),
        mode: Mode.run,
        header: h.header(),
      );
      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.exitCode, 1);
      expect(record.issues, isEmpty);
    });

    test('a failure the run carried on past is reported at the end', () async {
      // There is ONE way of carrying on, and it is reported at the end. A second way that is not
      // reported would differ only in how loudly the failure is written down rather than in what
      // happens next. A run that walked past a failure and came back looking clean is the one
      // outcome this cannot produce, so every continued failure is in the closing line.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: programWith((Arguments a) => const Blocks('no disk'), OnFailure.continueRun),
        mode: Mode.run,
        header: h.header(),
      );
      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.issues, <String>['the_step: no disk']);
      expect(record.exitCode, 2, reason: 'a run that finished with problems must not look clean');
      expect(record.clean, isFalse);
    });

    test('a failure that ended the run is not repeated in the closing line', () async {
      // The run stopped, and the last step of the record IS the reason. Repeating it at the end
      // would be the same failure counted twice, in a place whose whole job is to say what a run
      // that finished green nevertheless walked past.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: programWith((Arguments a) => const Blocks('no disk'), OnFailure.exit),
        mode: Mode.run,
        header: h.header(),
      );
      expect(record.steps.single.verdict, isA<Failed>());
      expect(record.issues, isEmpty);
      expect(record.exitCode, 1);
    });
  });

  test('a run that dies does not reach the steps after it', () async {
    final Harness h = Harness();
    final ResolvedProgram program =
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'blocks': ('x:1', (Arguments a) => const Blocks('no disk')),
              'writes': ('x:2', (Arguments a) => WritesAFile(path: '/late', content: 'x')),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('blocks', OnFailure.exit, <String>[]),
            ('writes', OnFailure.exit, <String>[]),
          ]),
        );

    final RunRecord record = await h.runner.run(
      program: program,
      mode: Mode.run,
      header: h.header(),
    );

    expect(record.steps, hasLength(1));
    expect(h.files.contents.containsKey('/late'), isFalse);
  });
}
