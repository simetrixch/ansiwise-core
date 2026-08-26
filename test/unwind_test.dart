import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// What a failed run takes back, and what it deliberately does not.
///
/// A machine cannot be rolled back — there is no transaction around installing a package. What is
/// achievable is compensation, and it is only safe if it is narrow: only steps that actually ran,
/// only steps that said how, in reverse.
void main() {
  ResolvedProgram twoWritesThenAFailure() =>
      ProgramResolver(
        registryOf(
          steps: <String, (String, Step Function(Arguments))>{
            'first': ('x:1', (Arguments a) => WritesAFile(path: '/one', content: '1')),
            'second': ('x:2', (Arguments a) => WritesAFile(path: '/two', content: '2')),
            'fails': ('x:3', (Arguments a) => const Blocks('the disk went away')),
          },
        ),
      ).resolve(
        programOf('p', <(String, OnFailure, List<String>)>[
          ('first', OnFailure.exit, <String>[]),
          ('second', OnFailure.exit, <String>[]),
          ('fails', OnFailure.exit, <String>[]),
        ]),
      );

  test('what was applied is taken back, newest first', () async {
    final Harness h = Harness();
    await h.runner.run(program: twoWritesThenAFailure(), mode: Mode.run, header: h.header());

    expect(h.files.deleted, <String>['/two', '/one'], reason: 'in reverse, not in order');
    expect(h.files.contents, isEmpty);
  });

  group('an unwind that was deliberately not performed', () {
    Runner refusingToUnwind(Harness h, {required String by}) => Runner(
      machine: h.machine,
      recorder: h.recorder,
      redactor: h.redactor,
      unwindDisabledBy: by,
    );

    test('leaves the changes where they are, which is the whole point of asking for it', () async {
      final Harness h = Harness();
      await refusingToUnwind(
        h,
        by: 'the --no-unwind option',
      ).run(program: twoWritesThenAFailure(), mode: Mode.run, header: h.header());

      expect(h.files.deleted, isEmpty);
      expect(h.files.contents.keys, containsAll(<String>['/one', '/two']));
    });

    test('the RECORD names every step still standing, not a log line', () async {
      // A warning among the log entries is not where somebody decides what to do to a machine
      // next. This is what that decision is read off, so it is a field of the outcome.
      final Harness h = Harness();
      final RunRecord closed = await refusingToUnwind(
        h,
        by: 'the --no-unwind option',
      ).run(program: twoWritesThenAFailure(), mode: Mode.run, header: h.header());

      expect(closed.leftStanding, <String>['first', 'second']);
      expect(closed.exitCode, 1);
    });

    test('it survives being written down and read back', () async {
      // The record on disk is what anybody looks at afterwards, and a field that only exists in
      // memory tells nobody anything.
      final Harness h = Harness();
      final RunRecord closed = await refusingToUnwind(
        h,
        by: 'the --no-unwind option',
      ).run(program: twoWritesThenAFailure(), mode: Mode.run, header: h.header());

      const RecordCodec codec = RecordCodec();
      final Map<String, Object?> written = codec.run(closed);
      expect(written['left_standing'], <String>['first', 'second']);
      expect(codec.runFrom(written).leftStanding, <String>['first', 'second']);
    });

    test('the message names the surface the decision came from', () async {
      // It used to say "--no-unwind was given" whatever had decided it, so an operator who set a
      // key in a configuration file was told about a command-line option they never typed.
      final Harness h = Harness();
      await refusingToUnwind(
        h,
        by: 'no_unwind: true in ansiwise.yaml',
      ).run(program: twoWritesThenAFailure(), mode: Mode.run, header: h.header());

      expect(
        h.recorder.events.whereType<Log>().map((Log e) => e.message).join('\n'),
        allOf(contains('no_unwind: true in ansiwise.yaml'), contains('first, second')),
      );
    });

    test('the innocent neighbour: a run that DID unwind carries nothing standing', () async {
      // Without this, a version that filled the field on every failed run would pass every test
      // above and say the machine was dirty after a clean rollback.
      final Harness h = Harness();
      final RunRecord closed = await h.runner.run(
        program: twoWritesThenAFailure(),
        mode: Mode.run,
        header: h.header(),
      );

      expect(closed.leftStanding, isEmpty);
      expect(const RecordCodec().run(closed).containsKey('left_standing'), isFalse);
    });
  });

  group('a step whose apply THREW', () {
    // The contract on Step.undo says it must tolerate being called after a partial apply, "and that
    // is exactly when it matters". It used to be the one path where it was never called: an apply
    // that threw left the step's own branch entirely, and the answer that came back carried no
    // applied step — so the unwind never reached it, the capture was discarded, and what the step
    // changed before it threw stood while its kind still said it could be taken back.

    ResolvedProgram writesThenStops({bool throwsAnError = false}) =>
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'half': (
                'x:1',
                (Arguments a) =>
                    ChangesThenItsApplyThrows(path: '/half', throwsAnError: throwsAnError),
              ),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[('half', OnFailure.exit, <String>[])]),
        );

    test('is taken back, which is where it matters most', () async {
      final Harness h = Harness();
      await h.runner.run(program: writesThenStops(), mode: Mode.run, header: h.header());

      expect(h.files.written, contains('/half'), reason: 'the apply really did change something');
      expect(
        h.files.contents.containsKey('/half'),
        isFalse,
        reason: 'and the throw did not stop it being taken back',
      );
    });

    test('is taken back where the apply threw an Error and not an Exception', () async {
      // The catch beside the apply asked for an Exception, so a StateError, a cast, an index or a
      // null out of a plugin's own apply passed it, passed the catch at the top of the step as
      // well, and was caught by the runner's last one — which closes a record holding NO rows at
      // all. The write stood, the unwind never ran, and the record an operator would read it out
      // of said nothing about the step that had changed the machine.
      final Harness h = Harness();
      final RunRecord closed = await h.runner.run(
        program: writesThenStops(throwsAnError: true),
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.files.written, contains('/half'));
      expect(h.files.contents, isEmpty);
      expect(closed.steps, hasLength(1), reason: 'and the record still holds the row');
      expect((closed.steps.single.verdict as Failed).reason, contains('the second act read'));
    });
  });

  group('a throw the engine could not classify', () {
    // ONE QUESTION AT THREE CALL SITES, and the engine used to hold two answers to it. The check
    // either side of the apply answered Object; the catch beside the apply and the catch at the top
    // of the step both answered Exception, so which record an operator got depended on which of
    // them a throw happened to meet.

    test('an Error out of a CAPTURE closes the row, and takes nothing back', () async {
      // Both halves at once. The capture runs before the apply — it is the reading an undo is built
      // out of — so this row wrote nothing, and taking it back would delete a file the run found
      // already there. What used to happen is neither: the Error left the engine and the record
      // closed holding no rows about the row that refused.
      final Harness h = Harness(files: FakeFiles(<String, String>{'/kept': 'was here'}));
      final ResolvedProgram program =
          ProgramResolver(
            registryOf(
              steps: <String, (String, Step Function(Arguments))>{
                'never': (
                  'x:1',
                  (Arguments a) => ThrowsWhileCapturing(path: '/kept', throwsAnError: true),
                ),
              },
            ),
          ).resolve(
            programOf('p', <(String, OnFailure, List<String>)>[
              ('never', OnFailure.exit, <String>[]),
            ]),
          );

      final RunRecord closed = await h.runner.run(
        program: program,
        mode: Mode.run,
        header: h.header(),
      );

      expect(closed.steps, hasLength(1));
      expect(closed.steps.single.verdict, isA<Failed>());
      expect(h.files.written, isEmpty, reason: 'the row threw before it wrote anything');
      expect(h.files.deleted, isEmpty);
      expect(h.files.contents['/kept'], 'was here');
    });

    group('an Error out of an UNDO', () {
      // The throw that happens while a failed run is already cleaning up. It used to leave the
      // unwind loop entirely: every step still to be taken back stood, and the record closed with
      // no rows in it.

      ResolvedProgram twoWritesTheSecondOfWhichCannotBePutBack({bool throwsAnError = false}) =>
          ProgramResolver(
            registryOf(
              steps: <String, (String, Step Function(Arguments))>{
                'first': ('x:1', (Arguments a) => WritesAFile(path: '/one', content: '1')),
                'stuck': (
                  'x:2',
                  (Arguments a) =>
                      WritesAndItsUndoThrows(path: '/stuck', throwsAnError: throwsAnError),
                ),
                'fails': ('x:3', (Arguments a) => const Blocks('the disk went away')),
              },
            ),
          ).resolve(
            programOf('p', <(String, OnFailure, List<String>)>[
              ('first', OnFailure.exit, <String>[]),
              ('stuck', OnFailure.exit, <String>[]),
              ('fails', OnFailure.exit, <String>[]),
            ]),
          );

      test('does not stop the steps before it being taken back', () async {
        final Harness h = Harness();
        final RunRecord closed = await h.runner.run(
          program: twoWritesTheSecondOfWhichCannotBePutBack(throwsAnError: true),
          mode: Mode.run,
          header: h.header(),
        );

        expect(h.files.deleted, contains('/one'));
        expect(closed.steps, hasLength(3), reason: 'and the record still holds every row');
      });

      test('is said in the record, so the failed undo is not silent', () async {
        final Harness h = Harness();
        await h.runner.run(
          program: twoWritesTheSecondOfWhichCannotBePutBack(throwsAnError: true),
          mode: Mode.run,
          header: h.header(),
        );

        expect(
          h.recorder.logLines.where((String each) => each.startsWith('could not be taken back')),
          hasLength(1),
        );
      });

      test('THE INNOCENT NEIGHBOUR: an undo that returns is not reported as failed', () async {
        // Without this, a version that logged the refusal on every undo would pass both probes
        // above and tell an operator that a clean rollback had failed.
        final Harness h = Harness();
        await h.runner.run(program: twoWritesThenAFailure(), mode: Mode.run, header: h.header());

        expect(
          h.recorder.logLines.where((String each) => each.startsWith('could not be taken back')),
          isEmpty,
        );
        expect(h.files.contents, isEmpty);
      });
    });
  });

  group('a recorder that refuses a line', () {
    // WHAT A FULL EVENT FILE DOES TO A RUN. Every row is closed by recording it, so the write that
    // refuses is the last thing a row does — and the row's answer, which used to be where the
    // engine kept whether the step had applied, never came back. The unwind then never reached a
    // row that HAD written, and the record said the step applied nothing.

    ResolvedProgram writesThenFails() =>
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'half': ('x:1', (Arguments a) => WritesAFile(path: '/half', content: 'written')),
              'fails': ('x:2', (Arguments a) => const Blocks('the disk went away')),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('half', OnFailure.continueRun, <String>[]),
            ('fails', OnFailure.exit, <String>[]),
          ]),
        );

    Runner recordingInto(Harness h, Recorder recorder) =>
        Runner(machine: h.machine, recorder: recorder, redactor: h.redactor);

    test('leaves the row it refused still able to be taken back', () async {
      final Harness h = Harness();
      int seen = 0;
      final RefusingRecorder recorder = RefusingRecorder(
        h.recorder,
        refuses: (RunEvent event) => event is StepFinished && seen++ == 0,
      );

      await recordingInto(
        h,
        recorder,
      ).run(program: writesThenFails(), mode: Mode.run, header: h.header());

      expect(h.files.written, contains('/half'));
      expect(h.files.contents, isEmpty, reason: 'the write was taken back all the same');
    });

    test('refusing the same line a second time costs the walk nothing it already had', () async {
      // The first refusal is answered by closing the row again, which needs the recorder to have
      // recovered. A recorder that refuses every time it is asked throws out of the step entirely,
      // and everything the walk had collected — the rows before this one AND the list the unwind
      // walks — used to go with it: a machine changed by every step that had run was then neither
      // taken back nor named anywhere.
      final Harness h = Harness();
      final RefusingRecorder recorder = RefusingRecorder(
        h.recorder,
        refuses: (RunEvent event) => event is StepFinished,
      );

      final RunRecord closed = await recordingInto(
        h,
        recorder,
      ).run(program: writesThenFails(), mode: Mode.run, header: h.header());

      expect(h.files.written, contains('/half'));
      expect(h.files.contents, isEmpty, reason: 'what it wrote was still taken back');
      expect(closed.end, isNotNull, reason: 'and the header still says the run ended');
      expect(
        closed.issues.single,
        contains('half'),
        reason: 'the row that could not be closed has no row of its own, so it is said here',
      );
    });

    test('THE INNOCENT NEIGHBOUR: a recorder that refuses nothing reports no issue', () async {
      // Without this, a version that treated every row as refused would pass both probes above and
      // put an issue on a run in which nothing went wrong.
      final Harness h = Harness();
      final RefusingRecorder recorder = RefusingRecorder(
        h.recorder,
        refuses: (RunEvent event) => false,
      );

      final RunRecord closed = await recordingInto(
        h,
        recorder,
      ).run(program: writesThenFails(), mode: Mode.run, header: h.header());

      expect(closed.steps, hasLength(2));
      expect(closed.issues, isEmpty);
      expect(h.files.contents, isEmpty);
    });
  });

  group('a step whose POSTCONDITION threw', () {
    // THE ONE THROW THAT MEETS AN ALREADY-CHANGED MACHINE. The reading a real run judges a row by is
    // taken AFTER the apply, so the write stands by the time it can throw; every other place a step
    // can throw is before the write or is the write. It used to be read outside the branch that
    // keeps what an undo needs, so the throw left the step's own code entirely, the answer that came
    // back carried no applied step, and the unwind never reached the one row whose reading could not
    // confirm what it had done — while its kind went on telling the operator it could be taken back.

    ResolvedProgram writesThenCannotReadItBack(OnFailure onFailure, {bool throwsAnError = false}) =>
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'half': (
                'x:1',
                (Arguments a) =>
                    ChangesThenItsPostconditionThrows(path: '/half', throwsAnError: throwsAnError),
              ),
              'fails': ('x:2', (Arguments a) => const Blocks('the disk went away')),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('half', onFailure, <String>[]),
            ('fails', OnFailure.exit, <String>[]),
          ]),
        );

    test('is taken back, and the machine is clean after the run', () async {
      // The ticket's own scenario: the row writes, its postcondition throws, the program carries the
      // run past it, and a later row ends the run. What is asserted is the state of the machine
      // afterwards and not a list the engine keeps.
      final Harness h = Harness();
      await h.runner.run(
        program: writesThenCannotReadItBack(OnFailure.continueRun),
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.files.written, contains('/half'), reason: 'the apply really did change something');
      expect(h.files.deleted, contains('/half'));
      expect(h.files.contents, isEmpty, reason: 'nothing this run wrote is still on the machine');
    });

    test('is taken back where its own row ends the run as well', () async {
      // The same row under the other failure policy, so the unwind is triggered by this row rather
      // than by a later one. A fix that only reached the row the walk carried on past would leave
      // the more common case standing.
      final Harness h = Harness();
      await h.runner.run(
        program: writesThenCannotReadItBack(OnFailure.exit),
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.files.written, contains('/half'));
      expect(h.files.contents, isEmpty);
    });

    test('is taken back where the reading threw an Error and not an Exception', () async {
      // THE OTHER HALF OF WHAT A READING THAT DID NOT COME BACK CAN BE, and the more expensive one.
      // An Error out of a step's own code — a cast, an index, a null — passed every catch in the
      // engine and was caught by the runner's last one, which closes a record holding NO rows at
      // all: the write stood, the unwind never ran, and the record an operator would have read it
      // out of had nothing in it.
      final Harness h = Harness();
      final RunRecord closed = await h.runner.run(
        program: writesThenCannotReadItBack(OnFailure.continueRun, throwsAnError: true),
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.files.written, contains('/half'));
      expect(h.files.contents, isEmpty);
      expect(closed.steps, hasLength(2), reason: 'and the record still holds both rows');
    });

    test('is named among the rows still standing where the unwind was turned off', () async {
      // The other half of the same list. What an unwind takes back and what a run with the unwind
      // switched off REPORTS as left on the machine are read from the same applied steps, so a row
      // missing from it was invisible on both surfaces at once: the change stayed, and the record
      // an operator reads to find out what is still there did not name it.
      final Harness h = Harness();
      final RunRecord closed =
          await Runner(
            machine: h.machine,
            recorder: h.recorder,
            redactor: h.redactor,
            unwindDisabledBy: 'the --no-unwind option',
          ).run(
            program: writesThenCannotReadItBack(OnFailure.continueRun),
            mode: Mode.run,
            header: h.header(),
          );

      expect(h.files.contents.keys, contains('/half'), reason: 'nothing was taken back');
      expect(closed.leftStanding, <String>['half']);
    });

    test('fails, and is counted apart from the measured rows', () async {
      // What the row says about itself does not change: the reading a real run judges it by never
      // came back, so it is declared, and the run carried on past a failure rather than a success.
      final Harness h = Harness();
      final RunRecord record = await h.runner.run(
        program: writesThenCannotReadItBack(OnFailure.continueRun),
        mode: Mode.run,
        header: h.header(),
      );

      expect(record.steps.first.verdict, isA<Failed>());
      expect(record.steps.first.standing, StepStanding.declared);
      expect(record.fullyProven, isFalse);
    });

    test('THE INNOCENT NEIGHBOUR: a row whose CAPTURE threw is not taken back', () async {
      // Capture runs before the apply, so this row wrote nothing at all. Taking it back would put
      // the machine into a state nobody produced — this undo deletes a file the run found already
      // there. Anything that answered the rows above by handing every throw an applied step would
      // pass every one of them and delete /kept.
      final Harness h = Harness(files: FakeFiles(<String, String>{'/kept': 'was here'}));
      final ResolvedProgram program =
          ProgramResolver(
            registryOf(
              steps: <String, (String, Step Function(Arguments))>{
                'never': ('x:1', (Arguments a) => ThrowsWhileCapturing(path: '/kept')),
                'fails': ('x:2', (Arguments a) => const Blocks('the disk went away')),
              },
            ),
          ).resolve(
            programOf('p', <(String, OnFailure, List<String>)>[
              ('never', OnFailure.continueRun, <String>[]),
              ('fails', OnFailure.exit, <String>[]),
            ]),
          );

      await h.runner.run(program: program, mode: Mode.run, header: h.header());

      expect(h.files.written, isEmpty, reason: 'the row threw before it wrote anything');
      expect(h.files.deleted, isEmpty);
      expect(h.files.contents['/kept'], 'was here');
    });

    test(
      'THE SECOND INNOCENT NEIGHBOUR: a postcondition that was read is taken back too',
      () async {
        // The ordinary failing row: the postcondition answered, and the answer was that the machine
        // is not in the state the step produces. It was already taken back before this change and
        // still is, so a fix that moved the applied step from one branch to another rather than
        // adding it to one cannot pass here.
        final Harness h = Harness();
        final ResolvedProgram program =
            ProgramResolver(
              registryOf(
                steps: <String, (String, Step Function(Arguments))>{
                  'unproven': ('x:1', (Arguments a) => WritesButNeverSatisfied(path: '/unproven')),
                  'fails': ('x:2', (Arguments a) => const Blocks('the disk went away')),
                },
              ),
            ).resolve(
              programOf('p', <(String, OnFailure, List<String>)>[
                ('unproven', OnFailure.continueRun, <String>[]),
                ('fails', OnFailure.exit, <String>[]),
              ]),
            );

        final RunRecord record = await h.runner.run(
          program: program,
          mode: Mode.run,
          header: h.header(),
        );

        expect(h.files.written, contains('/unproven'));
        expect(h.files.contents, isEmpty);
        expect(
          record.steps.first.standing,
          StepStanding.proven,
          reason: 'the postcondition was read and the answer was no, which is a measurement',
        );
      },
    );
  });

  test('a step that never ran is not taken back', () async {
    final Harness h = Harness();
    final ResolvedProgram program =
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'fails': ('x:1', (Arguments a) => const Blocks('nothing here')),
              'never': ('x:2', (Arguments a) => WritesAFile(path: '/never', content: 'x')),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('fails', OnFailure.exit, <String>[]),
            ('never', OnFailure.exit, <String>[]),
          ]),
        );

    await h.runner.run(program: program, mode: Mode.run, header: h.header());

    expect(
      h.files.deleted,
      isEmpty,
      reason: 'undoing a step that never ran would be a change nobody asked for',
    );
  });

  test('a step with nothing to do is not taken back either', () async {
    final Harness h = Harness(files: FakeFiles(<String, String>{'/one': '1'}));
    final ResolvedProgram program =
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'first': ('x:1', (Arguments a) => WritesAFile(path: '/one', content: '1')),
              'fails': ('x:2', (Arguments a) => const Blocks('the disk went away')),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('first', OnFailure.exit, <String>[]),
            ('fails', OnFailure.exit, <String>[]),
          ]),
        );

    await h.runner.run(program: program, mode: Mode.run, header: h.header());

    expect(h.files.deleted, isEmpty);
    expect(h.files.contents['/one'], '1', reason: 'the file was already there and stays');
  });

  test('an irreversible step is passed over and says why', () async {
    final Harness h = Harness();
    final ResolvedProgram program =
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'irreversible': (
                'x:1',
                (Arguments a) => RunsACommand(argv: const <String>['touch', '/m'], leaves: '/m'),
              ),
              'fails': ('x:2', (Arguments a) => const Blocks('the disk went away')),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('irreversible', OnFailure.continueRun, <String>[]),
            ('fails', OnFailure.exit, <String>[]),
          ]),
        );

    // The command leaves the file behind, the way the real one would, so the step actually applies
    // and is a candidate for being taken back.
    h.shell.changes('touch /m', () => h.files.contents['/m'] = '');
    await h.runner.run(program: program, mode: Mode.run, header: h.header());

    expect(
      h.recorder.logLines,
      contains('not taken back: the command it runs does not come with a way back'),
    );
  });

  test('nothing is taken back after a dry run, because nothing was done', () async {
    final Harness h = Harness();
    await h.runner.run(
      program: twoWritesThenAFailure(),
      mode: Mode.dry,
      header: h.header(mode: Mode.dry),
    );

    expect(h.files.written, isEmpty);
    expect(h.files.deleted, isEmpty);
  });

  group('a step the program says not to take back', () {
    // The operator's own decision, and the reason it exists: a step that CAN be undone is not always
    // one that SHOULD be. Putting a configuration back over one a person has edited since is a
    // correct undo doing damage, and whether that is right here is a question about one installation
    // rather than about the step.

    ResolvedProgram withTheSecondLeftStanding() =>
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'first': ('x:1', (Arguments a) => WritesAFile(path: '/one', content: '1')),
              'second': ('x:2', (Arguments a) => WritesAFile(path: '/two', content: '2')),
              'fails': ('x:3', (Arguments a) => const Blocks('the disk went away')),
            },
          ),
        ).resolve(
          programOf(
            'p',
            <(String, OnFailure, List<String>)>[
              ('first', OnFailure.exit, <String>[]),
              ('second', OnFailure.exit, <String>[]),
              ('fails', OnFailure.exit, <String>[]),
            ],
            undoOff: <String>{'second'},
          ),
        );

    test('stands, and the unwind stops there rather than reaching past it', () async {
      // The switch is about one step; what it does to the run is not. `first` wrote /one and
      // `second` wrote /two on top of a run that already held /one, so taking /one back removes
      // ground /two was put on — and the run had already announced that `second` would stand.
      final Harness h = Harness();
      await h.runner.run(program: withTheSecondLeftStanding(), mode: Mode.run, header: h.header());

      expect(h.files.deleted, isEmpty);
      expect(h.files.contents.keys, containsAll(<String>['/one', '/two']));
    });

    test('and the record names it and everything applied before it', () async {
      final Harness h = Harness();
      final RunRecord closed = await h.runner.run(
        program: withTheSecondLeftStanding(),
        mode: Mode.run,
        header: h.header(),
      );

      expect(closed.leftStanding, <String>['first', 'second'], reason: 'in the order they ran');
    });

    test('and this run says before it starts that it cannot take that step back', () {
      final NoWayBack? boundary = pointOfNoReturn(withTheSecondLeftStanding());
      expect(boundary?.step, const StepName('second'));
      expect(
        boundary?.because,
        Irreversibility.byDecision,
        reason:
            'learning at the moment an unwind reaches the step that it will not be undone is '
            'learning it too late',
      );
    });
  });

  group('a run past its point of no return', () {
    // MEASURED ON A REAL INSTALLATION. A run said before it started that from step 8 of 88 it could
    // not be taken back, because what that step installs leaves the data it wrote behind. The run
    // failed at step 13, and its unwind then deleted the thing that data sat inside — made four
    // steps earlier, and reversible. So the data did not stay behind, and the record said two
    // things that cannot both be true: that the step was not taken back, and that what its data
    // lived in was.
    //
    // Nothing there was a step behaving badly. The step that could not be taken back stated its
    // limit correctly and the earlier one deleted exactly what it had made. It is the composition
    // that was wrong.

    ResolvedProgram aDirectoryThenSomethingIrreversibleInIt() =>
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'ground': ('x:1', (Arguments a) => WritesAFile(path: '/ground', content: 'made')),
              'irreversible': (
                'x:2',
                (Arguments a) =>
                    RunsACommand(argv: const <String>['mint'], leaves: '/ground/minted'),
              ),
              'later': ('x:3', (Arguments a) => WritesAFile(path: '/later', content: 'l')),
              'fails': ('x:4', (Arguments a) => const Blocks('the disk went away')),
            },
          ),
        ).resolve(
          programOf('p', <(String, OnFailure, List<String>)>[
            ('ground', OnFailure.exit, <String>[]),
            ('irreversible', OnFailure.exit, <String>[]),
            ('later', OnFailure.exit, <String>[]),
            ('fails', OnFailure.exit, <String>[]),
          ]),
        );

    Future<RunRecord> runIt(Harness h) {
      // The command leaves its file behind, the way the real one would, so the step really applies.
      h.shell.changes('mint', () => h.files.contents['/ground/minted'] = '');
      return h.runner.run(
        program: aDirectoryThenSomethingIrreversibleInIt(),
        mode: Mode.run,
        header: h.header(),
      );
    }

    test('does not take back what the step it could not undo was built on', () async {
      final Harness h = Harness();
      await runIt(h);

      expect(h.files.contents.keys, contains('/ground'));
      expect(
        h.files.deleted,
        isNot(contains('/ground')),
        reason: 'the run said the minted value stands, and it stands inside /ground',
      );
    });

    test('still takes back everything applied AFTER it', () async {
      // The other direction, and it is what makes stopping at the boundary safe rather than merely
      // cautious: a step that ran later cannot be holding what an earlier one wrote, so undoing it
      // takes nothing away from what stands.
      final Harness h = Harness();
      await runIt(h);

      expect(h.files.deleted, contains('/later'));
      expect(h.files.contents.containsKey('/later'), isFalse);
    });

    test('the RECORD names what is standing, so it is not only a log line', () async {
      final Harness h = Harness();
      final RunRecord closed = await runIt(h);

      expect(closed.leftStanding, <String>['ground', 'irreversible']);
    });

    test('and it says why the unwind stopped, beside the step that stopped it', () async {
      final Harness h = Harness();
      await runIt(h);

      expect(
        h.recorder.logLines.where((String each) => each.startsWith('the unwind stops here')).single,
        allOf(contains('ground'), contains('irreversible')),
      );
    });

    test('THE INNOCENT NEIGHBOUR: a run with no boundary still unwinds to the beginning', () async {
      // Without this, a version that stopped the unwind at the first step it looked at would pass
      // every probe above and take nothing back on any failed run at all.
      final Harness h = Harness();
      final RunRecord closed = await h.runner.run(
        program: twoWritesThenAFailure(),
        mode: Mode.run,
        header: h.header(),
      );

      expect(h.files.deleted, <String>['/two', '/one']);
      expect(h.files.contents, isEmpty);
      expect(closed.leftStanding, isEmpty);
      expect(
        h.recorder.logLines.where((String each) => each.startsWith('the unwind stops here')),
        isEmpty,
      );
    });
  });
}

/// A recorder that refuses to write the lines a test names, and keeps the rest.
///
/// The shape a full device has: `FileRecorder.record` hands the line to the operating system before
/// it returns, so a partition with no room left throws out of it. Which line is refused is a value
/// rather than a second class, because one refused line and a device that refuses whenever it is
/// asked are the same failure at two lengths.
final class RefusingRecorder implements Recorder {
  /// Keeps everything [kept] would have kept, except what [refuses] answers true for.
  RefusingRecorder(this.kept, {required this.refuses});

  /// Where the lines that were not refused go, so a test can read them back.
  final MemoryRecorder kept;

  /// Which lines this recorder will not write.
  final bool Function(RunEvent event) refuses;

  @override
  int get nextSequence => kept.nextSequence;

  @override
  void record(RunEvent Function(int sequence, DateTime at) build) {
    // Built once and handed on already built, because calling the builder a second time would
    // stamp the event with a second sequence number.
    final RunEvent event = build(kept.nextSequence, DateTime.utc(2026));
    if (refuses(event)) {
      throw const FileSystemException('no space left on device');
    }
    kept.events.add(event);
  }

  @override
  Future<void> close() => kept.close();
}
