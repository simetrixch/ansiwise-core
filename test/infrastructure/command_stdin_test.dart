import 'dart:async';
import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';
import 'package:test/test.dart';

void main() {
  const RealShell shell = RealShell(elevation: Elevation.unconfigured());
  const String input =
      'private-input\n'
      r'quotes "$" and unicode: ü'
      '\n';

  test('stdin reaches the process intact and EOF closes it', () async {
    final CommandResult result = await shell.run(
      const Command.detailed('cat', stdin: input, timeout: Duration(seconds: 5)),
    );
    expect(result.ok, isTrue);
    expect(result.stdout, input);
    expect(const Command('cat').stdin, isNull);
    final CommandResult empty = await shell.run(
      const Command.detailed('cat', timeout: Duration(seconds: 5)),
    );
    expect(empty.stdout, isEmpty);
  });

  test('large stdin and output are drained concurrently', () async {
    final String large = List<String>.filled(100000, input).join();
    final CommandResult result = await shell.run(
      Command.detailed('cat', stdin: large, timeout: const Duration(seconds: 5)),
    );
    expect(result.stdout, large);
  });

  test('timeout also bounds a process that never reads its large input', () async {
    await expectLater(
      shell.run(
        Command.detailed(
          'sleep',
          arguments: const <String>['10'],
          stdin: List<String>.filled(100000, input).join(),
          timeout: const Duration(milliseconds: 100),
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a failed process retains its exit code even if it rejects stdin', () async {
    final CommandResult result = await shell.run(
      Command.detailed(
        'false',
        stdin: List<String>.filled(100000, input).join(),
        timeout: const Duration(seconds: 5),
      ),
    );
    expect(result.exitCode, 1);
  });

  test('a successful exit cannot hide undelivered input', () async {
    await expectLater(
      shell.run(
        Command.detailed(
          'true',
          stdin: List<String>.filled(100000, input).join(),
          timeout: const Duration(seconds: 5),
        ),
      ),
      throwsA(isA<InputUndelivered>()),
    );
  });

  test('input a child inherits after its parent exited is delivered whole or refused', () async {
    final Directory temp = await Directory.systemTemp.createTemp('command-stdin-');
    try {
      final String count = '${temp.path}/count';
      // The started process exits at once; the child it forked reads its input 300 ms later.
      Command reader(int bytes) => Command.detailed(
        'python3',
        arguments: <String>[
          '-c',
          'import os, sys, time\n'
              'if os.fork() == 0:\n'
              '    time.sleep(0.3)\n'
              '    open(sys.argv[1], "w").write(str(len(sys.stdin.buffer.read())))\n'
              '    os._exit(0)\n'
              'os._exit(0)\n',
          count,
        ],
        stdin: 'x' * bytes,
        timeout: const Duration(seconds: 5),
      );
      // PLANTED: a million bytes exceed the pipe, and Dart cuts what the child had not read yet.
      await expectLater(shell.run(reader(1000000)), throwsA(isA<InputUndelivered>()));
      // Innocent: an input the pipe holds reaches the late reader whole.
      expect((await shell.run(reader(1000))).exitCode, 0);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await File(count).readAsString(), '1000');
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('dry mode refuses mutation with stdin; an observing read preserves it', () async {
    final FakeShell fake = FakeShell();
    final PlanningShell planning = PlanningShell(fake, step: const StepName('exchange'));
    await expectLater(
      () => planning.run(const Command.detailed('tool', stdin: input)),
      throwsA(isA<MutationRefused>()),
    );
    expect(fake.ran, isEmpty);
    await planning.run(const Command.observing('tool', stdin: input, secretOutput: true));
    expect(fake.commands.single.stdin, input);
    expect(fake.commands.single.argv, <String>['tool']);
  });

  test('elevation consumes its password line and passes only stdin to the child', () async {
    final Directory temp = await Directory.systemTemp.createTemp('command-stdin-');
    try {
      final File sudo = File('${temp.path}/sudo');
      await sudo.writeAsString(r'''#!/bin/bash
IFS= read -r password
[ "$password" = fixture-password ] || exit 19
while [ "$1" != -- ]; do shift; done
shift
exec "$@"
''');
      await Process.run('chmod', <String>['700', sudo.path]);
      final File runner = File('${temp.path}/runner.dart');
      await runner.writeAsString("""
import 'dart:io';
import 'package:ansiwise_core/ansiwise_core.dart';
Future<void> main() async {
  final result = await const RealShell(elevation: Elevation.of('fixture-password', from: 'test'))
    .run(const Command.detailed('cat', stdin: 'fixture-input', elevated: true, timeout: Duration(seconds: 5)));
  stdout.write(result.stdout);
  exitCode = result.exitCode;
}
""");
      final ProcessResult result = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          runner.path,
        ],
        environment: <String, String>{'PATH': '${temp.path}:${Platform.environment['PATH']}'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, 'fixture-input');
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
