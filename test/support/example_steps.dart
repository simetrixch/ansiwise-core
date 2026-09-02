import 'package:ansiwise_core/ansiwise_core.dart';

/// A step that writes a file. Reversible: the undo puts back whatever was there, or deletes it when
/// there was nothing.
final class WritesAFile extends ReversibleStep<String?> with FileStep {
  WritesAFile({required this.path, required this.content});

  final String path;

  final String content;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => FileContent.text(content);

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> undo(StepContext context, String? captured) async {
    if (captured == null) {
      await context.files.delete(path);
      return;
    }
    await context.files.write(path, captured, mode: mode);
  }
}

/// A step that runs a command it declares as changing something, and whose postcondition is a file
/// the command is supposed to leave behind.
final class RunsACommand extends IrreversibleStep with CommandStep {
  RunsACommand({
    required this.argv,
    required this.leaves,
    this.secretOutput = false,
    this.elevated = false,
  });

  final List<String> argv;

  /// The file the command is supposed to produce, which is what proves it worked.
  final String leaves;

  /// Whether the command says its answer is a credential.
  ///
  /// A value and not a second class: what differs between a step that reads a secret store whole
  /// and one that runs a release tool is this flag on the command, and nothing else.
  final bool secretOutput;

  /// Whether the command has to run as root.
  ///
  /// A value for the same reason [secretOutput] is one. It puts the privilege in the WORK rather
  /// than in the reading before it: this step's check asks the file system and needs nothing, so a
  /// machine that can raise nothing to root refuses in the apply, with the check already answered.
  final bool elevated;

  @override
  String get irreversibleReason => 'the command it runs does not come with a way back';

  @override
  Command commandFor(StepContext context) => Command.detailed(
    argv.first,
    arguments: argv.sublist(1),
    secretOutput: secretOutput,
    elevated: elevated,
  );

  @override
  Future<CheckResult> check(StepContext context) async => await context.files.exists(leaves)
      ? CheckResult.satisfied('$leaves is there')
      : const CheckResult.ready();
}

/// A step that tries to change something from inside its own check.
///
/// It exists to be refused. Nothing in the framework stops a step being written this way, and that
/// is exactly why the port has to.
final class MutatesWhileChecking extends IrreversibleStep {
  const MutatesWhileChecking();

  @override
  String get irreversibleReason => 'it is only here to be refused';

  @override
  Future<CheckResult> check(StepContext context) async {
    await context.files.write('/tmp/never', 'this must not be written', mode: 0x1a4);
    return const CheckResult.ready();
  }

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('nothing');

  @override
  Future<void> apply(StepContext context) async {}
}

/// A step whose plan reaches for a command it did not declare as only looking.
final class MutatesWhilePlanning extends IrreversibleStep {
  const MutatesWhilePlanning();

  @override
  String get irreversibleReason => 'it is only here to be refused';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async {
    await context.shell.run(const Command('rm', <String>['-rf', '/']));
    return const StepPlan.nothing('nothing');
  }

  @override
  Future<void> apply(StepContext context) async {}
}

/// A step that does its work and whose postcondition never holds afterwards.
///
/// The shape of every phase the shell had that reported success over a real failure: the command
/// returns zero, and the machine is not in the state the step is supposed to produce.
final class ClaimsSuccessWithout extends IrreversibleStep {
  const ClaimsSuccessWithout();

  @override
  String get irreversibleReason => 'it is only here to fail its own postcondition';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('nothing');

  @override
  Future<void> apply(StepContext context) async {
    await context.shell.run(const Command('true'));
  }
}

/// A step that cannot run, and says which precondition is missing.
final class Blocks extends IrreversibleStep {
  const Blocks(this.reason);

  final String reason;

  @override
  String get irreversibleReason => 'it never runs';

  @override
  Future<CheckResult> check(StepContext context) async => CheckResult.blocked(reason);

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('nothing');

  @override
  Future<void> apply(StepContext context) async {}
}

/// A gate that reads the machine with a command that has to run as root.
///
/// The shape of every check whose subject belongs to root: the READING itself needs the privilege,
/// so on a machine that holds no way to raise a command the step learns nothing at all — the shell
/// refuses before a process starts and the check never reaches the machine it was asked about.
final class MeasuresAsRoot extends ObservingStep {
  /// Looks for the one path this example is about.
  const MeasuresAsRoot();

  /// What it looks for, in a place only root may see.
  static const String path = '/var/lib/example';

  /// The command it looks with, written down once so a fake shell can be told to answer it.
  static const Command looks = Command.detailed(
    'test',
    arguments: <String>['-e', path],
    observes: true,
    elevated: true,
  );

  @override
  Future<CheckResult> check(StepContext context) async {
    final CommandResult answered = await context.shell.run(looks);
    return answered.ok
        ? const CheckResult.satisfied('$path is there')
        : const CheckResult.blocked('$path is not there');
  }
}

/// A step that writes where only root may look, and whose plan says what stands there now.
///
/// The shape of every step that writes: what it WOULD change is described out of what is there, so
/// the reading its plan rests on needs the same privilege the write does. Its check answers before
/// anything is read, which is what puts the refusal in the plan rather than in the check.
final class PlansAsRoot extends IrreversibleStep {
  /// Would put [content] where only root may write.
  const PlansAsRoot({required this.content});

  /// What it would put there.
  final String content;

  /// The file it writes, in a place only root may read.
  static const String path = '/var/lib/example';

  /// The command its plan reads with, written down once so a fake shell can be told to answer it.
  static const Command reads = Command.detailed(
    'cat',
    arguments: <String>[path],
    observes: true,
    elevated: true,
  );

  @override
  String get irreversibleReason => 'what stood in $path is kept nowhere';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async {
    final CommandResult found = await context.shell.run(reads);
    return StepPlan.diff(path, before: found.trimmed, after: content);
  }

  @override
  Future<void> apply(StepContext context) async =>
      context.files.write(path, content, mode: 0x1a4, elevated: true);
}

/// A condition that answers whatever it was built with.
final class Says implements Predicate {
  const Says({required this.answer, required this.because});

  final bool answer;
  final String because;

  @override
  Future<PredicateResult> evaluate(PredicateContext context) async =>
      answer ? PredicateResult.holds(because) : PredicateResult.doesNotHold(because);
}

/// A condition that cannot answer, because what it reads says nothing it can make sense of.
final class CannotSay implements Predicate {
  const CannotSay(this.because);

  final String because;

  @override
  Future<PredicateResult> evaluate(PredicateContext context) async =>
      throw ConditionUnanswerable(because);
}

/// A step that throws something the engine has no name for.
final class ThrowsSomethingElse extends IrreversibleStep {
  const ThrowsSomethingElse();

  @override
  String get irreversibleReason => 'it never gets far enough to change anything';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('would throw');

  @override
  Future<void> apply(StepContext context) async =>
      throw StateError('the machine did not come back');
}

/// A step that only measures the machine and finds it as it should be.
///
/// There is nothing to take it back from, which is exactly what makes it worth having here: a
/// question about what a run leaves behind must not answer "this step" for something that leaves
/// nothing. Only its KIND says so — the class is neither reversible nor irreversible — so a reader
/// asking merely "is it a ReversibleStep" gets the wrong answer about it.
final class Measures extends ObservingStep {
  const Measures(this.because);

  final String because;

  @override
  Future<CheckResult> check(StepContext context) async => CheckResult.satisfied(because);

  @override
  Future<StepPlan> plan(StepContext context) async => StepPlan.nothing(because);
}

/// A wait whose command comes from the program row, so its answer rests on the row's word.
///
/// The row declares that the command only looks. No code chose that command, so the framework
/// cannot verify the claim — the step says so through its trust flag, and the engine stamps every
/// row of it declared, however the wait comes out.
/// A wait that has to wait ONCE, so its apply really runs.
///
/// The shape no check in this suite had: a step that is neither reversible nor irreversible AND whose
/// apply happened, so it reaches the run's applied list. A wait answers [Ready] while the thing it
/// waits for is not true yet (step.dart:144-148), which is how an observing step comes to be applied
/// at all — every other observing step in this file is satisfied outright and never gets there.
///
/// The counter is an instance field and that is enough: the engine builds a step once per row
/// (step_execution.dart:147), so the check, the apply and the postcondition of one row share this
/// object while the resolver's and the boundary's own copies are their own.
final class WaitsOnceThenHolds extends ObservingStep with WaitStep {
  WaitsOnceThenHolds();

  bool _asked = false;

  @override
  bool get answersOnTrust => true;

  @override
  Duration get deadline => const Duration(seconds: 60);

  @override
  Duration get interval => Duration.zero;

  @override
  String get waitingFor => 'the thing this row stands in for';

  @override
  Future<({bool held, String? saw})> holds(StepContext context) async {
    if (_asked) {
      return (held: true, saw: null);
    }
    _asked = true;
    return (held: false, saw: 'it has not happened yet');
  }
}

final class WaitsOnTheRowsWord extends ObservingStep with WaitStep {
  const WaitsOnTheRowsWord({required this.command});

  /// What the row said to ask.
  final String command;

  @override
  bool get answersOnTrust => true;

  @override
  Duration get deadline => const Duration(seconds: 60);

  @override
  Duration get interval => const Duration(seconds: 10);

  @override
  String get waitingFor => 'the command the row names to answer';

  @override
  Future<({bool held, String? saw})> holds(StepContext context) async {
    final CommandResult answered = await context.shell.run(
      Command.detailed(command, observes: true, timeout: deadline),
    );
    return answered.ok && answered.trimmed.isNotEmpty
        ? (held: true, saw: null)
        : (held: false, saw: 'it answered "${answered.trimmed}"');
  }
}

/// A gate whose whole job is verifying an earlier step, asked before that step has run.
///
/// The one row in this framework that ends up declared. Its check cannot hold in a mode where
/// nothing was applied — what it looks for is not there, through no fault of the machine — so the
/// engine carries the run past it on the strength of what it says it WOULD check. Nothing measured
/// that, and the record has to say so rather than count the row among the measured ones.
final class VerifiesWhatRanBefore extends ObservingStep {
  const VerifiesWhatRanBefore();

  @override
  bool get restsOnAnEarlierStep => true;

  @override
  Future<CheckResult> check(StepContext context) async =>
      const CheckResult.blocked('the file the earlier step writes is not there');

  @override
  Future<StepPlan> plan(StepContext context) async =>
      const StepPlan.nothing('would read back what the earlier step wrote');
}

/// A step that reads the machine and publishes what it read, the way a real measuring step does.
///
/// It measures inside its CHECK, which is where an observing step has to: its apply does nothing and
/// is never reached once the check is satisfied. So it publishes in every mode, and what a mode that
/// changes nothing does with the value is the engine's decision rather than this step's.
final class MeasuresAndPublishes extends ObservingStep {
  const MeasuresAndPublishes({required this.file, required this.publishes});

  /// The file it reads the value out of.
  final String file;

  /// The name it publishes under.
  final MeasurementName publishes;

  @override
  Future<CheckResult> check(StepContext context) async {
    if (!await context.files.exists(file)) {
      // Nothing read is not a value. A step answering with one here would put a sentence in the
      // record about a machine nobody measured.
      return CheckResult.blocked('$file could not be read, so nothing here says what it holds');
    }
    final String found = (await context.files.read(file)).trim();
    context.measurements.publish(publishes, found);
    return CheckResult.satisfied('$file says $found');
  }
}

/// A step that publishes a name its registry entry does not declare.
final class PublishesWhatItNeverDeclared extends ObservingStep {
  const PublishesWhatItNeverDeclared(this.name);

  final MeasurementName name;

  @override
  Future<CheckResult> check(StepContext context) async {
    context.measurements.publish(name, 'something');
    return const CheckResult.satisfied('published');
  }
}

/// A step that publishes an empty reading, which is not a reading.
final class PublishesNothing extends ObservingStep {
  const PublishesNothing(this.name);

  final MeasurementName name;

  @override
  Future<CheckResult> check(StepContext context) async {
    context.measurements.publish(name, '');
    return const CheckResult.satisfied('published');
  }
}

/// A step that writes whatever its `content` argument holds, reading it as an optional one.
///
/// The shape a step takes when a row may fill one of its arguments from a measurement: the value is
/// absent while the program is being examined, and the step still builds.
final class WritesWhatItWasGiven extends ReversibleStep<String?> with FileStep {
  WritesWhatItWasGiven({required this.path, required this.content});

  factory WritesWhatItWasGiven.fromArguments(Arguments arguments) => WritesWhatItWasGiven(
    path: arguments.text('path'),
    content: arguments.optionalText('content') ?? '',
  );

  /// What this step accepts. `content` is not required, so the step builds while the value that
  /// fills it does not exist yet.
  static const List<ArgumentSpec> arguments = <ArgumentSpec>[
    ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file it writes'),
    ArgumentSpec(
      name: 'content',
      kind: ArgumentKind.text,
      describes: 'what goes in it',
      required: false,
    ),
  ];

  final String path;

  final String content;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => FileContent.text(content);

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}

/// A step that reads its value while it is being built, so it cannot be built without one.
final class NeedsItsValueToBeBuilt extends ObservingStep {
  const NeedsItsValueToBeBuilt(this.content);

  factory NeedsItsValueToBeBuilt.fromArguments(Arguments arguments) =>
      NeedsItsValueToBeBuilt(arguments.text('content'));

  static const List<ArgumentSpec> arguments = <ArgumentSpec>[
    ArgumentSpec(
      name: 'content',
      kind: ArgumentKind.text,
      describes: 'what it was given',
      required: false,
    ),
  ];

  final String content;

  @override
  Future<CheckResult> check(StepContext context) async => CheckResult.satisfied(content);
}

/// A step that changes something and whose APPLY then throws, which is the partial apply an undo
/// exists for.
///
/// The shape every real one has: it does several things and the second fails. `patch_container_
/// arguments_and_ports` in this platform's plugin patches a workload declaration and then replaces
/// the pods, and a delete that returns non-zero throws with the declaration already changed.
///
/// IT THROWS EITHER AN [Exception] OR AN [Error], and the row ends in the same place both times:
/// the first act wrote, the second stopped, and nothing has read what the machine holds now. What
/// differs is which of the engine's catches the throw meets — an [Error] passes any catch that asks
/// for an [Exception], beside the apply and at the top of `execute` alike, and reaches the runner's
/// last catch, which closes a record with no rows while the write stands.
final class ChangesThenItsApplyThrows extends ReversibleStep<String?> with FileStep {
  ChangesThenItsApplyThrows({required this.path, this.throwsAnError = false});

  final String path;

  /// Whether its apply throws an [Error] rather than an [Exception].
  ///
  /// A value and not a second class of step, for the same reason
  /// [ChangesThenItsPostconditionThrows.throwsAnError] is one: an [Exception] where the machine
  /// refused, an [Error] where the step's own code has a bug in it — a cast, an index, a null.
  final bool throwsAnError;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => const FileContent.text('written');

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> apply(StepContext context) async {
    await super.apply(context);
    if (throwsAnError) {
      throw StateError('the second act read a value that was not there');
    }
    throw CommandFailed(
      argv: const <String>['second'],
      exitCode: 1,
      stdout: '',
      stderr: 'the second act failed',
    );
  }

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}

/// A step that changes something and whose POSTCONDITION then throws.
///
/// The one place a throw meets a machine that has already been changed. The apply returned without
/// a word, so the write stands; the reading a real run judges the row by is the one that could not
/// be taken.
///
/// The shape a real one has: what a step writes with and what reads it back are not the same tool,
/// so a write that went through says nothing about whether the reading after it will. A unit file
/// written and `systemctl show` refusing to answer about it; a configuration written and the parser
/// that reads it back throwing on what stands there. This one stands in for both by throwing
/// outright once the file is there.
///
/// Its check answers [Ready] before the apply, because the file is not there yet. That is what puts
/// the throw in the postcondition alone, and it is why this step is not simply one whose check
/// always throws: such a step never applies, and the machine is never changed.
final class ChangesThenItsPostconditionThrows extends ReversibleStep<String?> with FileStep {
  ChangesThenItsPostconditionThrows({required this.path, this.throwsAnError = false});

  final String path;

  /// Whether its postcondition throws an [Error] rather than an [Exception].
  ///
  /// A value and not a second class of step. The row ends in the same place either way: an
  /// [Exception] where the machine refused to answer, an [Error] where the step's own code has a
  /// bug in it — a cast, an index, a null — and in both the write is already done and the reading
  /// never came back. What differs is which of the engine's catches the throw would meet, and that
  /// is the difference this value is here to hold still.
  final bool throwsAnError;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => const FileContent.text('written');

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<CheckResult> check(StepContext context) async {
    if (!await context.files.exists(path)) {
      return const CheckResult.ready();
    }
    if (throwsAnError) {
      throw StateError('the postcondition read a value that was not there');
    }
    throw CommandFailed(
      argv: <String>['read-back', path],
      exitCode: 1,
      stdout: '',
      stderr: 'the tool that reads $path back did not answer',
    );
  }

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}

/// A step that writes, and whose postcondition answers that the machine is still not in the state
/// it produces.
///
/// The neighbour of a row whose postcondition threw, and the difference is the whole of what a
/// standing says: this reading came back and the answer was no, which is a measurement. It is
/// reversible and writes through the file port, so what it did can be taken back and a test can
/// read off the machine whether it was.
final class WritesButNeverSatisfied extends ReversibleStep<String?> with FileStep {
  WritesButNeverSatisfied({required this.path});

  final String path;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => const FileContent.text('written');

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}

/// A step whose capture throws, so nothing of it ever reached the machine.
///
/// The innocent neighbour of a row that threw after its apply. [ReversibleStep.capture] runs BEFORE
/// the apply — it is the reading an undo is built out of — so a row that threw there wrote nothing,
/// and an unwind reaching it would change a machine this run never touched: this undo puts back
/// what the capture returned, and the capture returned nothing.
///
/// The shape a real one has: the file it is about to overwrite belongs to root, and the reading is
/// refused before the step gets as far as writing.
final class ThrowsWhileCapturing extends ReversibleStep<String?> with FileStep {
  ThrowsWhileCapturing({required this.path, this.throwsAnError = false});

  final String path;

  /// Whether its capture throws an [Error] rather than an [Exception].
  ///
  /// The throw meets the catch at the top of `execute` either way — the capture runs outside the
  /// try around the apply — and a catch there that asks for an [Exception] lets an [Error] out of
  /// the engine entirely, closing a record holding no rows about a step that had not yet touched
  /// the machine.
  final bool throwsAnError;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => const FileContent.text('written');

  @override
  Future<String?> capture(StepContext context) async {
    if (throwsAnError) {
      throw StateError('what stands in $path is not what this step can put back');
    }
    throw CommandFailed(
      argv: <String>['cat', path],
      exitCode: 1,
      stdout: '',
      stderr: 'what stands in $path cannot be read, so nothing here could put it back',
    );
  }

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}

/// A step that writes and whose UNDO throws.
///
/// The one throw that happens while a failed run is already cleaning up. Its apply is ordinary and
/// its postcondition holds, so the row succeeds and the unwind reaches it in the normal way; what
/// fails is putting the change back. Where the unwind loop's catch asks for an [Exception], an
/// [Error] here leaves the loop entirely, every step still to be taken back is left standing, and
/// the record closes with no rows.
///
/// The shape a real one has: the tool the undo shells out to is gone by the time the undo runs,
/// because an earlier step in the same unwind removed it.
final class WritesAndItsUndoThrows extends ReversibleStep<String?> with FileStep {
  WritesAndItsUndoThrows({required this.path, this.throwsAnError = false});

  final String path;

  /// Whether its undo throws an [Error] rather than an [Exception].
  final bool throwsAnError;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => const FileContent.text('written');

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> undo(StepContext context, String? captured) async {
    if (throwsAnError) {
      throw StateError('the undo of $path read a value that was not there');
    }
    throw CommandFailed(
      argv: <String>['restore', path],
      exitCode: 1,
      stdout: '',
      stderr: 'what this step wrote to $path could not be put back',
    );
  }
}

/// A step that reads one answer by name and writes what it holds into the record.
///
/// The shape of every step that carries a value the run was given: it reads the answer its row
/// names, and the value reaches the record through an ordinary surface. Which answer is the row's
/// word, so one step stands in for a credential and for a value nobody hides alike — which is what
/// makes it usable as the innocent neighbour of its own test.
final class SaysAnAnswer extends ObservingStep {
  /// Says whatever the answer called [answer] holds.
  const SaysAnAnswer(this.answer);

  /// Builds the step from what the program gave it.
  factory SaysAnAnswer.fromArguments(Arguments arguments) => SaysAnAnswer(arguments.text('answer'));

  /// What this step accepts.
  static const List<ArgumentSpec> arguments = <ArgumentSpec>[
    ArgumentSpec(
      name: 'answer',
      kind: ArgumentKind.answerName,
      describes: 'the name of the answer whose value it writes into the record',
    ),
  ];

  /// The name of the answer it says.
  final String answer;

  @override
  Future<CheckResult> check(StepContext context) async {
    context.log.info('the answer holds ${context.answers.text(answer)}');
    return const CheckResult.satisfied('the answer was read');
  }
}

/// A step that mints a credential while the run happens and publishes it.
///
/// The shape mechanism 3 exists for: the value is in no answer, in no program file and in nothing
/// the redactor was built from, because it did not exist when the run started.
final class MintsACredential extends ObservingStep {
  const MintsACredential({required this.publishes});

  /// The name it publishes under. Whether that name is secret is the registry entry's word, not
  /// this class's — which is what the two registries below are for.
  final MeasurementName publishes;

  @override
  Future<CheckResult> check(StepContext context) async {
    context.measurements.publish(publishes, context.entropy.hex(16));
    return const CheckResult.satisfied('a credential was minted for this run');
  }
}

/// A step that writes the credential to the record BEFORE it publishes it, and once afterwards.
///
/// Where the registration actually starts, measured from both sides in one row: the first line is
/// written while nothing knows the value, the second after the sink has registered it. A step
/// written this way is a defect in the step, and this one exists so a record can be read for which
/// of the two lines the redactor could still reach.
final class MintsAndLogsBeforePublishing extends ObservingStep {
  const MintsAndLogsBeforePublishing({required this.publishes});

  /// The name it publishes under.
  final MeasurementName publishes;

  /// What the line written BEFORE the value is published begins with.
  static const String beforeSaid = 'about to publish';

  /// What the line written AFTER it is published begins with.
  static const String afterSaid = 'published';

  @override
  Future<CheckResult> check(StepContext context) async {
    final String minted = context.entropy.hex(16);
    context.log.info('$beforeSaid $minted');
    context.measurements.publish(publishes, minted);
    context.log.info('$afterSaid $minted');
    return const CheckResult.satisfied('a credential was minted for this run');
  }
}

/// A step that carries a credential to an address, on every surface a record keeps.
///
/// It puts the value in the ADDRESS, in the authorization header and in a line of its own, because
/// those reach the record by three different routes: `RequestSent.url` is redacted by value,
/// `hideHeaders` blanks the header by NAME whatever it holds, and a log line is redacted by value
/// as it is written. Only the first and the third say anything about whether the value is known to
/// the redactor at all.
final class SendsACredential extends IrreversibleStep {
  const SendsACredential({required this.url, required this.token});

  factory SendsACredential.fromArguments(Arguments arguments) =>
      SendsACredential(url: arguments.text('url'), token: arguments.optionalText('token') ?? '');

  /// What this step accepts.
  static const List<ArgumentSpec> arguments = <ArgumentSpec>[
    ArgumentSpec(name: 'url', kind: ArgumentKind.text, describes: 'where the request goes'),
    ArgumentSpec(
      name: 'token',
      kind: ArgumentKind.text,
      required: false,
      secret: true,
      describes: 'the credential the request carries',
    ),
  ];

  /// The address the request goes to.
  final String url;

  /// The credential it carries.
  final String token;

  @override
  String get irreversibleReason => 'the other end has been told, and nothing here can untell it';

  @override
  Future<CheckResult> check(StepContext context) async =>
      await context.files.exists('/var/lib/told')
      ? const CheckResult.satisfied('the other end has been told')
      : const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => StepPlan.nothing('would tell $url');

  @override
  Future<void> apply(StepContext context) async {
    context.log.info('sending the credential $token to $url');
    await context.http.send(
      HttpRequest(
        'POST',
        '$url?token=$token',
        headers: <String, String>{'authorization': 'Bearer $token'},
      ),
    );
    await context.files.write('/var/lib/told', 'told', mode: 0x1a4);
  }
}

/// A step whose one request mints a value, and whose answer is the whole of what it did.
///
/// The shape mechanism 4 exists for: nothing on the other end holds anything a second look could
/// find, so its check answers about the ROW and the engine reads what the row published instead.
final class MintsByExchange extends ExchangeStep {
  /// Sends to [url] and publishes what came back under [publishes].
  const MintsByExchange({required this.url, required this.publishes});

  /// Where the one changing request goes.
  final String url;

  /// The name it publishes what came back under.
  final MeasurementName publishes;

  @override
  String get irreversibleReason =>
      'the other end minted a value and there is no request that unmints it';

  @override
  Future<CheckResult> check(StepContext context) async => url.isEmpty
      ? const CheckResult.blocked('this row holds no address')
      : const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async =>
      StepPlan.nothing('would ask $url for a value');

  @override
  Future<void> apply(StepContext context) async {
    final HttpAnswer answer = await context.http.send(HttpRequest('POST', url));
    context.measurements.publish(publishes, answer.body);
  }
}

/// An exchange that sends its request and publishes nothing.
///
/// The row the engine's postcondition exists to fail: it did something to the other end, and there
/// is now nothing anywhere that says what.
final class ExchangesAndPublishesNothing extends ExchangeStep {
  /// Sends to [url] and publishes nothing at all.
  const ExchangesAndPublishesNothing({required this.url});

  /// Where the one changing request goes.
  final String url;

  @override
  String get irreversibleReason => 'the other end was told and nothing here can untell it';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => StepPlan.nothing('would ask $url');

  @override
  Future<void> apply(StepContext context) async {
    await context.http.send(HttpRequest('POST', url));
  }
}

/// An ORDINARY irreversible step that publishes and whose postcondition never holds afterwards.
///
/// The innocent neighbour of the exchange kind. Every name it publishes holds a value when it is
/// done, so a framework that handed the engine's postcondition to anything but an exchange would
/// report this row as a success — and the rule that turns "the step returned" into "the step worked"
/// would have been quietly widened for every step in every plugin.
final class PublishesAndStillFailsItsCheck extends IrreversibleStep {
  /// Publishes under [publishes] and never satisfies its own check.
  const PublishesAndStillFailsItsCheck({required this.publishes});

  /// The name it publishes under.
  final MeasurementName publishes;

  @override
  String get irreversibleReason => 'the other end was told and nothing here can untell it';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('would tell');

  @override
  Future<void> apply(StepContext context) async =>
      context.measurements.publish(publishes, 'a value that proves nothing about the machine');
}

/// An exchange whose check claims the work already stands.
///
/// A claim its kind says nobody can make: what an exchange does is its answer, and the other end
/// holds nothing that could say it was done before.
final class ExchangeThatClaimsSatisfied extends ExchangeStep {
  /// Creates the step that claims it.
  const ExchangeThatClaimsSatisfied();

  /// What its check says it found, which the refusal quotes back.
  static const String claimed = 'the value was already minted';

  @override
  String get irreversibleReason => 'the other end minted a value and nothing unmints it';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.satisfied(claimed);

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('would ask');

  @override
  Future<void> apply(StepContext context) async {}
}

/// A step that writes a text whose slots are filled from a mapping argument.
///
/// The mapping is the framework's grammar and not this step's: every entry is either a value
/// standing under its name or a body the framework read and filled, so what arrives here is text
/// either way.
final class FillsSlotsFromAMapping extends ReversibleStep<String?> with FileStep {
  FillsSlotsFromAMapping({required this.path, required this.template, required this.values});

  factory FillsSlotsFromAMapping.fromArguments(Arguments arguments) => FillsSlotsFromAMapping(
    path: arguments.text('path'),
    template: arguments.text('template'),
    values: <String, String>{
      for (final MapEntry<String, Object?> each
          in (arguments.raw('values') as Map<String, Object?>? ?? const <String, Object?>{})
              .entries)
        if (each.value case final String written) each.key: written,
    },
  );

  /// What this step accepts.
  static const List<ArgumentSpec> arguments = <ArgumentSpec>[
    ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file it writes'),
    ArgumentSpec(name: 'template', kind: ArgumentKind.text, describes: 'the text, with its slots'),
    ArgumentSpec(
      name: 'values',
      kind: ArgumentKind.mapping,
      required: false,
      describes: 'what fills each slot of the text',
    ),
  ];

  final String path;

  final String template;

  /// What each slot of the text holds, by the slot's name.
  final Map<String, String> values;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async =>
      FileContent.text(filledSlots(template, values));

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}
