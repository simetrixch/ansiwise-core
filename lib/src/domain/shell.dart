import 'package:meta/meta.dart';

import '../model/failures.dart';
import 'files.dart';

/// Where the password that raises a command to root comes from.
///
/// **There is no default and there cannot be one.** A path written into the framework is right on
/// the machine it was written for and silently wrong on every other: another operator, another
/// account, another layout. Worse, a wrong one does not announce itself — the elevation fails, the
/// command underneath it fails, and what the record shows is the command's own failure. So the
/// framework holds no path at all; the installation says where the password is, and where it says
/// nothing, no command is raised to root.
///
/// **The password crosses no command line.** It is read once, through the files port, and handed to
/// the elevating tool on its standard input. A password in an argument list stands in the process
/// listing for every account on the machine for as long as the command runs.
@immutable
final class Elevation {
  /// Nothing says where the password comes from, so no command may be raised to root.
  ///
  /// Not an error by itself: an installation whose steps never need root is completely configured
  /// without it. What it does is turn the first command that DOES need root into a refusal naming
  /// what has to be configured, instead of a shell failure that looks like the command's own.
  const Elevation.unconfigured() : password = null, from = null;

  /// The password [from] held, kept in memory for as long as this process lives.
  const Elevation.of(this.password, {required this.from});

  /// Reads the password out of [path], or refuses saying what is wrong with it.
  ///
  /// Read at start-up rather than at the first elevated command, so an operator learns that the
  /// file is missing before the run has changed anything — the same reason the answers are checked
  /// before the first step.
  ///
  /// Throws [ElevationUnavailable] naming the file when it is not there or holds nothing. The
  /// message is about the PASSWORD, because the failure is about the password: a refusal phrased in
  /// terms of whatever command needed root sends the operator to the wrong place.
  static Future<Elevation> read({required Files files, required String path}) async {
    if (!await files.exists(path)) {
      throw ElevationUnavailable(
        'there is no elevation password file at "$path"\n'
        'this installation names it, and nothing can be raised to root without it',
      );
    }
    final String text = await files.read(path);
    // The first line, and the newline an editor put at the end of it taken off. Nothing else is
    // stripped: a password is used exactly as it stands, and quietly trimming one would let a run
    // fail to elevate with a file that looks correct.
    final String first = text.split('\n').first;
    final String password = first.endsWith('\r') ? first.substring(0, first.length - 1) : first;
    if (password.isEmpty) {
      throw ElevationUnavailable(
        'the elevation password file "$path" begins with an empty line, so it holds no password',
      );
    }
    return Elevation.of(password, from: path);
  }

  /// The password itself, or null where this installation named none.
  ///
  /// Never recorded, never logged and never passed as an argument. The one thing that reads it
  /// writes it to the elevating tool's standard input.
  final String? password;

  /// Which file it was read out of, named in a refusal, or null where none was read.
  final String? from;
}

/// Running a command is one of the three ways this framework reaches outside.
///
/// A step never starts a process itself. It asks this. That is what lets a dry run refuse a
/// mutation, a test replace the machine with a fake, and every command reach the record without
/// anyone remembering to log it.
abstract interface class Shell {
  /// Runs [command] and returns what it did.
  ///
  /// Does not throw on a non-zero exit — the exit code is data, and what it means is the step's
  /// business. It throws only when the command could not be started at all, or when the mode
  /// forbids it.
  Future<CommandResult> run(Command command);
}

/// A command, described rather than written out.
@immutable
final class Command {
  /// Describes a command.
  ///
  /// The executable is its own parameter rather than the first entry of a list, so a command with
  /// nothing to run cannot be written down. A list with a length rule enforced by an assertion
  /// would say the same thing later, at run time, and only in a build that keeps assertions.
  const Command(this.executable, [this.arguments = const <String>[]])
    : workingDirectory = null,
      environment = const <String, String>{},
      observes = false,
      elevated = false,
      secretOutput = false,
      timeout = null;

  /// Describes a command with everything about how it runs spelled out.
  const Command.detailed(
    this.executable, {
    this.arguments = const <String>[],
    this.workingDirectory,
    this.environment = const <String, String>{},
    this.observes = false,
    this.elevated = false,
    this.secretOutput = false,
    this.timeout,
  });

  /// Describes a command that only looks at the machine.
  ///
  /// **[elevated] IS ASKED HERE, and that is the whole reason this constructor changed shape.** It
  /// used to take its arguments positionally, which meant it could not take a named flag beside
  /// them — so it fixed elevation to false, and a caller writing "this only looks" got "and it runs
  /// as you" without choosing it. That default was a limitation of the constructor, never a
  /// decision, and it cost two steps on real machines: one asked sshd for its configuration and was
  /// told Permission denied, the other asked a cluster whether it was running and waited fifteen
  /// minutes for an answer it was not allowed to read.
  ///
  /// **Observing and elevated are independent.** Running as root does not make a command change
  /// anything — it makes it able to READ — so a check that has to read something only root may read
  /// is still a command a dry run may perform. That is what makes both flags true a legitimate
  /// pair rather than a contradiction.
  const Command.observing(
    this.executable, {
    this.arguments = const <String>[],
    this.elevated = false,
    this.secretOutput = false,
  }) : workingDirectory = null,
       environment = const <String, String>{},
       observes = true,
       timeout = null;

  /// What is run.
  final String executable;

  /// What is passed to it, each argument as its own entry.
  ///
  /// A list and never a command line. The values are passed to the process directly, so a
  /// credential containing a quote, a dollar sign or a newline is data and cannot become syntax.
  /// The whole class of quoting failures that shell scripts spend their comments on does not exist
  /// here.
  final List<String> arguments;

  /// The executable and its arguments together, for recording and for a plan.
  List<String> get argv => <String>[executable, ...arguments];

  /// The directory to run in, or null for the one the run itself is in.
  final String? workingDirectory;

  /// Variables added to the environment the command sees.
  ///
  /// ADDED, not replacing: what the run itself was started with is passed through and these are set
  /// on top. And they reach the command in BOTH cases, elevated or not — which took work to be true
  /// rather than merely written here, because sudo resets the environment it passes on and once
  /// stripped a package installer's own "do not ask me anything" one command before apt would have
  /// asked.
  final Map<String, String> environment;

  /// Whether this command only looks at the machine and changes nothing.
  ///
  /// The default is false, so a command that was never thought about counts as changing something.
  /// Under a dry run that makes it throw, loudly, at the step that issued it — which is what makes
  /// the dry-run guarantee hold without trusting anyone to have remembered.
  final bool observes;

  /// How long to wait before giving up, or null to wait as long as it takes.
  final Duration? timeout;

  /// Whether this command has to run as root.
  ///
  /// Independent of [observes]. A command may look at the machine and still need root to see what
  /// it is looking at, and such a command stays observing — the dry run performs it, because
  /// running as root does not make it change anything. [Command.observing] cannot express the pair
  /// only because it takes its arguments positionally; [Command.detailed] can.
  ///
  /// Where the password comes from is not decided here and is not knowable from a command: it is
  /// [Elevation], which the composition root reads out of the installation's own configuration.
  final bool elevated;

  /// Whether what this command writes on its two output streams is a secret.
  ///
  /// **Said in code by whoever wrote the command, never by a program row**, for the same reason a
  /// measured value declares it: the caller knows what it asked the machine for, and a file does
  /// not. A command that reads a credential store whole answers with every credential in it, and
  /// nothing in the argv says so.
  ///
  /// **What follows from it, in the recording shell in `lib/src/engine/recording_ports.dart`.**
  /// That shell keeps a command's output when the command failed and when the row said
  /// `keep_output`; for a command that says this it keeps neither, and where it would have kept the
  /// output it leaves a line saying how many it withheld, so an answer that was not kept is not read
  /// as an answer that was empty. A row
  /// saying `keep_output` where such a command runs is REFUSED before the command starts, rather
  /// than quietly given less than it asked for: it is asking for a credential in a file every
  /// account on the machine may read, which is a defect in the program and not a preference.
  ///
  /// **Redaction cannot stand in for it.** What the redactor hides are the values it was told
  /// about, in the form it was told them — a value the command answers with in another encoding is
  /// text it has never seen, and a value nobody registered is text nothing is looking for. This
  /// says the output is a secret without anybody having to know what is in it.
  ///
  /// The default is false, so a command nobody thought about is recorded as every other command is.
  final bool secretOutput;
}

/// What a command did.
@immutable
final class CommandResult {
  /// Records what a command did.
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsed,
  });

  /// What the command returned.
  final int exitCode;

  /// Everything it wrote to standard output.
  final String stdout;

  /// Everything it wrote to standard error.
  final String stderr;

  /// How long it took.
  final Duration elapsed;

  /// Whether it returned zero.
  bool get ok => exitCode == 0;

  /// Standard output with surrounding whitespace removed, which is what a step reading a single
  /// value out of a command wants.
  String get trimmed => stdout.trim();
}
