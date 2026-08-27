/// What a detached run is TOLD, which is the whole of what it can stand on.
///
///   dart test test/infrastructure/detached_launcher_test.dart
///
/// WHAT IS BEING HELD is that the child is placed the way its parent was placed. Where the programs
/// are, which file names the active plugins and where records are kept all have a default relative
/// to the working directory — so a parent started with the defaults and a child given only the
/// directory resolve the same three, and a parent TOLD any of them resolves something the child then
/// cannot.
///
/// THAT IS NOT A THEORY. A REST surface started as
/// `cd <catalogue> && ansiwise-rest serve --programs <catalogue>/ansiwise/programs` listed and served
/// the catalogue, accepted a run, and the child exited 66 with `there are no programs at "programs"`
/// before writing a header. The caller was left holding a run id whose run answered 404 for ever,
/// and the only thing anybody could read was an absence.
///
/// THE CHILD HERE IS A REAL DETACHED PROCESS. It has to be: what is under test is the argument list
/// that reaches another process, and a fake that records a call would measure this file's own idea of
/// the call rather than what the operating system delivers.
library;

import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('ansiwise-launcher'));
  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  /// A child that writes down every word it was handed, beside itself.
  File aChildThatReportsItsArguments() {
    final File script = File('${home.path}/report_argv.dart');
    script.writeAsStringSync('''
import 'dart:io';

void main(List<String> argv) {
  final String beside = File.fromUri(Platform.script).parent.path;
  File('\$beside/argv.txt').writeAsStringSync(argv.join('\\n'));
}
''');
    return script;
  }

  /// What the child wrote, waited for rather than assumed: it is detached, so nothing here is its
  /// parent and there is no exit to await.
  Future<List<String>> whatItWasHanded() async {
    final File written = File('${home.path}/argv.txt');
    for (int attempt = 0; attempt < 200; attempt++) {
      if (written.existsSync()) {
        final String text = written.readAsStringSync();
        if (text.isNotEmpty) return text.split('\n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('the child wrote nothing in 20 seconds — it never ran, or it died before it could');
  }

  DetachedLauncher launcherWith(List<String> placement) => DetachedLauncher(
    executable: Platform.resolvedExecutable,
    workingDirectory: home.path,
    newRunId: () => const RunId('probe'),
    placement: placement,
  );

  test('the child is handed the placement its parent was given', () async {
    final File child = aChildThatReportsItsArguments();

    await launcherWith(<String>[
      '--programs',
      '/srv/catalogue/ansiwise/programs',
      '--runs',
      '/var/lib/ansiwise/runs',
    ]).start(program: ProgramName(child.path), mode: Mode.dry);

    expect(await whatItWasHanded(), <String>[
      '--programs',
      '/srv/catalogue/ansiwise/programs',
      '--runs',
      '/var/lib/ansiwise/runs',
      '--mode',
      'dry',
      '--run',
      'probe',
    ]);
  });

  // THE INNOCENT CASE: a parent that was told nothing hands nothing on, so a caller standing where
  // every default resolves is left exactly as it was.
  test('a parent given no placement hands the child none', () async {
    final File child = aChildThatReportsItsArguments();

    await launcherWith(const <String>[]).start(program: ProgramName(child.path), mode: Mode.test);

    expect(await whatItWasHanded(), <String>['--mode', 'test', '--run', 'probe']);
  });

  // The placement stands BEFORE the mode, and the order is asserted rather than left to chance: a
  // process listing is read left to right, and where a run stands is what an operator looks for
  // first when two of them are going at once.
  test('the placement stands first, so a process listing says where the run stands', () async {
    final File child = aChildThatReportsItsArguments();

    await launcherWith(<String>[
      '--config',
      'ansiwise.yaml',
    ]).start(program: ProgramName(child.path), mode: Mode.run, resumes: const RunId('earlier'));

    final List<String> handed = await whatItWasHanded();
    expect(handed.indexOf('--config'), lessThan(handed.indexOf('--mode')));
    expect(handed, containsAllInOrder(<String>['--config', 'ansiwise.yaml', '--mode', 'run']));
    expect(handed, containsAllInOrder(<String>['--resume', 'earlier']));
  });
}
