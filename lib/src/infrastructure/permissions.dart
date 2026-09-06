import 'dart:convert';
import 'dart:io';

/// The permission bits the record's files get: 0644, so anyone on the machine may read them.
///
/// That is only safe BECAUSE of the redaction every value passes through on its way into a record.
/// An operator reads the record without elevated rights and pastes it into a message, which is the
/// whole reason it is world-readable — and the moment a value reaches these files unredacted, the
/// same bits are a leak. A change that lets one through does not break anything that would notice.
const int recordFileMode = 420;

/// The permission bits a run's directory gets: 0755, for the same reason and with the same
/// dependency on redaction.
const int recordDirectoryMode = 493;

/// Sets the POSIX permission bits of [path] to [mode].
///
/// `dart:io` has no permission setter of any kind, so this runs `chmod`, which is the program that
/// owns those bits on the platforms that have them. [mode] is written the way `chmod` expects it:
/// the value is an octal number, so 0644 is the decimal 420.
///
/// On Windows nothing is run and nothing changes. There are no POSIX bits there — a file is
/// protected by the access control list it inherits from its directory — so a run on Windows gets
/// whatever that inheritance gives it, and a caller that needs a file to be unreadable by others
/// cannot get that from this call.
Future<void> setPermissions(String path, int mode) async {
  if (Platform.isWindows) {
    return;
  }
  final ProcessResult result = await Process.run('chmod', <String>[
    mode.toRadixString(8).padLeft(3, '0'),
    path,
  ]);
  if (result.exitCode != 0) {
    throw FileSystemException('chmod returned ${result.exitCode}', path);
  }
}

/// The directories among [paths] that an account other than the one running owns, each with the
/// name of the account that owns it.
///
/// **`dart:io` cannot answer this.** `FileStat` carries the type, the mode, the size and three
/// timestamps, and no owner at all, so the question goes to `stat` — the program that owns it on
/// the platforms that have one, for the same reason [setPermissions] runs `chmod`.
///
/// **TWO PROCESSES FOR THE WHOLE STORE, whatever it holds.** `stat` takes every path at once and
/// prints one `owner path` line per operand, so five hundred directories cost the same two
/// processes as one. A path that is gone by the time this runs gets no line and no entry, which
/// reads it as this account's own — and a directory that is already gone is what the caller
/// answers as removed by somebody else rather than as a refusal.
///
/// **ON WINDOWS NOTHING IS ANOTHER ACCOUNT'S**, because there is no such owner there: a directory
/// is protected by the access control list it inherits, and `stat` is not the program that reads
/// it. The answer is empty, so a caller holds every directory it finds to be its own — which is
/// what it did before this question could be asked.
///
/// Throws [FileSystemException] where `id` cannot say which account is running. An empty answer
/// there would read as "everything is ours", which is the one answer that must not be guessed.
Future<Map<String, String>> recordsOfOtherAccounts(List<String> paths) async {
  if (Platform.isWindows || paths.isEmpty) {
    return const <String, String>{};
  }
  final ProcessResult running = await Process.run('id', <String>['-un']);
  if (running.exitCode != 0) {
    throw FileSystemException('id -un returned ${running.exitCode}');
  }
  final String ours = (running.stdout as String).trim();

  // A non-zero exit on its own is not a failure here: `stat` refuses a path that has gone and still
  // prints every path it could, and a record removed between the listing and this call is not a
  // failure of anything. What is a failure is a refusal with no line at all, which is what a `stat`
  // that does not take `-c` answers — and reading that as "every directory is ours" would hold the
  // bound over records nobody here may touch, quietly.
  final ProcessResult owners = await Process.run('stat', <String>['-c', '%U %n', ...paths]);
  final List<String> said = const LineSplitter().convert(owners.stdout as String);
  if (said.isEmpty && owners.exitCode != 0) {
    throw FileSystemException(
      'stat -c returned ${owners.exitCode} and named no owner: ${owners.stderr}',
    );
  }

  final Map<String, String> elsewhere = <String, String>{};
  for (final String line in said) {
    final int space = line.indexOf(' ');
    if (space < 0) {
      continue;
    }
    final String owner = line.substring(0, space);
    if (owner != ours) {
      elsewhere[line.substring(space + 1)] = owner;
    }
  }
  return elsewhere;
}
