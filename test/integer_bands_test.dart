import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A whole number outside what its argument can plausibly mean is refused where a wrong kind is.
///
/// Everything that reads a value before the machine reads its KIND, so `memory_kilobytes: 1`,
/// `file_mode: 511` and `timeout_seconds: 1` were each as acceptable as the value they replaced. A
/// band is the argument's own statement of what its number can stand for. These probes plant a value
/// outside one and assert the refusal, and plant a value inside it and assert there is none.
void main() {
  const IntegerBand memory = IntegerBand.between(
    least: 1048576,
    most: 17179869184,
    // The edges tell a placeholder from a machine and nothing finer. What a size is compared against
    // is what the kernel leaves after its own reservations, which is several per cent short of the
    // size printed on the part, so an edge written as a real size refuses the machines it means to
    // accept.
    because: 'a machine has at least a gibibyte of memory and at most sixteen tebibytes',
  );

  Registry registryWith(ArgumentSpec spec) => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'require_machine_size': (
        'lib/src/steps/require_machine_size.dart:1',
        (Arguments a) => RunsACommand(argv: const <String>['true'], leaves: '/tmp/size'),
      ),
    },
    arguments: <String, List<ArgumentSpec>>{
      'require_machine_size': <ArgumentSpec>[spec],
    },
  );

  Program programWith(int value) => programOf(
    'deploy-host',
    <(String, OnFailure, List<String>)>[('require_machine_size', OnFailure.exit, <String>[])],
    arguments: <String, Arguments>{
      'require_machine_size': Arguments(<String, Object>{'memory_kilobytes': value}),
    },
  );

  const ArgumentSpec banded = ArgumentSpec(
    name: 'memory_kilobytes',
    kind: ArgumentKind.integer,
    describes: 'the memory this program refuses to install on less than',
    band: memory,
  );

  group('a value outside its band', () {
    test('is refused, naming the row, the argument, the band and the reason for its edges', () {
      expect(
        () => ProgramResolver(registryWith(banded)).resolve(programWith(1)),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            contains(
              'deploy-host[0] require_machine_size: "memory_kilobytes" holds a whole number from '
              '1048576 to 17179869184, and was given 1 — a machine has at least a gibibyte of '
              'memory and at most sixteen tebibytes',
            ),
          ),
        ),
      );
    });

    test('is refused above the band as well as below it', () {
      expect(
        () => ProgramResolver(registryWith(banded)).resolve(programWith(20000000000)),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            contains('and was given 20000000000'),
          ),
        ),
      );
    });

    test('is not reported where the value is inside', () {
      expect(
        ProgramResolver(registryWith(banded)).resolve(programWith(4194304)).steps,
        hasLength(1),
      );
    });
  });

  group('an argument with no plausible band', () {
    const ArgumentSpec unbanded = ArgumentSpec(
      name: 'memory_kilobytes',
      kind: ArgumentKind.integer,
      describes: 'the memory this program refuses to install on less than',
      band: IntegerBand.none(because: 'nothing about this number is implausible'),
    );

    test('accepts any whole number', () {
      expect(ProgramResolver(registryWith(unbanded)).resolve(programWith(1)).steps, hasLength(1));
    });

    test('has to SAY so: a step declaring a number and no band is refused at composition', () {
      const ArgumentSpec silent = ArgumentSpec(
        name: 'memory_kilobytes',
        kind: ArgumentKind.integer,
        describes: 'the memory this program refuses to install on less than',
      );

      expect(
        () => PluginSet(<Plugin>[
          _OnePlugin('host', registryWith(silent)),
        ]).activate(<String>['host']),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected e) => e.message,
            'message',
            contains(
              'the step "require_machine_size" declares the whole number "memory_kilobytes" and '
              'says nothing about what it can plausibly mean — give it an IntegerBand, or state '
              'IntegerBand.none with the reason there is no plausible band',
            ),
          ),
        ),
      );
    });

    test('composes once it says so', () {
      expect(
        PluginSet(<Plugin>[
          _OnePlugin('host', registryWith(unbanded)),
        ]).activate(<String>['host']).steps,
        hasLength(1),
      );
    });
  });

  test('the same band holds what a generic condition is told', () {
    final Registry registry = Registry(
      steps: const <StepName, RegisteredStep>{},
      predicates: <PredicateName, RegisteredPredicate>{
        const PredicateName('port_answers'): RegisteredPredicate.taking(
          name: const PredicateName('port_answers'),
          source: 'lib/src/conditions/port_answers.dart:1',
          create: (Arguments values) => const Says(answer: true, because: 'it does'),
          describes: 'whether something answers on that port',
          arguments: const <ArgumentSpec>[
            ArgumentSpec(
              name: 'port',
              kind: ArgumentKind.integer,
              describes: 'the port to knock on',
              band: IntegerBand.between(
                least: 1,
                most: 65535,
                because:
                    'a TCP port number is one of sixty-five thousand five hundred and thirty '
                    'five, and the protocol has no others',
              ),
            ),
          ],
        ),
      },
    );

    expect(
      () => bindConditions(
        registry: registry,
        named: <String, ConditionBinding>{
          'manager_answers': const ConditionBinding(
            predicate: 'port_answers',
            values: <String, Object>{'port': 70000},
          ),
        },
        where: 'ansiwise.yaml',
      ),
      throwsA(
        isA<PluginRejected>().having(
          (PluginRejected e) => e.message,
          'message',
          contains('"port" holds a whole number from 1 to 65535, and was given 70000'),
        ),
      ),
    );
  });
}

final class _OnePlugin implements Plugin {
  const _OnePlugin(this.name, this.registry);

  @override
  final String name;

  @override
  final Registry registry;
}
