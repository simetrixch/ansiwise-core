/// The three ports as every step receives them: whatever they carry out reaches the record,
/// attributed to the step, with secrets already removed.
///
/// This is why nothing in this framework logs. A step that runs a command has recorded it, because
/// running it is what recorded it. The shell this replaces spent its comments on which output
/// escaped its logging function — the raw output of the tools it called, what a container echoed, a
/// sibling script's own writing — and answered it by capturing a byte stream and slicing it by
/// offset. Here there is no escape to answer: a step reaches outside only through these.
library;

import 'dart:convert' show LineSplitter;

import '../domain/files.dart';
import '../domain/http.dart';
import '../domain/recorder.dart';
import '../domain/shell.dart';
import '../domain/logger.dart';
import '../model/failures.dart';
import '../model/names.dart';
import '../model/run_event.dart';
import 'redactor.dart';

/// A shell that records every command it runs.
///
/// What it records of the OUTPUT is decided here and nowhere else. Output is kept when the command
/// failed, and when the row this step runs for said `keep_output` — for those, the output is the
/// evidence somebody will need to read. Everything else is noise the record would grow by, so it
/// leaves only the [CommandFinished] with its exit code, its elapsed time, and a count of the lines
/// that were not kept — the count, so an unkept answer can never be read as an empty one.
///
/// **One command overrides both of those: the one whose `secretOutput` says its answer is a
/// credential.** Its lines are never kept, whatever the row asked and whatever it returned, because
/// the record is a file every account on the machine may read. A row that asks for them anyway is
/// refused with [KeepOutputRefused] before the command starts — the alternative, honouring
/// `keep_output` for every command except that one, is a record that keeps less than the program
/// says while nothing says so.
final class RecordingShell implements Shell {
  /// Wraps [inner] so that every command reaches [recorder], attributed to [step].
  const RecordingShell(
    this.inner, {
    required this.recorder,
    required this.redactor,
    required this.step,
    this.keepsOutput = false,
  });

  /// The shell that actually runs the command.
  final Shell inner;

  /// Where the events go.
  final Recorder recorder;

  /// What is removed from the output before it is recorded.
  final Redactor redactor;

  /// The step the commands belong to.
  final StepName step;

  /// Whether output is kept even for a command that succeeded.
  ///
  /// Carried from the program row, because whether a step's output is evidence or noise is a fact
  /// about one program and not about the step. A failed command's output is kept either way.
  final bool keepsOutput;

  /// How many lines of one stream the record keeps of a command whose output is kept.
  ///
  /// The tail, because a tool says why it stopped at the end of what it wrote. A record that kept
  /// every line of a verbose command would be a record nobody can read, and a redactor running
  /// over megabytes.
  static const int maxLines = 50;

  @override
  Future<CommandResult> run(Command command) async {
    if (command.secretOutput && keepsOutput) {
      // BEFORE the command is recorded as started and before it is run, which is the order the
      // planning ports keep for the same reason: what was refused did not happen, and a record
      // saying it was attempted would say otherwise.
      throw KeepOutputRefused(step: step, argv: redactor.hideAll(command.argv));
    }

    recorder.record(
      (int sequence, DateTime at) => CommandStarted(
        sequence: sequence,
        at: at,
        step: step,
        argv: redactor.hideAll(command.argv),
        elevated: command.elevated,
        workingDirectory: command.workingDirectory,
      ),
    );

    final CommandResult result = await inner.run(command);

    if (!result.ok || keepsOutput) {
      _recordLines(result.stdout, OutputStream.stdout, secret: command.secretOutput);
      _recordLines(result.stderr, OutputStream.stderr, secret: command.secretOutput);
    }

    recorder.record(
      (int sequence, DateTime at) => CommandFinished(
        sequence: sequence,
        at: at,
        step: step,
        exitCode: result.exitCode,
        elapsed: result.elapsed,
        stdoutLines: _lineCount(result.stdout),
        stderrLines: _lineCount(result.stderr),
      ),
    );
    return result;
  }

  int _lineCount(String text) => text.isEmpty ? 0 : LineSplitter.split(text).length;

  void _recordLines(String text, OutputStream stream, {required bool secret}) {
    if (text.isEmpty) {
      return;
    }
    if (secret) {
      // How many, and not one of them. This is reached where the output WOULD have been kept, which
      // for such a command is only a command that failed — and a failed command whose lines are
      // simply absent reads as a command that wrote nothing, which is the reading this line exists
      // to prevent.
      final int lines = LineSplitter.split(text).length;
      _recordLine(
        stream,
        '[withheld ${lines == 1 ? '1 line' : '$lines lines'}: this command answers with a secret]',
      );
      return;
    }
    // Split rather than record the block whole: the record is read line by line, and a client that
    // reconnected asks for everything after a sequence number, which only means something if one
    // line is one event.
    final List<String> lines = LineSplitter.split(text).toList();
    final int toDrop = lines.length - maxLines;
    if (toDrop > 0) {
      _recordLine(stream, '[dropped $toDrop lines of output]');
    }
    for (final String line in toDrop > 0 ? lines.skip(toDrop) : lines) {
      _recordLine(stream, redactor.hide(line));
    }
  }

  void _recordLine(OutputStream stream, String text) {
    recorder.record(
      (int sequence, DateTime at) =>
          Output(sequence: sequence, at: at, step: step, stream: stream, text: text),
    );
  }
}

/// A file system that records every write.
final class RecordingFiles implements Files {
  /// Wraps [inner] so that every write reaches [recorder], attributed to [step].
  const RecordingFiles(this.inner, {required this.recorder, required this.step});

  /// The file system that actually carries out the operation.
  final Files inner;

  /// Where the events go.
  final Recorder recorder;

  /// The step the operations belong to.
  final StepName step;

  @override
  Future<bool> exists(String path, {bool elevated = false}) =>
      inner.exists(path, elevated: elevated);

  @override
  Future<String> read(String path, {bool elevated = false}) => inner.read(path, elevated: elevated);

  @override
  Future<List<String>> list(String path, {bool elevated = false}) =>
      inner.list(path, elevated: elevated);

  @override
  Future<void> write(
    String path,
    String content, {
    required int mode,
    bool elevated = false,
  }) async {
    // Asked the same way the write is made. Without the flag this is the ordinary reader, and a
    // path only root may look at answers with a permission error — from the RECORDING wrapper, one
    // line before the write that would have worked. Measured on a machine three runs in a row, each
    // time reading as though the step had forgotten something it had not.
    final bool existed = await inner.exists(path, elevated: elevated);
    await inner.write(path, content, mode: mode, elevated: elevated);
    recorder.record(
      (int sequence, DateTime at) => FileWritten(
        sequence: sequence,
        at: at,
        step: step,
        path: path,
        bytes: content.length,
        created: !existed,
      ),
    );
  }

  @override
  Future<void> delete(String path, {bool elevated = false}) async {
    // Asked the same way the write is made. Without the flag this is the ordinary reader, and a
    // path only root may look at answers with a permission error — from the RECORDING wrapper, one
    // line before the write that would have worked. Measured on a machine three runs in a row, each
    // time reading as though the step had forgotten something it had not.
    final bool existed = await inner.exists(path, elevated: elevated);
    await inner.delete(path, elevated: elevated);
    if (existed) {
      recorder.record(
        (int sequence, DateTime at) => Log(
          sequence: sequence,
          at: at,
          step: step,
          level: LogLevel.info,
          message: 'deleted $path',
        ),
      );
    }
  }

  @override
  Future<void> createDirectory(String path, {required int mode, bool elevated = false}) async {
    // Asked the same way the write is made. Without the flag this is the ordinary reader, and a
    // path only root may look at answers with a permission error — from the RECORDING wrapper, one
    // line before the write that would have worked. Measured on a machine three runs in a row, each
    // time reading as though the step had forgotten something it had not.
    final bool existed = await inner.exists(path, elevated: elevated);
    await inner.createDirectory(path, mode: mode, elevated: elevated);
    if (!existed) {
      recorder.record(
        (int sequence, DateTime at) => Log(
          sequence: sequence,
          at: at,
          step: step,
          level: LogLevel.info,
          message: 'created directory $path',
        ),
      );
    }
  }
}

/// A network port that records every request.
final class RecordingHttp implements Http {
  /// Wraps [inner] so that every request reaches [recorder], attributed to [step].
  const RecordingHttp(
    this.inner, {
    required this.recorder,
    required this.redactor,
    required this.step,
  });

  /// The port that actually sends the request.
  final Http inner;

  /// Where the events go.
  final Recorder recorder;

  /// What is removed from the address before it is recorded.
  final Redactor redactor;

  /// The step the requests belong to.
  final StepName step;

  @override
  Future<HttpAnswer> send(HttpRequest request) async {
    final HttpAnswer answer = await inner.send(request);
    recorder.record(
      (int sequence, DateTime at) => RequestSent(
        sequence: sequence,
        at: at,
        step: step,
        method: request.method,
        url: redactor.hide(request.url),
        // Through the redactor like the address beside it. A socket path is rarely a secret, but a
        // field that goes into the record raw is a field nobody thought about — and an answer given
        // as a path is a place an answer can stand.
        status: answer.status,
        socketPath: switch (request.socketPath) {
          final String path => redactor.hide(path),
          null => null,
        },
      ),
    );
    return answer;
  }
}

/// What a step says in its own words, on its way to the record.
///
/// **The level decides what is WRITTEN, never what a step is allowed to say.** Every step logs at
/// every level, always; [threshold] is what a reader configured for this run, and a line below it is
/// dropped here rather than never produced. That difference matters: a step that decided for itself
/// what was worth saying would be a step whose author guessed, months earlier, what somebody would
/// need at three in the morning.
final class RecordingLogger implements Logger {
  /// Sends every line at or above [threshold] to [recorder], attributed to [step].
  const RecordingLogger({
    required this.recorder,
    required this.redactor,
    required this.step,
    this.threshold = LogLevel.info,
  });

  /// Where the events go.
  final Recorder recorder;

  /// What is removed before a line is recorded.
  final Redactor redactor;

  /// The step the lines belong to.
  final StepName step;

  /// The quietest level this run writes.
  ///
  /// `info` unless a run says otherwise, so a normal run carries what an operator reads and a run
  /// somebody is debugging carries what they need by being asked for it.
  final LogLevel threshold;

  @override
  void debug(String message) => _log(LogLevel.debug, message);

  @override
  void info(String message) => _log(LogLevel.info, message);

  @override
  void warn(String message) => _log(LogLevel.warn, message);

  @override
  void error(String message) => _log(LogLevel.error, message);

  void _log(LogLevel level, String message) {
    if (!level.passes(threshold)) {
      return;
    }
    recorder.record(
      (int sequence, DateTime at) => Log(
        sequence: sequence,
        at: at,
        step: step,
        level: level,
        message: redactor.hide(message),
      ),
    );
  }
}
