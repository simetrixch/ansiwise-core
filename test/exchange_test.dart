import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A call whose only effect is its answer, and the postcondition the ENGINE supplies for it.
///
/// **What an ordinary step is judged by.** `StepExecution` fails any step whose check does not answer
/// [Satisfied] after its apply, and that rule is the best thing this framework has: it is what turns
/// "the step returned without throwing" into "the step worked". A call that MINTS cannot meet it.
/// The value that comes back is the whole of what happened, so the other end holds nothing a second
/// look could find — and asking again would not be a second look but a SECOND EXCHANGE.
///
/// **What stands in its place, and only for this kind.** Where the run branch asks a step's check again, an
/// [ExchangeStep] instead has the run's measurements asked whether every name THIS ROW published now
/// holds a value. All held is a success; any missing is a failure that names it. Nothing else
/// inherits it, and the first group below is the row that proves so.
///
/// **The row is declared and never proven.** Nothing re-read the other end, and the record has to
/// say that rather than count the row among the measured ones.
void main() {
  const MeasurementName minted = MeasurementName('api_token');
  const String address = 'https://api.example/mint';

  Registry registryOfSteps({List<MeasurementSpec> mintPublishes = const <MeasurementSpec>[]}) =>
      registryOf(
        steps: <String, (String, Step Function(Arguments))>{
          'mints': ('x:1', (Arguments a) => const MintsByExchange(url: address, publishes: minted)),
          'exchanges_nothing': (
            'x:2',
            (Arguments a) => const ExchangesAndPublishesNothing(url: address),
          ),
          'claims_satisfied': ('x:3', (Arguments a) => const ExchangeThatClaimsSatisfied()),
          'tells_and_fails': (
            'x:4',
            (Arguments a) => const PublishesAndStillFailsItsCheck(publishes: minted),
          ),
        },
        publishes: <String, List<MeasurementSpec>>{
          'mints': mintPublishes.isEmpty
              ? const <MeasurementSpec>[
                  MeasurementSpec(name: minted, describes: 'the value the other end minted'),
                ]
              : mintPublishes,
          'exchanges_nothing': const <MeasurementSpec>[
            MeasurementSpec(name: minted, describes: 'the value the other end minted'),
          ],
          'claims_satisfied': const <MeasurementSpec>[
            MeasurementSpec(name: minted, describes: 'the value the other end minted'),
          ],
          'tells_and_fails': const <MeasurementSpec>[
            MeasurementSpec(name: minted, describes: 'what the other end answered'),
          ],
        },
      );

  ResolvedProgram resolve(
    String step, {
    Map<String, Map<MeasurementName, MeasurementName>> publish =
        const <String, Map<MeasurementName, MeasurementName>>{},
  }) => ProgramResolver(registryOfSteps()).resolve(
    Program(
      name: const ProgramName('p'),
      roles: const <Role>[Role('master')],
      steps: <ProgramStep>[
        ProgramStep(
          step: StepName(step),
          onFailure: OnFailure.exit,
          publish: publish[step] ?? const <MeasurementName, MeasurementName>{},
        ),
      ],
    ),
  );

  /// A run of one row, against a network that answers the mint with [answered].
  Future<RunRecord> runOne(
    String step, {
    String answered = 'fa4e-minted',
    Mode mode = Mode.run,
    Map<String, Map<MeasurementName, MeasurementName>> publish =
        const <String, Map<MeasurementName, MeasurementName>>{},
  }) async {
    final FakeHttp http = FakeHttp()..answers('POST $address', body: answered);
    final Harness h = Harness(http: http);
    return h.runner.run(
      program: resolve(step, publish: publish),
      mode: mode,
      header: h.header(mode: mode),
    );
  }

  group('the engine supplies the postcondition, and only for an exchange', () {
    test('an exchange that published what it owes succeeds', () async {
      final RunRecord record = await runOne('mints');

      expect(record.steps.single.verdict, isA<Succeeded>());
      expect(record.exitCode, 0);
    });

    test('AND ITS CHECK IS NEVER ASKED AGAIN, which is the whole of the kind', () async {
      // The measured half of "a second look is a second exchange": exactly one request leaves this
      // row. A framework that asked the step's check again would send another.
      final FakeHttp http = FakeHttp()..answers('POST $address', body: 'fa4e-minted');
      final Harness h = Harness(http: http);
      await h.runner.run(program: resolve('mints'), mode: Mode.run, header: h.header());

      expect(http.sent, <String>['POST $address']);
    });

    test(
      'THE INNOCENT NEIGHBOUR: an ordinary step that publishes still fails its own check',
      () async {
        // Without this, the softer proof would have been widened to every step in every plugin: this
        // row publishes what it declares, so an engine that read the postcondition off the published
        // names would report it green. It is not an exchange, so its own check decides — and its own
        // check does not hold.
        final RunRecord record = await runOne('tells_and_fails');

        expect(record.steps.single.verdict, isA<Failed>());
        expect(
          (record.steps.single.verdict as Failed).reason,
          'the step ran and the machine is still not in the state it produces',
        );
        expect(
          record.steps.single.standing,
          StepStanding.proven,
          reason: 'the framework measured this row failing, and it is not an exchange',
        );
      },
    );
  });

  group('an exchange that brought nothing back', () {
    test('fails, naming what it owed', () async {
      final RunRecord record = await runOne('exchanges_nothing');

      expect(record.steps.single.verdict, isA<Failed>());
      expect(
        (record.steps.single.verdict as Failed).reason,
        'the request was sent and this row published nothing under "api_token" — an exchange proves '
        'itself by the value it brings back, and there is none',
      );
    });

    test('AND IT FAILS EVEN WHERE AN EARLIER ROW ALREADY FILLED THAT NAME', () async {
      // Measurements is run-wide and cumulative: valueOf answers about the whole run, so a
      // postcondition read off it would pass this row on the strength of somebody else's value.
      // What is asked instead is what THIS row published, which is nothing.
      //
      // Driven through StepExecution rather than through a program, because the resolver refuses two
      // rows publishing one name — and this failure is exactly what would survive that refusal being
      // lifted, or a run assembled by anything other than a resolved program.
      final Harness h = Harness(http: FakeHttp()..answers('POST $address', body: 'x'));
      final Measurements taken = Measurements(h.redactor);
      taken
          .forStep(const StepName('earlier'), const <MeasurementSpec>[
            MeasurementSpec(name: minted, describes: 'the value the other end minted'),
          ])
          .publish(minted, 'a value from the row before');

      final StepOutcome outcome =
          await StepExecution(
            machine: h.machine,
            recorder: h.recorder,
            redactor: h.redactor,
          ).execute(
            resolved: resolve('exchanges_nothing').steps.single,
            mode: Mode.run,
            facts: Facts.none,
            answers: Arguments.none,
            start: h.clock.now(),
            measurements: taken,
          );

      expect(
        taken.valueOf(minted),
        'a value from the row before',
        reason: 'the run still holds the earlier value, which is what makes this trap real',
      );
      expect(outcome.record.verdict, isA<Failed>());
      expect(
        (outcome.record.verdict as Failed).reason,
        contains('published nothing under "api_token"'),
      );
    });

    test('and the postcondition follows the name the ROW publishes under, not the step\'s', () async {
      // The rename mechanism 2 built. The step publishes api_token; this row publishes it as run_id,
      // and the sink writes the row's name — so a postcondition asking for the step's name would
      // report a value missing that is there under the name the file gave it.
      final RunRecord record = await runOne(
        'mints',
        publish: const <String, Map<MeasurementName, MeasurementName>>{
          'mints': <MeasurementName, MeasurementName>{minted: MeasurementName('run_id')},
        },
      );

      expect(record.steps.single.verdict, isA<Succeeded>());
    });
  });

  group('what an exchange may never claim', () {
    test('a proven standing, on the branch that succeeded', () async {
      final RunRecord record = await runOne('mints');

      expect(record.steps.single.standing, StepStanding.declared);
      expect(record.standings, const Standings(declared: 1));
      expect(
        record.fullyProven,
        isFalse,
        reason: 'nothing re-read the other end, so no part of this run is fully proven',
      );
    });

    test('a proven standing, on the branch that failed', () async {
      final RunRecord record = await runOne('exchanges_nothing');

      expect(record.steps.single.standing, StepStanding.declared);
    });

    test('a proven standing in a mode where nothing happened', () async {
      // Every branch and every mode, because the reason does not depend on either: a dry run did not
      // re-read the other end for the same reason a real one did not.
      for (final Mode mode in <Mode>[Mode.test, Mode.dry]) {
        final RunRecord record = await runOne('mints', mode: mode);

        expect(record.steps.single.standing, StepStanding.declared, reason: 'in $mode');
      }
    });

    test('that its work already stands', () async {
      // A satisfied exchange is a check claiming to have found work already done, and the kind
      // exists to say nothing can. It is refused with what the row claimed quoted back.
      final RunRecord record = await runOne('claims_satisfied');

      expect(record.steps.single.verdict, isA<Failed>());
      expect(
        (record.steps.single.verdict as Failed).reason,
        allOf(
          contains('an exchange answered that its work already stands'),
          contains(ExchangeThatClaimsSatisfied.claimed),
        ),
      );
    });

    test('a postcondition over nothing at all', () async {
      // A kind with nothing to publish has no postcondition: every name it owes is held, because it
      // owes none. The registry audit refuses such a kind; this is the same refusal for a row that
      // reached a run anyway.
      final FakeHttp http = FakeHttp()..answers('POST $address', body: 'fa4e-minted');
      final Harness h = Harness(http: http);
      final ResolvedProgram program =
          ProgramResolver(
            registryOf(
              steps: <String, (String, Step Function(Arguments))>{
                'exchanges_nothing': (
                  'x:2',
                  (Arguments a) => const ExchangesAndPublishesNothing(url: address),
                ),
              },
            ),
          ).resolve(
            programOf('p', const <(String, OnFailure, List<String>)>[
              ('exchanges_nothing', OnFailure.exit, <String>[]),
            ]),
          );

      final RunRecord record = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.single.verdict, isA<Failed>());
      expect(
        (record.steps.single.verdict as Failed).reason,
        contains('its step publishes nothing, so there is no postcondition to hold'),
      );
    });
  });

  group('what the record says about the row', () {
    test('the reason it is declared is written down, in the row\'s own names', () async {
      final FakeHttp http = FakeHttp()..answers('POST $address', body: 'fa4e-minted');
      final Harness h = Harness(http: http);
      await h.runner.run(program: resolve('mints'), mode: Mode.run, header: h.header());

      final Iterable<Log> said = h.recorder.forStep(const StepName('mints')).whereType<Log>();
      expect(
        said.map((Log line) => line.message),
        contains(
          allOf(
            contains('this row is an exchange'),
            contains('api_token'),
            contains('a second look would be a second exchange'),
            contains('declared rather than proven'),
          ),
        ),
        reason:
            'a row standing as declared with no reason beside it states a fact and withholds the '
            'only thing that makes it readable',
      );
    });
  });

  group('an exchange cannot be taken back', () {
    test('and it moves the point of no return, with its own reason', () {
      final ResolvedProgram program = resolve('mints');

      expect(
        pointOfNoReturnSaid(program),
        'from step 1 of 1, mints, this run cannot be taken back: the other end minted a value and '
        'there is no request that unmints it',
      );
    });
  });
}
