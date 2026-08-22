import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A step publishes what it measured, and a later row takes it — with what that costs said out loud.
///
/// The cost is the whole reason this is written down rather than assumed. A value measured while the
/// run is going cannot be in the fingerprint the gate spoke on, because the fingerprint is built
/// before the first step runs. So three things have to be true at once, and a design that did two of
/// them would be worse than none: the dry run says the value is not known yet and which row will
/// produce it, the record counts such a row as declared rather than proven, and the material the
/// fingerprint is made of states the WIRING so two runs wired differently cannot share a hash.
void main() {
  const MeasurementName backend = MeasurementName('host.backend');
  const MeasurementName other = MeasurementName('host.resolvers');

  Registry registry({
    MeasurementName publishes = backend,
    String measures = '/etc/measured',
    Object? contentDefault,
  }) => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'measures': (
        'x:1',
        (Arguments a) => MeasuresAndPublishes(file: measures, publishes: publishes),
      ),
      'measures_too': (
        'x:2',
        (Arguments a) => MeasuresAndPublishes(file: '/etc/second', publishes: publishes),
      ),
      'writes': ('x:3', WritesWhatItWasGiven.fromArguments),
      'needs_it_built': ('x:4', NeedsItsValueToBeBuilt.fromArguments),
    },
    arguments: <String, List<ArgumentSpec>>{
      'writes': <ArgumentSpec>[
        const ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file it writes'),
        ArgumentSpec(
          name: 'content',
          kind: ArgumentKind.text,
          describes: 'what goes in it',
          required: false,
          defaultValue: contentDefault,
        ),
        const ArgumentSpec(
          name: 'how_many',
          kind: ArgumentKind.integer,
          describes: 'a value of another kind',
          required: false,
        ),
        const ArgumentSpec(
          name: 'token',
          kind: ArgumentKind.text,
          describes: 'a credential',
          required: false,
          secret: true,
        ),
      ],
      'needs_it_built': NeedsItsValueToBeBuilt.arguments,
    },
    publishes: <String, List<MeasurementSpec>>{
      'measures': <MeasurementSpec>[
        MeasurementSpec(
          name: publishes,
          describes: 'what the machine says it filters packets with',
        ),
      ],
      'measures_too': <MeasurementSpec>[
        MeasurementSpec(name: publishes, describes: 'the same name, from a second row'),
      ],
    },
  );

  /// The two-row program this is all about: one row measures, the next takes what it measured.
  Program measureThenWrite({
    String reading = 'writes',
    String argument = 'content',
    MeasurementName measurement = backend,
    List<String> publisherWhen = const <String>[],
    List<String> readerWhen = const <String>[],
    OnFailure onFailure = OnFailure.exit,
    List<String> rows = const <String>['measures', 'writes'],
  }) => programOf(
    'p',
    <(String, OnFailure, List<String>)>[
      for (final String row in rows) (row, onFailure, row == reading ? readerWhen : publisherWhen),
    ],
    arguments: <String, Arguments>{
      'writes': const Arguments(<String, Object>{'path': '/etc/thing'}),
    },
    reads: <String, Map<String, MeasurementName>>{
      reading: <String, MeasurementName>{argument: measurement},
    },
  );

  group('a step publishes what it measured, and a later row takes it', () {
    test('the value the machine gave reaches the row that names it', () async {
      final Harness h = Harness();
      h.files.contents['/etc/measured'] = 'legacy\n';
      final ResolvedProgram program = ProgramResolver(registry()).resolve(measureThenWrite());

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.files.contents['/etc/thing'], 'legacy');
      expect(record.steps.last.verdict, isA<Succeeded>());
    });

    test('the row that took it is DECLARED, and the run is not fully proven', () async {
      final Harness h = Harness();
      h.files.contents['/etc/measured'] = 'legacy\n';
      final ResolvedProgram program = ProgramResolver(registry()).resolve(measureThenWrite());

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.first.standing, StepStanding.proven, reason: 'the row that measured did');
      expect(record.steps.last.standing, StepStanding.declared);
      expect(record.standings, const Standings(proven: 1, declared: 1));
      expect(record.fullyProven, isFalse);
      expect(record.waived, isEmpty, reason: 'nobody waived anything — the gate was not skipped');
    });

    test('the record says WHY that row is not proven, at any log level', () async {
      final Harness h = Harness();
      h.files.contents['/etc/measured'] = 'legacy\n';
      final ResolvedProgram program = ProgramResolver(registry()).resolve(measureThenWrite());

      // The quietest level a run can be configured to write. The reason a row is not proven is not a
      // step talking, and a threshold must not be able to take it out of the record.
      await Runner(
        machine: h.machine,
        recorder: h.recorder,
        redactor: h.redactor,
        logLevel: LogLevel.error,
      ).run(program: program, mode: Mode.run, header: h.header());

      final Iterable<Log> said = h.recorder.events.whereType<Log>();
      expect(
        said.map((Log each) => each.message),
        contains(
          '"content" holds the measurement "host.backend", taken by step 1 measures during this '
          'run — a value measured while the run happens was not in the fingerprint the gate spoke '
          'on, so this row is declared rather than proven',
        ),
      );
      expect(said.single.step, const StepName('writes'));
    });

    test(
      'a step may take its value while a condition it shares with the publisher holds',
      () async {
        final Harness h = Harness();
        h.files.contents['/etc/measured'] = 'legacy\n';
        final ResolvedProgram program =
            ProgramResolver(
              registryOf(
                steps: <String, (String, Step Function(Arguments))>{
                  'measures': (
                    'x:1',
                    (Arguments a) =>
                        const MeasuresAndPublishes(file: '/etc/measured', publishes: backend),
                  ),
                  'writes': ('x:3', WritesWhatItWasGiven.fromArguments),
                },
                predicates: <String, Predicate>{
                  'is_a_master': const Says(answer: true, because: 'this machine is a master'),
                },
                arguments: <String, List<ArgumentSpec>>{'writes': WritesWhatItWasGiven.arguments},
                publishes: <String, List<MeasurementSpec>>{
                  'measures': const <MeasurementSpec>[
                    MeasurementSpec(name: backend, describes: 'the backend'),
                  ],
                },
              ),
            ).resolve(
              measureThenWrite(
                publisherWhen: <String>['is_a_master'],
                readerWhen: <String>['is_a_master'],
              ),
            );

        await h.runner.run(program: program, mode: Mode.run, header: h.header());

        expect(h.files.contents['/etc/thing'], 'legacy');
      },
    );
  });

  group('the dry run names every row whose value it cannot know yet', () {
    test('the plan says the value is not known and which row will produce it', () async {
      final Harness h = Harness();
      h.files.contents['/etc/measured'] = 'legacy\n';
      final ResolvedProgram program = ProgramResolver(registry()).resolve(measureThenWrite());

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(record.steps.last.plan, isA<NotKnownYetPlan>());
      expect(
        record.steps.last.plan?.summary,
        'not known yet: "content" holds the measurement "host.backend", which step 1 measures '
        'takes while the run happens',
      );
      expect(
        h.recorder.events.whereType<Planned>().last.plan.summary,
        record.steps.last.plan?.summary,
        reason: 'what the record holds and what a client watching the run reads are one sentence',
      );
    });

    test('nothing is asked of that row, so nothing is written and nothing is claimed', () async {
      final Harness h = Harness();
      h.files.contents['/etc/measured'] = 'legacy\n';
      final ResolvedProgram program = ProgramResolver(registry()).resolve(measureThenWrite());

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.dry,
        header: h.header(mode: Mode.dry),
      );

      expect(h.files.written, isEmpty);
      expect(record.steps.last.standing, StepStanding.declared);
      expect(record.fullyProven, isFalse);
      expect(
        record.clean,
        isTrue,
        reason: 'the dry run still counts as one — it says what it could not know, it did not fail',
      );
    });

    test('a test says the same and produces no plan, because a test plans nothing', () async {
      final Harness h = Harness();
      h.files.contents['/etc/measured'] = 'legacy\n';
      final ResolvedProgram program = ProgramResolver(registry()).resolve(measureThenWrite());

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.test,
        header: h.header(mode: Mode.test),
      );

      expect(record.steps.last.plan, isNull);
      expect(record.steps.last.standing, StepStanding.declared);
      expect(
        h.recorder.events
            .whereType<Log>()
            .where((Log each) => each.step == const StepName('writes'))
            .map((Log each) => each.message)
            .single,
        startsWith('not known yet: "content" holds the measurement "host.backend"'),
      );
    });

    test('the plan survives the record being written and read back', () {
      const RecordCodec codec = RecordCodec();
      const StepPlan plan = StepPlan.notKnownYet('"content" holds the measurement "host.backend"');

      final StepPlan read = codec.stepPlanFrom(codec.stepPlan(plan));

      expect(read, isA<NotKnownYetPlan>());
      expect(read.summary, plan.summary);
    });
  });

  group('a row taking a name nothing provides is refused at resolution', () {
    test('a name no row of this program publishes', () {
      expect(
        () => ProgramResolver(registry()).resolve(measureThenWrite(measurement: other)),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            allOf(
              contains('takes "content" from the measurement "host.resolvers"'),
              contains('no step of this program publishes it'),
              contains('this program publishes host.backend'),
            ),
          ),
        ),
      );
    });

    test('a name published by a row that runs later', () {
      expect(
        () => ProgramResolver(
          registry(),
        ).resolve(measureThenWrite(rows: const <String>['writes', 'measures'])),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            allOf(
              contains('step 2 measures publishes it'),
              contains('that row runs after this one'),
            ),
          ),
        ),
      );
    });

    test('a name two rows publish, because nothing would say which value arrived', () {
      expect(
        () => ProgramResolver(
          registry(),
        ).resolve(measureThenWrite(rows: const <String>['measures', 'measures_too', 'writes'])),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            allOf(
              contains('is published by step 1 measures and step 2 measures_too'),
              contains('nothing says which value a row taking it would get'),
            ),
          ),
        ),
      );
    });

    test('a publisher a condition may skip while the row taking it runs', () {
      final Registry registered = registryOf(
        steps: <String, (String, Step Function(Arguments))>{
          'measures': (
            'x:1',
            (Arguments a) => const MeasuresAndPublishes(file: '/etc/measured', publishes: backend),
          ),
          'writes': ('x:3', WritesWhatItWasGiven.fromArguments),
        },
        predicates: <String, Predicate>{
          'is_a_master': const Says(answer: true, because: 'this machine is a master'),
        },
        arguments: <String, List<ArgumentSpec>>{'writes': WritesWhatItWasGiven.arguments},
        publishes: <String, List<MeasurementSpec>>{
          'measures': const <MeasurementSpec>[
            MeasurementSpec(name: backend, describes: 'the backend'),
          ],
        },
      );

      expect(
        () => ProgramResolver(
          registered,
        ).resolve(measureThenWrite(publisherWhen: <String>['is_a_master'])),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            allOf(
              contains('publishes it only when is_a_master holds'),
              contains('the value may be missing exactly when this row runs'),
            ),
          ),
        ),
      );
    });

    test('an argument the step does not declare', () {
      expect(
        () => ProgramResolver(registry()).resolve(measureThenWrite(argument: 'nowhere')),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            contains('this step has no argument "nowhere"'),
          ),
        ),
      );
    });

    test('an argument that does not hold text', () {
      expect(
        () => ProgramResolver(registry()).resolve(measureThenWrite(argument: 'how_many')),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            contains('"how_many" holds integer — a measurement is text'),
          ),
        ),
      );
    });

    test('a SECRET argument filled from a measurement that is not secret', () {
      // The one thing that hides a value which did not exist before the run is the sink registering
      // it where it is published, and only a measurement DECLARED secret is registered. An argument
      // the program calls secret and fills from an unregistered value would tell every reader the
      // value is hidden while the record carried it in the clear.
      expect(
        () => ProgramResolver(registry()).resolve(measureThenWrite(argument: 'token')),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            allOf(
              contains('"token" is secret while that measurement is not'),
              contains('Declare both or neither'),
            ),
          ),
        ),
      );
    });

    test('a step that cannot be built while the value does not exist yet', () {
      expect(
        () => ProgramResolver(registry()).resolve(
          measureThenWrite(
            reading: 'needs_it_built',
            rows: const <String>['measures', 'needs_it_built'],
          ),
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            allOf(
              contains('takes a value from a measurement and cannot be built without it'),
              contains('Read that argument as an optional one'),
            ),
          ),
        ),
      );
    });

    test('an argument the step REQUIRES is not missing when the row says it is measured', () {
      // The row has decided where the value comes from, and it comes from somewhere the argument
      // check cannot see. Reported as missing, it would send an operator to write a value on a row
      // that already says where its value comes from.
      final Registry required = registryOf(
        steps: <String, (String, Step Function(Arguments))>{
          'measures': (
            'x:1',
            (Arguments a) => const MeasuresAndPublishes(file: '/etc/measured', publishes: backend),
          ),
          'writes': ('x:3', WritesWhatItWasGiven.fromArguments),
        },
        arguments: <String, List<ArgumentSpec>>{
          'writes': const <ArgumentSpec>[
            ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file it writes'),
            ArgumentSpec(name: 'content', kind: ArgumentKind.text, describes: 'what goes in it'),
          ],
        },
        publishes: <String, List<MeasurementSpec>>{
          'measures': const <MeasurementSpec>[
            MeasurementSpec(name: backend, describes: 'the backend'),
          ],
        },
      );

      expect(
        ProgramResolver(
          required,
        ).resolve(measureThenWrite()).steps.last.measured.single.measurement,
        backend,
      );
    });

    test('a program-wide default for an argument every row measures fills nothing', () {
      // The row that names a measurement has decided where its value comes from, so the block does
      // not reach past it — and a block entry that fills no row at all is dead config, refused with
      // the program rather than left in the file looking like it decides something.
      expect(
        () => ProgramResolver(registry()).resolve(
          programOf(
            'p',
            const <(String, OnFailure, List<String>)>[
              ('measures', OnFailure.exit, <String>[]),
              ('writes', OnFailure.exit, <String>[]),
            ],
            arguments: <String, Arguments>{
              'writes': const Arguments(<String, Object>{'path': '/etc/thing'}),
            },
            reads: const <String, Map<String, MeasurementName>>{
              'writes': <String, MeasurementName>{'content': backend},
            },
            defaults: const Arguments(<String, Object>{'content': 'nft'}),
          ),
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message,
            'message',
            contains('every row that takes "content" writes its own'),
          ),
        ),
      );
    });

    test('every problem at once, never the first', () {
      expect(
        () => ProgramResolver(registry()).resolve(
          programOf(
            'p',
            const <(String, OnFailure, List<String>)>[
              ('measures', OnFailure.exit, <String>[]),
              ('writes', OnFailure.exit, <String>[]),
            ],
            arguments: <String, Arguments>{
              'writes': const Arguments(<String, Object>{'path': '/etc/thing'}),
            },
            reads: const <String, Map<String, MeasurementName>>{
              'writes': <String, MeasurementName>{
                'content': other,
                'how_many': backend,
                'token': backend,
              },
            },
          ),
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid e) => e.message.split('\n').length,
            'one line per problem',
            3,
          ),
        ),
      );
    });
  });

  group('a value that was never published stands in for nothing', () {
    test('the row taking it refuses, and names the row that owed it', () async {
      final Harness h = Harness();
      // The file the first row reads is not there, so it blocks and publishes nothing. The program
      // says to carry on, which is what puts the second row in front of a missing value.
      final ResolvedProgram program = ProgramResolver(
        registry(),
      ).resolve(measureThenWrite(onFailure: OnFailure.continueRun));

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.files.written, isEmpty, reason: 'nothing was written from a value nobody measured');
      expect(record.steps.last.verdict, isA<Failed>());
      expect(
        (record.steps.last.verdict as Failed).reason,
        'the measurement "host.backend" was never published, so "content" has no value — step 1 '
        'measures produces it, and it did not',
      );
      expect(record.steps.last.standing, StepStanding.declared);
    });
  });

  group('a step publishes what it declares, and only what it read', () {
    test('a name the registry entry does not declare is refused', () {
      final Measurements taken = Measurements(Redactor.none);
      final MeasurementSink sink = taken.forStep(
        const StepName('measures'),
        const <MeasurementSpec>[MeasurementSpec(name: backend, describes: 'the backend')],
      );

      expect(
        () => sink.publish(other, 'something'),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            contains('publishes what its registry entry declares, and it declares host.backend'),
          ),
        ),
      );
      expect(taken.valueOf(other), isNull);
    });

    test('an empty reading is refused, because nothing read is not a value', () {
      final Measurements taken = Measurements(Redactor.none);
      final MeasurementSink sink = taken.forStep(
        const StepName('measures'),
        const <MeasurementSpec>[MeasurementSpec(name: backend, describes: 'the backend')],
      );

      expect(
        () => sink.publish(backend, ''),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            contains('cannot tell an empty reading from a missing one'),
          ),
        ),
      );
      expect(taken.valueOf(backend), isNull);
    });

    test('a context that is not part of a run collects nothing and says so', () {
      expect(
        () => MeasurementSink.none.publish(backend, 'legacy'),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message.toString(),
            'message',
            contains('this context is not part of a run'),
          ),
        ),
      );
    });
  });

  group('the fingerprint states the wiring, so two runs wired differently differ', () {
    String hashOf(ResolvedProgram program) =>
        fingerprintOf(program: program, commit: 'abc1234', answers: Arguments.none);

    /// The same row written twice: once taking its value from a measurement, once left blank.
    ///
    /// This is the pair the wiring has to tell apart. Both write nothing for the argument, so a
    /// material that did not carry the wiring would hash them alike — and one of them takes a value
    /// off the machine while the other runs on the step's own default.
    Program blankOrWired({required bool wired}) => programOf(
      'p',
      const <(String, OnFailure, List<String>)>[
        ('measures', OnFailure.exit, <String>[]),
        ('writes', OnFailure.exit, <String>[]),
      ],
      arguments: <String, Arguments>{
        'writes': const Arguments(<String, Object>{'path': '/etc/thing'}),
      },
      reads: wired
          ? const <String, Map<String, MeasurementName>>{
              'writes': <String, MeasurementName>{'content': backend},
            }
          : const <String, Map<String, MeasurementName>>{},
    );

    test('a row taking a measurement hashes unlike the same row given nothing', () {
      expect(
        hashOf(ProgramResolver(registry()).resolve(blankOrWired(wired: true))),
        isNot(hashOf(ProgramResolver(registry()).resolve(blankOrWired(wired: false)))),
      );
    });

    test('a row taking a measurement hashes unlike the same row given a value', () {
      final String wired = hashOf(ProgramResolver(registry()).resolve(measureThenWrite()));
      final String written = hashOf(
        ProgramResolver(registry()).resolve(
          programOf(
            'p',
            const <(String, OnFailure, List<String>)>[
              ('measures', OnFailure.exit, <String>[]),
              ('writes', OnFailure.exit, <String>[]),
            ],
            arguments: <String, Arguments>{
              'writes': const Arguments(<String, Object>{
                'path': '/etc/thing',
                'content': 'host.backend',
              }),
            },
          ),
        ),
      );

      expect(wired, isNot(written));
    });

    test('the same argument wired to another measurement hashes differently', () {
      final String toBackend = hashOf(ProgramResolver(registry()).resolve(measureThenWrite()));
      final String toOther = hashOf(
        ProgramResolver(registry(publishes: other)).resolve(measureThenWrite(measurement: other)),
      );

      expect(toBackend, isNot(toOther));
    });

    test('the same program hashes differently when another ROW produces the value', () {
      // THE CASE THE WHOLE WIRING FIELD EXISTS FOR, and the only one where nothing else in the
      // material moves. One binary has the first row publish the name and the second row publish
      // nothing; the other binary has it the other way round. The program file is the same file,
      // its rows are the same rows in the same order with the same arguments — and the value the
      // last row acts on comes off a different step. Without the producing row in the material the
      // two hash alike, and a dry run of one would admit a real run of the other.
      Registry publishedBy(String row) => registryOf(
        steps: <String, (String, Step Function(Arguments))>{
          'measures': (
            'x:1',
            (Arguments a) => const MeasuresAndPublishes(file: '/etc/measured', publishes: backend),
          ),
          'measures_too': (
            'x:2',
            (Arguments a) => const MeasuresAndPublishes(file: '/etc/second', publishes: backend),
          ),
          'writes': ('x:3', WritesWhatItWasGiven.fromArguments),
        },
        arguments: <String, List<ArgumentSpec>>{'writes': WritesWhatItWasGiven.arguments},
        publishes: <String, List<MeasurementSpec>>{
          row: const <MeasurementSpec>[MeasurementSpec(name: backend, describes: 'the backend')],
        },
      );

      final Program program = measureThenWrite(
        rows: const <String>['measures', 'measures_too', 'writes'],
      );

      expect(
        hashOf(ProgramResolver(publishedBy('measures')).resolve(program)),
        isNot(hashOf(ProgramResolver(publishedBy('measures_too')).resolve(program))),
      );
    });

    test('the step default of a wired argument is not in the material', () {
      // The default is what lets the row be examined before the run; it is not what the step runs
      // with. A fingerprint carrying it would say the gate had seen a value it never sees.
      final String withoutDefault = hashOf(ProgramResolver(registry()).resolve(measureThenWrite()));
      final String withDefault = hashOf(
        ProgramResolver(registry(contentDefault: 'nft')).resolve(measureThenWrite()),
      );

      expect(withDefault, withoutDefault);
    });
  });

  group('a row taking a measurement can still be examined before the run', () {
    test('the boundary a run cannot be taken back past still names it', () {
      // The point of no return is built by BUILDING every step, because only an instance says
      // whether it can be undone. A row whose value does not exist yet is exactly the row that
      // could take that sentence away from the operator, and the resolver is what stops it.
      final ResolvedProgram program = ProgramResolver(registry()).resolve(
        programOf(
          'p',
          const <(String, OnFailure, List<String>)>[
            ('measures', OnFailure.exit, <String>[]),
            ('writes', OnFailure.exit, <String>[]),
          ],
          arguments: <String, Arguments>{
            'writes': const Arguments(<String, Object>{'path': '/etc/thing'}),
          },
          reads: const <String, Map<String, MeasurementName>>{
            'writes': <String, MeasurementName>{'content': backend},
          },
          undoOff: const <String>{'writes'},
        ),
      );

      expect(
        pointOfNoReturnSaid(program),
        'from step 2 of 2, writes, this run cannot be taken back: this program says undo: false '
        'for this step, so what it does stands even though the step could take it back',
      );
    });
  });

  // WHAT THE CLIENT IS TOLD ABOUT SUCH A ROW is not measured here, and this comment used to name a
  // suite that measures it — ansiwise-rest/test/rest/measured_values_over_the_wire_test.dart, which
  // has never existed in any repository. What the endpoints answer is covered by the suites under
  // ansiwise-cli/test/rest/, and whether a measured value reaches a caller UNDER THAT NAME is
  // covered by none of them.
}
