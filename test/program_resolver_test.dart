import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A program that does not add up is refused before anything is looked at.
///
/// This is where the safety a compiler cannot give across a configuration boundary is restored. A
/// program file hands a step some values and nothing about that is checked at build time; it is
/// checked here instead, and everything wrong with it is said at once.
void main() {
  Registry registry() => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'writes_a_file': (
        'x:1',
        (Arguments a) => WritesAFile(path: a.text('path'), content: a.text('content')),
      ),
    },
    arguments: <String, List<ArgumentSpec>>{
      'writes_a_file': const <ArgumentSpec>[
        ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file to write'),
        ArgumentSpec(
          name: 'content',
          kind: ArgumentKind.text,
          describes: 'what goes in it',
          required: false,
          defaultValue: '',
        ),
      ],
    },
    predicates: <String, Predicate>{
      'is_master': const Says(answer: true, because: 'the role is master'),
    },
  );

  test('an unknown step name is refused', () {
    expect(
      () => ProgramResolver(registry()).resolve(
        programOf('p', <(String, OnFailure, List<String>)>[
          ('no_such_step', OnFailure.exit, <String>[]),
        ]),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid e) => e.message,
          'message',
          contains('no step is registered under that name'),
        ),
      ),
    );
  });

  test('an unknown predicate name is refused', () {
    expect(
      () => ProgramResolver(registry()).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[
            ('writes_a_file', OnFailure.exit, <String>['no_such_condition']),
          ],
          arguments: <String, Arguments>{
            'writes_a_file': const Arguments(<String, Object>{'path': '/x'}),
          },
        ),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid e) => e.message,
          'message',
          contains('no predicate is registered under "no_such_condition"'),
        ),
      ),
    );
  });

  test('a missing required argument is refused, and the message says what it is for', () {
    expect(
      () => ProgramResolver(registry()).resolve(
        programOf('p', <(String, OnFailure, List<String>)>[
          ('writes_a_file', OnFailure.exit, <String>[]),
        ]),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid e) => e.message,
          'message',
          contains('needs the argument "path" — the file to write'),
        ),
      ),
    );
  });

  test('an argument the step does not have is refused', () {
    expect(
      () => ProgramResolver(registry()).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[('writes_a_file', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'writes_a_file': const Arguments(<String, Object>{'path': '/x', 'colour': 'blue'}),
          },
        ),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid e) => e.message,
          'message',
          contains('has no argument "colour"'),
        ),
      ),
    );
  });

  test('a value of the wrong kind is refused', () {
    expect(
      () => ProgramResolver(registry()).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[('writes_a_file', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'writes_a_file': const Arguments(<String, Object>{'path': 7}),
          },
        ),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid e) => e.message,
          'message',
          contains('"path" holds text, and was given int'),
        ),
      ),
    );
  });

  test('every problem is reported at once, not one run at a time', () {
    try {
      ProgramResolver(registry()).resolve(
        programOf('p', <(String, OnFailure, List<String>)>[
          ('no_such_step', OnFailure.exit, <String>[]),
          ('writes_a_file', OnFailure.exit, <String>['no_such_condition']),
        ]),
      );
      fail('the program must be refused');
    } on ProgramInvalid catch (refusal) {
      expect(refusal.message, contains('no step is registered'));
      expect(refusal.message, contains('needs the argument "path"'));
      expect(refusal.message, contains('no predicate is registered'));
      expect(refusal.message.split('\n'), hasLength(3));
    }
  });

  test('a program that adds up resolves, and a default fills in', () async {
    final ResolvedProgram program = ProgramResolver(registry()).resolve(
      programOf(
        'p',
        <(String, OnFailure, List<String>)>[
          ('writes_a_file', OnFailure.exit, <String>['is_master']),
        ],
        arguments: <String, Arguments>{
          'writes_a_file': const Arguments(<String, Object>{'path': '/x'}),
        },
      ),
    );

    expect(program.steps.single.registered.source, 'x:1');
    expect(program.steps.single.when.single.name.value, 'is_master');

    final Harness h = Harness();
    await h.runner.run(program: program, mode: Mode.run, header: h.header());
    expect(h.files.contents['/x'], '', reason: 'the declared default stood in');
  });

  test('a step reading an answer the program does not declare is refused', () {
    // Without this the step reaches for the answer in the middle of an installation and throws
    // there — the class of error the argument schema exists to prevent, arriving by another door.
    expect(
      () => const ProgramResolver(_readsTheDomain).resolve(
        programOf('p', <(String, OnFailure, List<String>)>[
          ('needs_the_domain', OnFailure.exit, <String>[]),
        ]),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid p) => p.message,
          'message',
          contains('reads the answer "fqdn", and this program does not declare it'),
        ),
      ),
    );
  });

  test('a step reading an answer name at runtime the program does not declare is refused', () {
    expect(
      () => const ProgramResolver(_readsAnswerName).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[('needs_an_answer_name', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'needs_an_answer_name': const Arguments(<String, Object>{'source': 'db_password'}),
          },
        ),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid p) => p.message,
          'message',
          contains(
            'the argument "source" names the answer "db_password", and this program does not declare it',
          ),
        ),
      ),
    );
  });

  test('a row binding a slot to an answer the program does not declare is refused, naming both', () {
    // THE PLANTED DEFECT. `values:` names an answer once per entry, and a resolver that looks only
    // at arguments whose WHOLE value is an answer name resolves this. What an operator then meets
    // is a refusal while the template is being filled — naming the slot, which is the half they did
    // not get wrong, on a run that has already begun.
    expect(
      () => const ProgramResolver(_bindsSlotsToAnswers).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[('fills_a_template', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'fills_a_template': const Arguments(<String, Object>{
              'values': <String, Object?>{
                'build-plane': <String, Object?>{'answer': 'build_plane'},
              },
            }),
          },
        ),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid p) => p.message,
          'message',
          allOf(contains('"build-plane"'), contains('"build_plane"'), contains('does not declare')),
        ),
      ),
      reason: 'both halves are named, because either of them can be the mistake',
    );
  });

  test('THE INNOCENT NEIGHBOUR: a binding to an answer the program declares resolves', () {
    // Without this the refusal above would mean nothing: a resolver that refused every mapping would
    // pass that test and make the mechanism unusable.
    final ResolvedProgram resolved = const ProgramResolver(_bindsSlotsToAnswers).resolve(
      programOf(
        'p',
        <(String, OnFailure, List<String>)>[('fills_a_template', OnFailure.exit, <String>[])],
        answers: const DeclaredAnswers(<ArgumentSpec>[
          ArgumentSpec(
            name: 'build_plane',
            kind: ArgumentKind.text,
            describes: 'which machine builds',
          ),
        ]),
        arguments: <String, Arguments>{
          'fills_a_template': const Arguments(<String, Object>{
            'values': <String, Object?>{
              'build-plane': <String, Object?>{'answer': 'build_plane'},
            },
          }),
        },
      ),
    );

    expect(resolved.steps, hasLength(1));
  });

  test('an entry whose value is written out names no source and is passed over', () {
    // A mapping carries data a step reads itself as well as bindings. A value standing under the
    // entry's name says nothing about where it came from, because it came from the file.
    final ResolvedProgram resolved = const ProgramResolver(_bindsSlotsToAnswers).resolve(
      programOf(
        'p',
        <(String, OnFailure, List<String>)>[('fills_a_template', OnFailure.exit, <String>[])],
        arguments: <String, Arguments>{
          'fills_a_template': const Arguments(<String, Object>{
            'values': <String, Object?>{'literal': 'a value written here'},
          }),
        },
      ),
    );

    expect(resolved.steps, hasLength(1));
  });

  test('an entry naming BOTH sources is refused, because nothing says which', () {
    // The framework owns two words and writes into one of them, so it has to know where a value
    // comes from. Two sources under one name is the case where it cannot: whichever it filled would
    // be a guess, and the other would stand in the text as its own characters for whatever reads it
    // next to take as content.
    expect(
      () => const ProgramResolver(_bindsSlotsToAnswers).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[('fills_a_template', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'fills_a_template': const Arguments(<String, Object>{
              'values': <String, Object?>{
                'nested': <String, Object?>{'answer': 'a', 'measured': 'm'},
              },
            }),
          },
        ),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid failure) => failure.message,
          'message',
          allOf(
            contains('"values" entry "nested"'),
            contains('which of them the value comes from'),
          ),
        ),
      ),
    );
  });

  test('THE INNOCENT NEIGHBOUR: a body naming neither is the STEP\'s, and is passed over', () {
    // Rows that ship carry `{answer: a, join: ","}` and `{file: ..., key: ..., split: ", "}`. The
    // properties beside a source, and a source the framework has no word for at all, belong to the
    // step that declared the mapping — reading them would put its private vocabulary in the engine.
    // test/mapping_bodies_test.dart holds the shipped rows themselves.
    expect(
      () => const ProgramResolver(_bindsSlotsToAnswers).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[('fills_a_template', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'fills_a_template': const Arguments(<String, Object>{
              'values': <String, Object?>{
                'nested': <String, Object?>{'file': '/srv/map.yaml', 'key': 'k', 'join': ','},
              },
            }),
          },
        ),
      ),
      returnsNormally,
    );
  });

  test('an entry naming a measurement of the wrong shape is refused for THAT reason', () {
    // Told that its body is neither of the two, a reader looking at a body that plainly says
    // `measured:` goes to the wrong file. The refusal names the half that is actually wrong.
    expect(
      () => const ProgramResolver(_bindsSlotsToAnswers).resolve(
        programOf(
          'p',
          <(String, OnFailure, List<String>)>[('fills_a_template', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'fills_a_template': const Arguments(<String, Object>{
              'values': <String, Object?>{
                'build-plane': <String, Object?>{'measured': 'Build.Plane'},
              },
            }),
          },
        ),
      ),
      throwsA(
        isA<ProgramInvalid>().having(
          (ProgramInvalid failure) => failure.message,
          'message',
          allOf(
            contains('"values" entry "build-plane" takes the measurement "Build.Plane"'),
            contains('that is not a measurement name'),
          ),
        ),
      ),
    );
  });

  test('a step reading an answer the program declares resolves', () {
    final ResolvedProgram resolved = const ProgramResolver(_readsTheDomain).resolve(
      programOf(
        'p',
        <(String, OnFailure, List<String>)>[('needs_the_domain', OnFailure.exit, <String>[])],
        answers: const DeclaredAnswers(<ArgumentSpec>[
          ArgumentSpec(name: 'fqdn', kind: ArgumentKind.text, describes: 'the domain'),
        ]),
      ),
    );

    expect(resolved.steps, hasLength(1));
  });
}

/// A registry holding one step, which reads one answer.
const Registry _readsTheDomain = Registry(
  steps: <StepName, RegisteredStep>{
    StepName('needs_the_domain'): RegisteredStep(
      name: StepName('needs_the_domain'),
      source: 'lib/src/steps/needs_the_domain.dart:1',
      create: _aStep,
      answers: <String>['fqdn'],
    ),
  },
  predicates: <PredicateName, RegisteredPredicate>{},
);

Step _aStep(Arguments arguments) => RunsACommand(argv: const <String>['true'], leaves: '/m');

/// A registry holding one step, which takes an answer name as an argument.
const Registry _readsAnswerName = Registry(
  steps: <StepName, RegisteredStep>{
    StepName('needs_an_answer_name'): RegisteredStep(
      name: StepName('needs_an_answer_name'),
      source: 'lib/src/steps/needs_an_answer_name.dart:1',
      create: _aStep,
      arguments: <ArgumentSpec>[
        ArgumentSpec(
          name: 'source',
          kind: ArgumentKind.answerName,
          describes: 'the answer to read',
        ),
      ],
    ),
  },
  predicates: <PredicateName, RegisteredPredicate>{},
);

/// A step taking a mapping, which is the shape a row uses to bind a slot to an answer.
const Registry _bindsSlotsToAnswers = Registry(
  steps: <StepName, RegisteredStep>{
    StepName('fills_a_template'): RegisteredStep(
      name: StepName('fills_a_template'),
      source: 'lib/src/steps/fills_a_template.dart:1',
      create: _aStep,
      arguments: <ArgumentSpec>[
        ArgumentSpec(
          name: 'values',
          kind: ArgumentKind.mapping,
          required: false,
          describes: 'which answer fills each slot of the template',
        ),
      ],
    ),
  },
  predicates: <PredicateName, RegisteredPredicate>{},
);
