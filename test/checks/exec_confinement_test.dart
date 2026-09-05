import 'package:test/test.dart';
import 'package:ansiwise_checks_tree/ansiwise_checks_tree.dart';

/// exec-confinement — nothing outside infrastructure/ reaches the machine directly.
///
/// The dry-run guarantee is that `--mode dry` cannot change anything, and it rests on two
/// independent things: the engine calls a step's plan and never its apply, and the ports handed to
/// the step throw on any call the step did not declare as only looking. The second is what holds
/// when the first is wrong.
///
/// It holds only for what goes THROUGH those ports. A step that writes `Process.run(...)` or
/// `File(path).writeAsString(...)` has left the framework: the port never sees the call, the run
/// record never mentions it, and the dry run reports that nothing would change while the machine
/// was already changed. Nothing about that line looks wrong in review — it is shorter than the port
/// call and does the same thing on a real run.
///
/// So the reach itself is confined by name. A directory called infrastructure/ is where a port is
/// implemented against the real machine; everywhere else in the shipped library asks a port.
///
/// THE RULE IS ABOUT THE SHIPPED LIBRARY, so the directories of the package layout that ship
/// nothing stand outside it — they are named in [notTheShippedLibrary] and each is matched at the
/// package root and not as a path segment anywhere. lib/src/testing/ is deliberately not among
/// them: it ships — it is the fake machine the framework hands to a step's test, and a fake that
/// reached the real one would defeat the thing it exists for.
void main() {
  final SourceTree tree = SourceTree.on(repositoryRoot());

  test('this tree holds at least one Dart package', () {
    expect(
      tree.packages,
      isNotEmpty,
      reason: 'with no package there is nothing to confine and a pass would mean nothing',
    );
  });

  test('there is a shipped library to scan', () {
    expect(
      confinedFilesOf(tree),
      isNotEmpty,
      reason:
          'every Dart file in this tree sits in one of the places the reach is allowed, so this '
          'check measured nothing',
    );
  });

  test('nothing in a shipped library outside infrastructure/ reaches the machine directly', () {
    expect(
      directReachesIn(tree),
      isEmpty,
      reason:
          'each finding reads <file>:<line>:<text>; the fix is to ask Shell, Files, Http or Clock '
          'rather than to widen this rule',
    );
  });

  group('counter-probe', () {
    // Both directions, or the probe proves nothing: a planted reach outside infrastructure/ must be
    // reported, and the same line inside one must not. A scan that reported everything would pass
    // the first half alone.

    final SourceTree planted = SourceTree.planted(<String, String>{
      'pubspec.yaml': 'name: planted_package\n',
      'lib/src/domain/planted.dart': _reach,
      'lib/src/infrastructure/real_shell.dart': _reach,
      // lib/src/testing/ ships and only LOOKS like test/. If the two allowances are ever collapsed
      // into a match on the word anywhere in the path, this file is what reports it.
      'lib/src/testing/fake_machine.dart': _reach,
      'test/executions/reads_a_program.dart': _reach,
      'bin/planted.dart': _reach,
      // The gate's own programs start the Dart toolchain, which is the whole of what they are. A
      // rule that forbade them the reach would forbid the gate.
      'tool/planted_engine.dart': _reach,
      'lib/src/domain/only_says_it.dart': _mentionsItInAComment,
    });
    final List<String> reported = directReachesIn(planted);

    for (final String path in <String>[
      'lib/src/domain/planted.dart',
      'lib/src/testing/fake_machine.dart',
    ]) {
      test('a planted reach in $path is reported', () {
        expect(
          reported.where((String hit) => hit.startsWith('$path:')),
          isNotEmpty,
          reason: 'this scan cannot go red there, so its silence about the real tree means nothing',
        );
      });
    }

    for (final String path in <String>[
      'lib/src/infrastructure/real_shell.dart',
      'test/executions/reads_a_program.dart',
      'bin/planted.dart',
      'tool/planted_engine.dart',
    ]) {
      test('the same lines in $path are not reported', () {
        expect(
          reported.where((String hit) => hit.startsWith('$path:')),
          isEmpty,
          reason: 'this scan refuses one of the places the reach belongs',
        );
      });
    }

    test('a line that only names the reach in a comment is not a reach', () {
      expect(
        reported.where((String hit) => hit.startsWith('lib/src/domain/only_says_it.dart:')),
        isEmpty,
        reason:
            "the framework's own doc comments say what a port exists instead of, and a scan that "
            'could not tell that from a call would forbid the sentence that states the rule',
      );
    });
  });
}

/// The five ways out of the process.
///
/// Matched case-SENSITIVELY and word-anchored, because these are Dart identifiers: the prose "a
/// step never starts a process itself" is not a reference to `Process`, and the port class `Files`
/// is not `File`.
const List<String> waysOut = <String>['dart:io', 'Process', 'File', 'HttpClient', 'SSHClient'];

/// The directories of a package that are not its shipped library, matched at the package root.
///
/// `test/` — a test that could not open a program file would be verifying a copy of the program
/// pasted into it rather than the program that ships.
///
/// `bin/` — the entry point reads the process's own arguments and sets its exit code, which is one
/// library and can be nothing else.
///
/// `tool/` — the gate's own programs. They drive the Dart toolchain on a developer machine and are
/// never carried onto a deployed one, so no run of a program passes through them and no dry-run
/// guarantee rests on them.
///
/// `checks/` — the gate's own AUDITS, a package of their own rather than a directory of this one.
/// An audit walks a tree of files, so it reaches `dart:io` by necessity; it is a dev dependency of
/// whatever runs it, compiled into no binary and carried onto no machine, so nothing a run promises
/// rests on it. Named here for the same reason `tool/` is — and that reason is what the whole list
/// means: the rule is about what SHIPS, and none of these four does.
const List<String> notTheShippedLibrary = <String>['test', 'bin', 'tool', 'checks'];

/// The Dart files of [tree] the rule applies to, sorted.
List<String> confinedFilesOf(SourceTree tree) =>
    tree.dartFiles.where((String path) => !_reachIsAllowedIn(tree, path)).toList(growable: false);

/// Every reference to a way out from a file the rule applies to, as `<file>:<line>:<text>`.
List<String> directReachesIn(SourceTree tree) {
  final RegExp anyOfThem = RegExp('\\b(?:${waysOut.map(RegExp.escape).join('|')})\\b');
  final List<String> found = <String>[];
  for (final String path in confinedFilesOf(tree)) {
    final String? text = tree.textOf(path);
    if (text == null) {
      continue;
    }
    final List<String> lines = linesOf(text);
    for (int i = 0; i < lines.length; i++) {
      if (!anyOfThem.hasMatch(lines[i]) || _isCommentOnly(lines[i])) {
        continue;
      }
      found.add('$path:${i + 1}:${lines[i]}');
    }
  }
  return found;
}

/// Whether [path] is one of the places the reach is allowed in the package holding it.
bool _reachIsAllowedIn(SourceTree tree, String path) {
  // An infrastructure/ directory is where the reach belongs. The test is on a path segment, so a
  // file merely NAMED infrastructure.dart is not inside one.
  if (path.split('/').contains('infrastructure')) {
    return true;
  }
  for (final String directory in tree.packages.keys) {
    final String prefix = directory.isEmpty ? '' : '$directory/';
    for (final String outside in notTheShippedLibrary) {
      if (path.startsWith('$prefix$outside/')) {
        return true;
      }
    }
  }
  return false;
}

/// Whether [line] is nothing but a comment.
///
/// Nothing executable can hide there: a comment-only line runs no code, and a trailing comment sits
/// on a line that is scanned anyway.
bool _isCommentOnly(String line) {
  final String trimmed = line.trimLeft();
  return trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*');
}

const String _reach =
    "import 'dart:io';\n"
    'Future<void> plantedApply() async => Process.run("rm", <String>["-rf", "/"]);';

const String _mentionsItInAComment =
    '/// Neither of these knows about a socket or dart:io, and none of them starts a Process.';
