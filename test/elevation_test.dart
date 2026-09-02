import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// Raising a command to root: where the password comes from, and what the record says about it.
///
/// Treat every line here as security work. A password on a command line stands in the process
/// listing for every account on the machine; a password read from a path written into the framework
/// is a path nobody could change and one that failed as the command underneath it, sending the
/// operator to read a tool's output for a problem that was never in it.
void main() {
  group('where the password comes from', () {
    test('is the first line of the file the installation named', () async {
      final Elevation elevation = await Elevation.read(
        files: FakeFiles(<String, String>{'/somewhere/.pass': 'the password\n'}),
        path: '/somewhere/.pass',
      );

      expect(elevation.password, 'the password');
      expect(elevation.from, '/somewhere/.pass');
    });

    test('keeps a password exactly as it stands, spaces and all', () async {
      // Not trimmed. A password quietly stripped is a run that fails to elevate with a file that
      // looks correct, and nothing in the failure would point at the trimming.
      final Elevation elevation = await Elevation.read(
        files: FakeFiles(<String, String>{'/p': ' two words \n'}),
        path: '/p',
      );

      expect(elevation.password, ' two words ');
    });

    test('reads a file an editor ended with a carriage return', () async {
      final Elevation elevation = await Elevation.read(
        files: FakeFiles(<String, String>{'/p': 'the password\r\n'}),
        path: '/p',
      );

      expect(elevation.password, 'the password');
    });

    test('a file that is not there refuses, and the refusal is about the password', () {
      expect(
        Elevation.read(files: FakeFiles(<String, String>{}), path: '/gone/.pass'),
        throwsA(
          isA<ElevationUnavailable>().having(
            (ElevationUnavailable refused) => refused.message,
            'message',
            allOf(contains('elevation password file'), contains('/gone/.pass')),
          ),
        ),
        reason:
            'a failure inside a shell comes back as a non-zero exit of the step\'s own command, '
            'which sends the operator to look at the wrong thing',
      );
    });

    test('a file whose first line is empty refuses rather than elevating with nothing', () {
      expect(
        Elevation.read(files: FakeFiles(<String, String>{'/p': '\nsomething\n'}), path: '/p'),
        throwsA(
          isA<ElevationUnavailable>().having(
            (ElevationUnavailable refused) => refused.message,
            'message',
            contains('holds no password'),
          ),
        ),
      );
    });

    test('nothing configured is a state, not a password', () {
      expect(const Elevation.unconfigured().password, isNull);
    });
  });

  group('what the configuration file says about it', () {
    Future<Configuration> read(String yaml) => Configuration.load(
      files: FakeFiles(<String, String>{'ansiwise.yaml': yaml}),
      path: 'ansiwise.yaml',
    );

    test('names the file, and there is no path anywhere to fall back to', () async {
      expect(
        (await read('plugins:\n  - one\nelevation:\n  password_file: /home/op/.pass\n')).elevation,
        const ElevationFromFile('/home/op/.pass'),
      );
    });

    test('or names the caller, and then nothing on this machine holds it', () async {
      expect(
        (await read('plugins:\n  - one\nelevation:\n  password_from_caller: true\n')).elevation,
        const ElevationFromCaller(),
      );
    });

    test('naming BOTH routes is refused — two answers to one question', () {
      // Whichever this picked would be the one somebody did not mean, and the one it dropped is the
      // one they would go on believing was in use.
      expect(
        read(
          'plugins:\n  - one\nelevation:\n  password_file: /home/op/.pass\n'
          '  password_from_caller: true\n',
        ),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected refused) => refused.message,
            'message',
            contains('names both'),
          ),
        ),
      );
    });

    test('a caller route that is not true or false is refused', () {
      expect(
        read('plugins:\n  - one\nelevation:\n  password_from_caller: sometimes\n'),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected refused) => refused.message,
            'message',
            contains('it is true or false'),
          ),
        ),
      );
    });

    test('a file that says nothing about it names nothing', () async {
      expect((await read('plugins:\n  - one\n')).elevation, isNull);
    });

    test('an elevation block with no file is refused rather than read past', () {
      // Somebody who wrote the word meant to configure elevation, and a key silently ignored leaves
      // them believing they did.
      expect(
        read('plugins:\n  - one\nelevation:\n  something_else: /x\n'),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected refused) => refused.message,
            'message',
            contains('says neither "password_file:" nor "password_from_caller: true"'),
          ),
        ),
      );
    });

    test('an elevation that is not a mapping is refused', () {
      expect(
        read('plugins:\n  - one\nelevation: /home/op/.pass\n'),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected refused) => refused.message,
            'message',
            contains('"elevation" has to be a mapping'),
          ),
        ),
      );
    });
  });

  group('a command that has to run as root', () {
    test('is refused before the process starts when nothing says how', () {
      // The executable named here exists on no machine this suite runs on. A shell that started the
      // process first would come back with a failure to start it; getting the refusal instead is
      // what proves nothing was started.
      expect(
        const RealShell(
          elevation: Elevation.unconfigured(),
        ).run(const Command.detailed('no-such-executable-anywhere', elevated: true)),
        throwsA(
          isA<ElevationUnavailable>().having(
            (ElevationUnavailable refused) => refused.message,
            'message',
            allOf(contains('no-such-executable-anywhere'), contains('has to run as root')),
          ),
        ),
      );
    });

    test('may also be one that only looks at the machine', () {
      // The pair the shorthand cannot write. A check that needs root to see what it is looking at
      // stays observing, so a dry run still performs it.
      const Command looking = Command.detailed('a-tool', observes: true, elevated: true);

      expect(looking.observes, isTrue);
      expect(looking.elevated, isTrue);
    });

    test('is let through by a dry run exactly because it observes', () async {
      final FakeShell inner = FakeShell();

      await PlanningShell(inner, step: const StepName('a_step')).run(
        const Command.detailed(
          'a-tool',
          arguments: <String>['status'],
          observes: true,
          elevated: true,
        ),
      );

      expect(inner.ran, <String>['a-tool status']);
    });

    test('is refused by a dry run when it changes something, root or not', () {
      // The counter-probe of the case above: elevation is not what the dry run decides on, so a
      // shell that let the observing one through because it was elevated would pass this too.
      final FakeShell inner = FakeShell();

      expect(
        () => PlanningShell(
          inner,
          step: const StepName('a_step'),
        ).run(const Command.detailed('a-tool', arguments: <String>['apply'], elevated: true)),
        throwsA(isA<MutationRefused>()),
      );
      expect(inner.ran, isEmpty);
    });
  });

  group('what the record says about it', () {
    test('a command that ran as root says so', () async {
      final Harness harness = Harness();
      await RecordingShell(
        harness.shell,
        recorder: harness.recorder,
        redactor: harness.redactor,
        step: const StepName('a_step'),
      ).run(const Command.detailed('a-tool', elevated: true));

      expect(harness.recorder.only<CommandStarted>().single.elevated, isTrue);
    });

    test('a command that did not says so too', () async {
      // The innocent case. A writer that hardcoded either answer would pass one of these two and
      // fail the other, and neither alone would notice.
      final Harness harness = Harness();
      await RecordingShell(
        harness.shell,
        recorder: harness.recorder,
        redactor: harness.redactor,
        step: const StepName('a_step'),
      ).run(const Command('a-tool'));

      expect(harness.recorder.only<CommandStarted>().single.elevated, isFalse);
    });

    test('the command it records is the one the step wrote', () async {
      // Not the elevating tool and its options. Those are the same every time and say nothing about
      // this run, while the command a step meant is what a reader is looking for.
      final Harness harness = Harness();
      await RecordingShell(
        harness.shell,
        recorder: harness.recorder,
        redactor: harness.redactor,
        step: const StepName('a_step'),
      ).run(const Command.detailed('a-tool', arguments: <String>['upgrade'], elevated: true));

      expect(harness.recorder.only<CommandStarted>().single.argv, <String>['a-tool', 'upgrade']);
    });
  });

  group('the variables a command was promised reach it, elevated too', () {
    // The contract says "variables added to the environment the command sees". For an elevated one
    // that was false: they were set on the SUDO process, sudo resets what it passes on, and the
    // command ran without them. Nothing refused and nothing warned — the failure appears wherever
    // the variable mattered, arbitrarily far from the line that set it.
    //
    // It is not theoretical. A package install passes DEBIAN_FRONTEND=noninteractive and runs as
    // root, so an unattended run was one config-file question away from stopping at a prompt nobody
    // would ever answer.
    test('a command with variables is run through env, as root, on the far side of the reset', () {
      const Command install = Command.detailed(
        'apt-get',
        arguments: <String>['install', '--yes', 'a-tool'],
        environment: <String, String>{'DEBIAN_FRONTEND': 'noninteractive'},
        elevated: true,
      );

      expect(elevatedArgumentsFor(install), <String>[
        ...RealShell.elevatedPrefix,
        'env',
        'DEBIAN_FRONTEND=noninteractive',
        'apt-get',
        'install',
        '--yes',
        'a-tool',
      ]);
    });

    test('THE INNOCENT NEIGHBOUR: a command with none is not run through env', () {
      // Without this, wrapping unconditionally would pass the assertion above while putting a second
      // executable in front of every elevated command on every machine, for nothing.
      const Command plain = Command.detailed(
        'apt-get',
        arguments: <String>['update'],
        elevated: true,
      );

      expect(elevatedArgumentsFor(plain), <String>[
        ...RealShell.elevatedPrefix,
        'apt-get',
        'update',
      ]);
      expect(elevatedArgumentsFor(plain), isNot(contains('env')));
    });

    test('several variables are all set, in the order the command gave them', () {
      const Command many = Command.detailed(
        'a-tool',
        environment: <String, String>{'ONE': '1', 'TWO': '2'},
        elevated: true,
      );

      final List<String> argv = elevatedArgumentsFor(many);
      // After `env` and before the executable, which is where a variable belongs and where the
      // sudo prefix's own `--prompt=` is not.
      final int from = argv.indexOf('env') + 1;
      expect(argv.sublist(from, argv.indexOf('a-tool')), <String>['ONE=1', 'TWO=2']);
    });

    test('a value that is empty is still SET, rather than dropped', () {
      // Setting a variable to nothing and leaving it unset are different states to whatever reads
      // it, and the caller asked for the first.
      const Command empty = Command.detailed(
        'a-tool',
        environment: <String, String>{'QUIET': ''},
        elevated: true,
      );

      expect(elevatedArgumentsFor(empty), contains('QUIET='));
    });
  });
}
