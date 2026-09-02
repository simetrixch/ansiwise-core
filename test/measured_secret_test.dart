import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// A credential that did not exist when the run started, and the record it must not be in.
///
/// **What this is about.** A redactor fixed the moment it is built, out of the answers an operator
/// gave before anything ran, has never seen the value a step MINTS mid-run — or reads off the
/// machine — so that value goes into a world-readable file through the first surface that carries
/// it. The value is registered with the redactor at the moment it is published, by the run's own
/// sink, and every line written from there on hides it.
///
/// **How far that reaches is measured here too, because it is not everything.** A line already
/// written cannot have anything taken out of it, so a step that writes the value before it publishes
/// puts it in the record for good. The last test of the first group runs exactly that row and reads
/// both sides of the boundary.
///
/// **The test that matters is the whole record.** One row mints, the next carries the value to an
/// address, and then every line of the finished record — the event file and the header, which is
/// what an operator reads and pastes into a message — is searched for it.
void main() {
  const MeasurementName minted = MeasurementName('api_token');

  /// What [FakeEntropy] mints on its first draw of sixteen bytes, which is the credential of these
  /// runs. Written out rather than asked of the fake: a test that asked would compare the value with
  /// itself and pass over a step that published nothing.
  const String credential = 'fa4e0001000000000000000000000000';

  Registry registryOfSteps({required bool secret}) => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'mints': ('x:1', (Arguments a) => const MintsACredential(publishes: minted)),
      'sends': ('x:2', SendsACredential.fromArguments),
    },
    arguments: <String, List<ArgumentSpec>>{
      'sends': <ArgumentSpec>[
        const ArgumentSpec(name: 'url', kind: ArgumentKind.text, describes: 'where it goes'),
        ArgumentSpec(
          name: 'token',
          kind: ArgumentKind.text,
          required: false,
          // Matched against the measurement: an argument the program calls secret takes only a
          // measurement that is, and one that is not takes only one that is not.
          secret: secret,
          describes: 'the credential the request carries',
        ),
      ],
    },
    publishes: <String, List<MeasurementSpec>>{
      'mints': <MeasurementSpec>[
        MeasurementSpec(name: minted, describes: 'a credential for this run', secret: secret),
      ],
    },
  );

  Program mintThenSend() => programOf(
    'p',
    const <(String, OnFailure, List<String>)>[
      ('mints', OnFailure.exit, <String>[]),
      ('sends', OnFailure.exit, <String>[]),
    ],
    arguments: <String, Arguments>{
      'sends': const Arguments(<String, Object>{'url': 'https://api.example/things'}),
    },
    reads: const <String, Map<String, MeasurementName>>{
      'sends': <String, MeasurementName>{'token': minted},
    },
  );

  late Directory temp;
  late RunDirectory directory;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ansiwise-measured-secret-');
    directory = RunDirectory(temp.path);
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a handle open for a moment after a file is closed.
    }
  });

  /// Runs the two-row program and returns every line of the record it left behind.
  ///
  /// The record is written by [FileRecorder] with the run's own redactor, which is the same object
  /// the ports and the sink hold — the arrangement the whole mechanism rests on.
  Future<List<String>> everyLineOfTheRecord({required bool secret}) async {
    final FakeClock clock = FakeClock();
    final FakeFiles files = FakeFiles();
    final FakeHttp http = FakeHttp();
    final Redactor redactor = Redactor(const <String>[]);
    final FileRecorder recorder = await FileRecorder.open(
      id: id,
      directory: directory,
      clock: clock,
      redactor: redactor,
    );
    final ResolvedProgram program = ProgramResolver(
      registryOfSteps(secret: secret),
    ).resolve(mintThenSend());

    final RunRecord closed = await Runner(
      machine: fakeMachine(files: files, http: http, clock: clock),
      recorder: recorder,
      redactor: redactor,
    ).run(program: program, mode: Mode.run, header: _header(clock));
    await recorder.close();
    await recorder.save(closed);

    expect(
      http.sent.single,
      'POST https://api.example/things?token=$credential',
      reason: 'the request really carried the minted value, or there is nothing to hide',
    );

    return <String>[
      ...File(directory.events(id)).readAsLinesSync(),
      ...File(directory.header(id)).readAsLinesSync(),
    ].where((String line) => line.isNotEmpty).toList(growable: false);
  }

  test('the minted credential is in no line of the finished record', () async {
    final List<String> lines = await everyLineOfTheRecord(secret: true);

    expect(
      lines.where((String line) => line.contains(credential)),
      isEmpty,
      reason: 'a value minted while the run happened reached a world-readable file',
    );
    expect(
      lines.where((String line) => line.contains(Redactor.marker)),
      isNotEmpty,
      reason: 'the value was removed rather than never having been carried',
    );
  });

  test('THE INNOCENT NEIGHBOUR: the same value, not declared secret, IS in the record', () async {
    // Without this the test above would pass over a run that never carried the value at all, and a
    // clean answer would mean nobody was looking rather than that nothing got through.
    final List<String> lines = await everyLineOfTheRecord(secret: false);

    expect(lines.where((String line) => line.contains(credential)), isNotEmpty);
  });

  test('the line written BEFORE the value is published keeps it, the one after does not', () async {
    // WHAT THE REGISTRATION PROMISES, AND WHERE IT STOPS. It reaches forward: everything written
    // from the publish onwards hides the value, and nothing can be taken out of a line already
    // written. The row below writes the same credential twice, once on either side of publish(),
    // so the record says which of the two the redactor could still reach.
    //
    // Both halves are asserted. The first line still carrying the value is what stops the comment
    // beside the registration from claiming that no surface could have recorded it; the second not
    // carrying it is what says the registration works at all.
    final FakeClock clock = FakeClock();
    final Redactor redactor = Redactor(const <String>[]);
    final FileRecorder recorder = await FileRecorder.open(
      id: id,
      directory: directory,
      clock: clock,
      redactor: redactor,
    );
    final ResolvedProgram program =
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'mints': (
                'x:1',
                (Arguments a) => const MintsAndLogsBeforePublishing(publishes: minted),
              ),
            },
            publishes: <String, List<MeasurementSpec>>{
              'mints': const <MeasurementSpec>[
                MeasurementSpec(name: minted, describes: 'a credential for this run', secret: true),
              ],
            },
          ),
        ).resolve(
          programOf('p', const <(String, OnFailure, List<String>)>[
            ('mints', OnFailure.exit, <String>[]),
          ]),
        );

    final RunRecord closed = await Runner(
      machine: fakeMachine(files: FakeFiles(), http: FakeHttp(), clock: clock),
      recorder: recorder,
      redactor: redactor,
    ).run(program: program, mode: Mode.run, header: _header(clock));
    await recorder.close();
    await recorder.save(closed);

    final List<String> lines = File(directory.events(id)).readAsLinesSync();
    final String before = lines.singleWhere(
      (String line) => line.contains(MintsAndLogsBeforePublishing.beforeSaid),
    );
    final String after = lines.singleWhere(
      (String line) => line.contains(MintsAndLogsBeforePublishing.afterSaid),
    );

    expect(
      before,
      contains(credential),
      reason:
          'a line the step wrote before it published is in the record as it was written, and the '
          'registration cannot reach back into it',
    );
    expect(
      after,
      allOf(isNot(contains(credential)), contains(Redactor.marker)),
      reason: 'everything written from the publish onwards hides the value',
    );
  });

  group('an argument and the measurement that fills it agree about secrecy, or the program is '
      'refused', () {
    test('a secret argument may not take a measurement that is not secret', () {
      expect(
        () => ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'mints': ('x:1', (Arguments a) => const MintsACredential(publishes: minted)),
              'sends': ('x:2', SendsACredential.fromArguments),
            },
            arguments: <String, List<ArgumentSpec>>{'sends': SendsACredential.arguments},
            publishes: <String, List<MeasurementSpec>>{
              'mints': const <MeasurementSpec>[
                MeasurementSpec(name: minted, describes: 'a credential for this run'),
              ],
            },
          ),
        ).resolve(mintThenSend()),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid failure) => failure.message,
            'message',
            allOf(
              contains('"token" is secret while that measurement is not'),
              contains('Declare both or neither'),
            ),
          ),
        ),
      );
    });

    test('an argument that is not secret may not take a measurement that is', () {
      expect(
        () => ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'mints': ('x:1', (Arguments a) => const MintsACredential(publishes: minted)),
              'sends': ('x:2', SendsACredential.fromArguments),
            },
            arguments: <String, List<ArgumentSpec>>{
              'sends': const <ArgumentSpec>[
                ArgumentSpec(name: 'url', kind: ArgumentKind.text, describes: 'where it goes'),
                ArgumentSpec(
                  name: 'token',
                  kind: ArgumentKind.text,
                  required: false,
                  describes: 'the credential the request carries',
                ),
              ],
            },
            publishes: <String, List<MeasurementSpec>>{
              'mints': const <MeasurementSpec>[
                MeasurementSpec(name: minted, describes: 'a credential for this run', secret: true),
              ],
            },
          ),
        ).resolve(mintThenSend()),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid failure) => failure.message,
            'message',
            contains('that measurement is secret while "token" is not'),
          ),
        ),
      );
    });
  });

  group('what registering during a run does to a redactor', () {
    test('a value registered now is hidden in text written afterwards', () {
      final Redactor redactor = Redactor(const <String>[]);

      expect(redactor.hide('the key is s3cret-value'), 'the key is s3cret-value');
      redactor.register('s3cret-value');
      expect(redactor.hide('the key is s3cret-value'), 'the key is ${Redactor.marker}');
    });

    test('the longest-first order holds, so a secret inside a secret is replaced whole', () {
      final Redactor redactor = Redactor(const <String>['short-one']);

      redactor.register('short-one-and-longer');

      expect(redactor.hide('short-one-and-longer'), Redactor.marker);
    });

    test('a value too short to hide is ignored, exactly as one given at the start is', () {
      final Redactor redactor = Redactor(const <String>[]);

      redactor.register('abc');

      expect(redactor.isEmpty, isTrue);
    });

    test('the redactor that hides nothing refuses to be told to hide something', () {
      // The two ways this name could carry a mutable redactor, and why it carries neither. A fresh
      // instance per caller splits one run across two redactors, so a value registered through the
      // one the sink holds goes on being written in the clear by the one the recorder holds. A
      // single shared mutable instance carries a value registered by one run into the records of
      // every later run in the same process. Refusing removes both: there is nothing in it to leak
      // and nothing to be out of step with, and a caller that reached for it as a run's redactor is
      // told instead of finding out from the record.
      expect(
        () => Redactor.none.register('a-registered-value'),
        throwsA(
          isA<StateError>().having(
            (StateError failure) => failure.message,
            'message',
            allOf(
              contains('belongs to no run'),
              contains('hidden nowhere'),
              isNot(contains('a-registered-value')),
            ),
          ),
        ),
      );
      expect(Redactor.none.isEmpty, isTrue);
      expect(
        identical(Redactor.none, Redactor.none),
        isTrue,
        reason: 'nothing can be registered with it, so one object serves every caller',
      );
    });
  });
}

RunRecord _header(FakeClock clock) => RunRecord(
  id: id,
  program: const ProgramName('p'),
  mode: Mode.run,
  argv: const <String>['ansiwise', 'p'],
  start: clock.now(),
  stage: const Stage('dev'),
  role: const Role('master'),
  fqdn: const Fqdn('m1.example.com'),
  commit: '0000000',
  fingerprint: 'test-fingerprint',
);

const RunId id = RunId('20260817T120000Z-1');
