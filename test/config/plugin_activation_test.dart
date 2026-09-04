import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';

/// Which steps exist at all, and what happens when the configuration asks for ones that do not.
///
/// This is the earliest gate in the binary — earlier than the program loader, because it decides
/// what the loader is allowed to resolve against. Every refusal here is a refusal an operator meets
/// before anything has been looked at, so each one has to say what to do about it.
void main() {
  const StepName alpha = StepName('alpha_step');
  const StepName beta = StepName('beta_step');
  const PredicateName shared = PredicateName('is_ready');

  Registry registryWith(
    List<StepName> steps, {
    List<PredicateName> predicates = const <PredicateName>[],
  }) => Registry(
    steps: <StepName, RegisteredStep>{
      for (final StepName name in steps)
        name: RegisteredStep(
          name: name,
          source: 'lib/src/steps/${name.value}.dart:1',
          create: (Arguments arguments) =>
              RunsACommand(argv: const <String>['true'], leaves: '/tmp/${name.value}'),
        ),
    },
    predicates: <PredicateName, RegisteredPredicate>{
      for (final PredicateName name in predicates)
        name: RegisteredPredicate(
          name: name,
          source: 'lib/src/predicates/${name.value}.dart:1',
          predicate: const Says(answer: true, because: 'always'),
          describes: 'always',
        ),
    },
  );

  group('the active set', () {
    test('composes the steps of every plugin it names', () {
      final PluginSet set = PluginSet(<Plugin>[
        _FakePlugin('one', registryWith(<StepName>[alpha])),
        _FakePlugin('two', registryWith(<StepName>[beta])),
      ]);

      final Registry composed = set.activate(<String>['one', 'two']);

      expect(composed.steps.keys, containsAll(<StepName>[alpha, beta]));
    });

    test('leaves out the steps of a plugin that is compiled in but not named', () {
      final PluginSet set = PluginSet(<Plugin>[
        _FakePlugin('one', registryWith(<StepName>[alpha])),
        _FakePlugin('two', registryWith(<StepName>[beta])),
      ]);

      final Registry composed = set.activate(<String>['one']);

      // The point of activating rather than compiling in: a program file cannot reach a step that
      // nobody turned on, even though the class for it is in this very binary.
      expect(composed.step(alpha), isNotNull);
      expect(composed.step(beta), isNull);
    });

    test('refuses a name the binary was not built with, and says which it carries', () {
      final PluginSet set = PluginSet(<Plugin>[
        _FakePlugin('one', registryWith(<StepName>[alpha])),
      ]);

      expect(
        () => set.activate(<String>['nowhere']),
        throwsA(
          isA<PluginRejected>()
              .having((PluginRejected r) => r.message, 'message', contains('not compiled into'))
              // A different build is the fix, not a different line in the file, and the message has
              // to make that difference visible or the operator edits config forever.
              .having((PluginRejected r) => r.message, 'message', contains('it carries: one')),
        ),
      );
    });

    test('refuses an empty list rather than running a binary with no steps', () {
      final PluginSet set = PluginSet(<Plugin>[
        _FakePlugin('one', registryWith(<StepName>[alpha])),
      ]);

      expect(
        () => set.activate(<String>[]),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected r) => r.message,
            'message',
            contains('no plugin is active'),
          ),
        ),
      );
    });

    test('refuses two plugins claiming one step name, naming both', () {
      final PluginSet set = PluginSet(<Plugin>[
        _FakePlugin('one', registryWith(<StepName>[alpha])),
        _FakePlugin('two', registryWith(<StepName>[alpha])),
      ]);

      expect(
        () => set.activate(<String>['one', 'two']),
        throwsA(
          isA<PluginRejected>()
              .having((PluginRejected r) => r.message, 'message', contains('alpha_step'))
              .having((PluginRejected r) => r.message, 'message', contains('one and two')),
        ),
      );
    });

    test('refuses two plugins claiming one predicate name', () {
      final PluginSet set = PluginSet(<Plugin>[
        _FakePlugin('one', registryWith(<StepName>[alpha], predicates: <PredicateName>[shared])),
        _FakePlugin('two', registryWith(<StepName>[beta], predicates: <PredicateName>[shared])),
      ]);

      expect(
        () => set.activate(<String>['one', 'two']),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected r) => r.message,
            'message',
            contains('the predicate "is_ready"'),
          ),
        ),
      );
    });

    test('names every problem at once', () {
      final PluginSet set = PluginSet(<Plugin>[
        _FakePlugin('one', registryWith(<StepName>[alpha])),
      ]);

      // One error per attempt would mean one run per mistake. An operator fixing a configuration
      // learns everything it is wrong about in a single run.
      expect(
        () => set.activate(<String>['nowhere', 'nowhere', 'elsewhere']),
        throwsA(
          isA<PluginRejected>()
              .having(
                (PluginRejected r) => r.message,
                'message',
                contains('"nowhere" is activated twice'),
              )
              .having(
                (PluginRejected r) => r.message,
                'message',
                contains('"elsewhere" is not compiled'),
              ),
        ),
      );
    });
  });

  group('the configuration file', () {
    Future<Configuration> read(String yaml) {
      final FakeFiles files = FakeFiles(<String, String>{'ansiwise.yaml': yaml});
      return Configuration.load(files: files, path: 'ansiwise.yaml');
    }

    test('reads the names in the order they are written', () async {
      final Configuration configuration = await read('plugins:\n  - one\n  - other\n');

      expect(configuration.plugins, <String>['one', 'other']);
    });

    test('refuses a file that names no plugins', () {
      expect(
        read('something: else\n'),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected r) => r.message,
            'message',
            contains('names no plugins'),
          ),
        ),
      );
    });

    test('refuses a plugins key that is not a list', () {
      expect(
        read('plugins: one\n'),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected r) => r.message,
            'message',
            contains('has to be a list'),
          ),
        ),
      );
    });

    test('refuses an entry that is not a name', () {
      expect(
        read('plugins:\n  - {name: one}\n'),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected r) => r.message,
            'message',
            contains('is not a plugin name'),
          ),
        ),
      );
    });

    test('refuses a document that is not a mapping', () {
      expect(
        read('- one\n'),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected r) => r.message,
            'message',
            contains('has to be a mapping'),
          ),
        ),
      );
    });

    group('the log level it carries', () {
      // It stands here and not only on the command line, because handing this binary its
      // configuration file has to be enough — for a run somebody starts by hand, and for the same
      // program reached over the REST surface, which has no command line at all.

      test('is info when the file does not say', () async {
        expect((await read('plugins:\n  - one\n')).logLevel, LogLevel.info);
      });

      test('is any of the four the file names', () async {
        for (final LogLevel level in LogLevel.values) {
          expect((await read('log_level: ${level.name}\nplugins:\n  - one\n')).logLevel, level);
        }
      });

      test('a word that is not one of them is refused, with all four named', () {
        expect(
          read('log_level: warning\nplugins:\n  - one\n'),
          throwsA(
            isA<PluginRejected>().having(
              (PluginRejected refused) => refused.message,
              'message',
              allOf(contains('warning'), contains('debug'), contains('warn'), contains('error')),
            ),
          ),
          reason:
              'somebody who wrote a near-miss learns the word rather than that something was '
              'wrong, which is the difference between one run and three',
        );
      });
    });

    group('the gate it leaves standing', () {
      // A real run needs a clean dry run of the same input behind it. That can be turned off, and
      // the ONE way to end up without it is to have typed the word — an installation that never
      // thought about the question keeps the gate.

      test('stands where the file says nothing at all', () async {
        expect((await read('plugins:\n  - one\n')).requireDryRun, isTrue);
      });

      test('stands where a gate block says nothing about it', () async {
        // A `gate:` block naming something else must not read as a decision about this one.
        expect(
          (await read('gate:\n  something_else: false\nplugins:\n  - one\n')).requireDryRun,
          isTrue,
        );
      });

      test('stands where it is written true', () async {
        expect((await read('gate:\n  dry: true\nplugins:\n  - one\n')).requireDryRun, isTrue);
      });

      test('comes down only where somebody wrote false', () async {
        expect((await read('gate:\n  dry: false\nplugins:\n  - one\n')).requireDryRun, isFalse);
      });

      test('a value that is neither is refused, saying what false would mean', () {
        // Not coerced. "no" and "off" are what somebody reaches for, and quietly reading either as
        // false would take the gate away on a typo — the one setting where a wrong guess costs a
        // machine.
        expect(
          read('gate:\n  dry: no\nplugins:\n  - one\n'),
          throwsA(
            isA<PluginRejected>().having(
              (PluginRejected refused) => refused.message,
              'message',
              allOf(contains('gate.dry'), contains('true or false'), contains('clean dry run')),
            ),
          ),
        );
      });

      test('a gate that is not a mapping is refused rather than read past', () {
        expect(
          read('gate: false\nplugins:\n  - one\n'),
          throwsA(
            isA<PluginRejected>().having(
              (PluginRejected refused) => refused.message,
              'message',
              contains('"gate" has to be a mapping'),
            ),
          ),
          reason:
              'somebody meant to turn something off, and a key read past in silence leaves them '
              'believing they did',
        );
      });
    });

    group('the run records it keeps', () {
      // The one place an installation states how many, so no program names it and every program is
      // held to it. Before this existed nothing removed a record anywhere, and the number a machine
      // held was the number of invocations it had ever had.

      test('is the default where the file says nothing at all', () async {
        expect((await read('plugins:\n  - one\n')).retention, const RunRetention());
      });

      test('is the default where a runs block says nothing about it', () async {
        expect(
          (await read('runs:\n  something_else: 3\nplugins:\n  - one\n')).retention,
          const RunRetention(),
        );
      });

      test('is the number the file names', () async {
        expect(
          (await read('runs:\n  keep: 20\nplugins:\n  - one\n')).retention,
          const RunRetention(20),
        );
      });

      test('a bound of none is refused, saying what the number is', () {
        // Not read as "keep nothing": a machine that removed the record of the run happening on it
        // could not be asked what that run did.
        expect(
          read('runs:\n  keep: 0\nplugins:\n  - one\n'),
          throwsA(
            isA<PluginRejected>().having(
              (PluginRejected refused) => refused.message,
              'message',
              allOf(contains('runs.keep'), contains('at least one'), contains('run records')),
            ),
          ),
        );
      });

      test('a value that is not a whole number is refused rather than coerced', () {
        expect(
          read('runs:\n  keep: many\nplugins:\n  - one\n'),
          throwsA(
            isA<PluginRejected>().having(
              (PluginRejected refused) => refused.message,
              'message',
              allOf(contains('runs.keep'), contains('many')),
            ),
          ),
        );
      });

      test('a runs entry that is not a mapping is refused rather than read past', () {
        expect(
          read('runs: 20\nplugins:\n  - one\n'),
          throwsA(
            isA<PluginRejected>().having(
              (PluginRejected refused) => refused.message,
              'message',
              contains('"runs" has to be a mapping'),
            ),
          ),
        );
      });
    });
  });
}

final class _FakePlugin implements Plugin {
  const _FakePlugin(this.name, this.registry);

  @override
  final String name;

  @override
  final Registry registry;
}
