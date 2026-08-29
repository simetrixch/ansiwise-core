import 'package:meta/meta.dart';

import '../model/names.dart';
import '../model/on_failure.dart';
import 'answers.dart';
import 'arguments.dart';

/// An ordered list of steps, and what each of them is allowed to cost.
///
/// A program is declared as data and never as code. It names steps, gives them arguments, puts
/// named conditions in front of some of them, and says what a failure costs. It cannot compute: no
/// loops, no expressions, no templating, no precedence between sources. The moment a program file
/// can compute, the thing being debugged is the file rather than the code, which is the state this
/// framework exists to avoid.
@immutable
final class Program {
  /// Creates a program.
  const Program({
    required this.name,
    required this.roles,
    required this.steps,
    this.answers = DeclaredAnswers.none,
    this.defaults = Arguments.none,
  });

  /// Its name, which is also the sub-command that runs it.
  final ProgramName name;

  /// The machine roles it applies to.
  ///
  /// A program run against a machine whose role is not in here is refused at the first gate, before
  /// anything is looked at.
  final List<Role> roles;

  /// The steps, in the order they run.
  final List<ProgramStep> steps;

  /// What an operator has to supply before this can run.
  ///
  /// Declared here rather than known by whatever starts the run, which is what lets one client
  /// stand in front of any plugin: it renders a form from this and hard-codes no field.
  final DeclaredAnswers answers;

  /// Values this program gives to every step that takes them and was not given them on its own row.
  ///
  /// **What this is for.** Several steps of one program regularly need the same value — where the
  /// profile of this installation stands, which key inside it holds an address, which permissions an
  /// argument file is written with. Writing it on every row means writing it thirty times, and the
  /// failure that follows is not the typing: it is the day one of them changes and twenty-nine rows
  /// are edited. The thirtieth is then wrong, and nothing reports it, because a row carrying a stale
  /// value is a valid row.
  ///
  /// **It is still data.** A map of names to values, resolved once against the registry before the
  /// run begins. There is no expression in it, nothing is computed from anything, and a reader sees
  /// the text that will be used.
  ///
  /// **A row always wins.** A value written on the row is what that step gets; this only fills what
  /// the row left out. The order is therefore row, then this, then what the step itself declares as
  /// its default — narrowest first, so nothing here can reach past a decision somebody made.
  ///
  /// **A name here that no step of this program declares is REFUSED**, with the program, before
  /// anything runs. A misspelled key would otherwise sit in the file filling nothing, and the run
  /// would go ahead on the step's own default while the file says something else.
  final Arguments defaults;

  /// Whether this program may be run against a machine of [role].
  ///
  /// A role that carries several parts applies where ANY of its parts does: a machine whose role
  /// is a union of two jobs IS each of them, so a program declared for either one runs against it.
  /// The exact-membership half stays first, so a program that deliberately names a union in
  /// `roles:` — applying only to a machine that does both jobs — still matches it whole.
  bool appliesTo(Role role) => roles.contains(role) || role.parts.any(roles.contains);
}

/// One entry in a program: which step, with what, when, and what a failure costs.
@immutable
final class ProgramStep {
  /// Creates one entry in a program.
  const ProgramStep({
    required this.step,
    required this.onFailure,
    this.arguments = Arguments.none,
    this.reads = const <String, MeasurementName>{},
    this.publish = const <MeasurementName, MeasurementName>{},
    this.when = const <PredicateName>[],
    this.undo = true,
    this.restsOnAnEarlierStep = false,
    this.keepsOutput = false,
  });

  /// The registered name of the step.
  final StepName step;

  /// What a failure of this step costs the run.
  ///
  /// Required, with no default. A default would be a policy nobody chose, applied to the step
  /// somebody forgot to think about — and the steps nobody thought about are exactly the ones whose
  /// failure policy turns out to be wrong.
  final OnFailure onFailure;

  /// The values this step is given.
  final Arguments arguments;

  /// Which of this step's arguments take their value from a measurement, and from which one.
  ///
  /// Keyed by the ARGUMENT the step declares, valued by the NAME an earlier row of this program
  /// publishes. In a file it is written where the value would stand — `resolvers: {measured:
  /// host.upstream_resolvers}` — so a reader sees on the row itself that this value comes off the
  /// machine rather than out of the file.
  ///
  /// **A named slot and nothing more.** The row names one measurement and takes the whole of it. It
  /// cannot be part of a larger string, cannot be tested, cannot be combined with another, and
  /// cannot appear twice in one value. Every one of those would be an expression, and a program file
  /// that can compute is a program file being debugged instead of the code.
  ///
  /// **What the resolver refuses about it**, before anything runs: an argument the step does not
  /// declare, one that does not hold text, one declared secret, a name no row of this program
  /// publishes, a name published by a row that runs later, a name published by a row that a
  /// condition may skip while this row runs, and a step that cannot be built at all while the value
  /// is missing — which is what everything examining a program before it runs has to do.
  final Map<String, MeasurementName> reads;

  /// The name this row publishes each of its step's measurements under.
  ///
  /// Keyed by a name the step's registry entry DECLARES, valued by the name this row publishes it
  /// under — `publish: {http_field: run_id}`. A name left out is published as the step declares it,
  /// which is what every row that says nothing here does.
  ///
  /// **What it is for.** The name a step publishes is fixed by its class, so two rows of one program
  /// running the SAME step publish one name twice — and the resolver refuses that program, because
  /// nothing says which of the two values a row taking the name would get. A program that has to
  /// carry two values out of two answers could not be written at all. The rename is what a row says
  /// instead, and it says it as data: one name standing for one name, nothing computed, nothing
  /// conditional.
  ///
  /// **The step is never told.** It publishes the name its class declares, in every program; the
  /// sink the engine hands it writes the name this row chose.
  ///
  /// **What the resolver refuses about it**, before anything runs: a name the step's registry entry
  /// does not publish, and a rename that lands two rows on one name again.
  final Map<MeasurementName, MeasurementName> publish;

  /// The conditions that must all hold for this step to run.
  ///
  /// Combined with and, never with or. A condition that needs an or is two named conditions too
  /// few — and a program file that can express or is one expression away from being able to
  /// compute.
  final List<PredicateName> when;

  /// Whether what THIS ROW needs is brought about by an earlier row of the same program.
  ///
  /// **A property of the sequence, not of the step.** A step that writes into a process argument
  /// file rests on nothing when the process is already installed, and rests on the row three above
  /// it when that row is what installs it. The same class, two programs, two truths — so the program
  /// says it, which is also where every other fact about an order belongs.
  ///
  /// It decides what the two modes that change nothing do when the row cannot proceed. Without it a
  /// dry run of any program that installs something and then configures it dies at its first
  /// configuring step, on a machine where nothing has been installed — which is precisely the
  /// machine a dry run is pointed at, and a real run is admitted only where a dry one came back
  /// green.
  ///
  /// A step may also say it for itself, where it is true of every use: a gate that verifies what an
  /// earlier step did can never answer before that step has run, whatever program names it. The two
  /// are different statements and both may be made — one about the step, one about this row.
  ///
  /// **What it does NOT do is hide a machine's own answer.** A row that says this reports what it
  /// WOULD do and is recorded as declared rather than proven, so the run's closing numbers carry it.
  final bool restsOnAnEarlierStep;

  /// Whether this entry may be taken back when a later step ends the run.
  ///
  /// **True by default, and the operator is who turns it off.** A step that CAN be undone is not
  /// always a step that SHOULD be: taking a package manager's cache back onto a machine somebody has
  /// since been working on, or restoring a configuration a person edited in the meantime, is a
  /// correct undo doing damage. What is right there is a decision about one installation, so it is
  /// made in the program file rather than in the step.
  ///
  /// **It never makes an irreversible step reversible.** It only takes an undo away. A step that
  /// cannot be undone at all says so through its class, and no line in a program file changes that.
  ///
  /// **And it is said before the run, not afterwards.** A step whose undo is switched off is part of
  /// what the run cannot take back, so it moves the point of no return exactly as an irreversible
  /// step does — and an operator reads that boundary before deciding to start.
  final bool undo;

  /// Whether the record keeps what this row's commands said even when they succeeded.
  ///
  /// Without it, output is kept only for a command that failed. That default exists because most
  /// output is noise, and a record that keeps every line of every command is a record nobody can
  /// read. But for some rows the output IS the evidence: a release tool that reports what it
  /// installed, a gate whose answer says why it decided. A command of such a row can exit zero and
  /// still be the thing somebody has to read afterwards, and by then it is too late to ask for it.
  ///
  /// **A property of the row, not of the step**, for the same reason [undo] is: the same step's
  /// output is evidence in one program and noise in another, and the program file is where that
  /// judgement about one installation belongs.
  ///
  /// What is kept is bounded and redacted exactly as a failed command's output is — the tail, with
  /// a line saying how much was dropped — so saying yes here cannot make the record unreadable.
  ///
  /// **What redaction removes is the values the run registered, in the form it was given them**, so
  /// a command that answers with a credential in any other form is not covered by it. Such a command
  /// says so where it is written, in code; a row that says this while one of them runs is REFUSED
  /// when it reaches the shell, rather than being given a record with less in it than the row asked
  /// for and nothing saying why.
  final bool keepsOutput;
}
