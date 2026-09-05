import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A row gated on the wrong half of an opposing pair is refused when the program is resolved.
///
/// Two registered names over one reading are how this framework writes a negation, because a `not:`
/// behind `when:` would be an operator. The price of two names is that a row can be gated on the
/// wrong one and everything stays green: the row is simply skipped, the modes that change nothing
/// see nothing, and the first honest answer comes from the machine. These probes plant that swap and
/// assert the refusal, and plant the correct neighbour and assert there is none.
void main() {
  const PredicateName has = PredicateName('remote_has_branch');
  const PredicateName lacks = PredicateName('remote_lacks_branch');
  const PredicateName published = PredicateName('install_branch_published');
  const PredicateName unpublished = PredicateName('install_branch_unpublished');

  RegisteredStep stepNamed(String name, List<Sidedness> gatedOn) => RegisteredStep(
    name: StepName(name),
    source: 'lib/src/steps/$name.dart:1',
    create: (Arguments arguments) =>
        RunsACommand(argv: const <String>['true'], leaves: '/tmp/$name'),
    gatedOn: gatedOn,
  );

  RegisteredPredicate genericNamed(PredicateName name, PredicateName? opposite) =>
      RegisteredPredicate.taking(
        name: name,
        source: 'lib/src/conditions/${name.value}.dart:1',
        create: (Arguments values) => const Says(answer: true, because: 'it does'),
        describes: 'what a remote publishes',
        arguments: const <ArgumentSpec>[
          ArgumentSpec(name: 'remote', kind: ArgumentKind.text, describes: 'the remote to ask'),
        ],
        opposite: opposite,
      );

  /// The registry a program is resolved against: two generic conditions declared a pair, bound under
  /// the two names one installation chose, and three steps standing on them.
  Registry bound() => bindConditions(
    registry: Registry(
      steps: <StepName, RegisteredStep>{
        const StepName('git_branch'): stepNamed('git_branch', const <Sidedness>[
          Sidedness.only(lacks),
        ]),
        const StepName('git_checkout_branch'): stepNamed('git_checkout_branch', const <Sidedness>[
          Sidedness.only(has),
        ]),
        const StepName('git_push_credential'): stepNamed('git_push_credential', const <Sidedness>[
          Sidedness.either(has),
        ]),
        const StepName('git_fetch'): stepNamed('git_fetch', const <Sidedness>[]),
      },
      predicates: <PredicateName, RegisteredPredicate>{
        has: genericNamed(has, lacks),
        lacks: genericNamed(lacks, has),
      },
    ),
    named: <String, ConditionBinding>{
      published.value: const ConditionBinding(
        predicate: 'remote_has_branch',
        values: <String, Object>{'remote': 'origin'},
      ),
      unpublished.value: const ConditionBinding(
        predicate: 'remote_lacks_branch',
        values: <String, Object>{'remote': 'origin'},
      ),
    },
    where: 'ansiwise.yaml',
  );

  Program programWith(List<(String, String)> rows) =>
      programOf('deploy-branch', <(String, OnFailure, List<String>)>[
        for (final (String, String) row in rows) (row.$1, OnFailure.exit, <String>[row.$2]),
      ]);

  group('a swapped gate', () {
    test('is refused, naming the row, the condition and the name to write instead', () {
      expect(
        () => ProgramResolver(bound()).resolve(
          programWith(<(String, String)>[
            ('git_branch', published.value),
            ('git_checkout_branch', unpublished.value),
          ]),
        ),
        throwsA(
          isA<ProgramInvalid>()
              .having(
                (ProgramInvalid e) => e.message,
                'the cut row',
                contains(
                  'deploy-branch[0] git_branch: "install_branch_published" reads '
                  '"remote_has_branch", and this step may run only where "remote_lacks_branch" '
                  'holds — gate this row on install_branch_unpublished',
                ),
              )
              .having(
                (ProgramInvalid e) => e.message,
                'the checkout row',
                contains(
                  'deploy-branch[1] git_checkout_branch: "install_branch_unpublished" reads '
                  '"remote_lacks_branch", and this step may run only where "remote_has_branch" '
                  'holds — gate this row on install_branch_published',
                ),
              ),
        ),
      );
    });

    test('is not reported where the two are the right way round', () {
      final ResolvedProgram resolved = ProgramResolver(bound()).resolve(
        programWith(<(String, String)>[
          ('git_branch', unpublished.value),
          ('git_checkout_branch', published.value),
        ]),
      );

      expect(resolved.steps, hasLength(2));
    });
  });

  group('a step that may run on either side', () {
    test('resolves under both halves of the pair when it says so', () {
      final ResolvedProgram resolved = ProgramResolver(bound()).resolve(
        programWith(<(String, String)>[
          ('git_push_credential', unpublished.value),
          ('git_push_credential', published.value),
        ]),
      );

      expect(resolved.steps, hasLength(2));
    });

    test('has to SAY so: a step that says nothing about the pair is refused', () {
      expect(
        () => ProgramResolver(
          bound(),
        ).resolve(programWith(<(String, String)>[('git_fetch', published.value)])),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            contains(
              'deploy-branch[0] git_fetch: "install_branch_published" reads "remote_has_branch", '
              'one side of the opposing pair "remote_has_branch" and "remote_lacks_branch", and '
              'this step does not say which side of that pair it may run on',
            ),
          ),
        ),
      );
    });
  });

  group('a pair declared in one direction only', () {
    test('is refused when the plugins are composed', () {
      final PluginSet set = PluginSet(<Plugin>[
        _OnePlugin(
          'git',
          Registry(
            steps: const <StepName, RegisteredStep>{},
            predicates: <PredicateName, RegisteredPredicate>{
              has: genericNamed(has, lacks),
              lacks: genericNamed(lacks, null),
            },
          ),
        ),
      ]);

      expect(
        () => set.activate(<String>['git']),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected e) => e.message,
            'message',
            contains(
              'the condition "remote_has_branch" names "remote_lacks_branch" as its opposite, and '
              '"remote_lacks_branch" names none',
            ),
          ),
        ),
      );
    });

    test('is refused where the opposite is a name no active plugin registers', () {
      final PluginSet set = PluginSet(<Plugin>[
        _OnePlugin(
          'git',
          Registry(
            steps: const <StepName, RegisteredStep>{},
            predicates: <PredicateName, RegisteredPredicate>{has: genericNamed(has, lacks)},
          ),
        ),
      ]);

      expect(
        () => set.activate(<String>['git']),
        throwsA(
          isA<PluginRejected>().having(
            (PluginRejected e) => e.message,
            'message',
            contains(
              'the condition "remote_has_branch" names "remote_lacks_branch" as its opposite, and '
              'no active plugin registers that name',
            ),
          ),
        ),
      );
    });

    test('composes where both name each other', () {
      final PluginSet set = PluginSet(<Plugin>[
        _OnePlugin(
          'git',
          Registry(
            steps: const <StepName, RegisteredStep>{},
            predicates: <PredicateName, RegisteredPredicate>{
              has: genericNamed(has, lacks),
              lacks: genericNamed(lacks, has),
            },
          ),
        ),
      ]);

      expect(
        set.activate(<String>['git']).predicates.keys,
        containsAll(<PredicateName>[has, lacks]),
      );
    });
  });

  test('a condition with no opposite constrains nothing', () {
    final Registry registry = Registry(
      steps: <StepName, RegisteredStep>{
        const StepName('git_fetch'): stepNamed('git_fetch', const <Sidedness>[]),
      },
      predicates: <PredicateName, RegisteredPredicate>{
        const PredicateName('is_master'): const RegisteredPredicate(
          name: PredicateName('is_master'),
          source: 'lib/src/conditions/is_master.dart:1',
          predicate: Says(answer: true, because: 'the role is master'),
          describes: 'whether this machine is the master',
        ),
      },
    );

    expect(
      ProgramResolver(
        registry,
      ).resolve(programWith(<(String, String)>[('git_fetch', 'is_master')])).steps,
      hasLength(1),
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
