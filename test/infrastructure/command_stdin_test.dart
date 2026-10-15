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

  group('elevation hands the password to sudo alone', () {
    late Directory temp;
    // A stand-in for sudo: under FIXTURE_POLICY=password it runs $SUDO_ASKPASS the way sudo and
    // sudo-rs do and checks the answer, under nopasswd it runs the command without asking, and under
    // refused it asks twice, as sudo does after a wrong password. While it asks, the password must
    // stand in no file of the temporary directory or the channel's: grep skips the pipe itself.
    const String sudo = r"""#!/bin/bash
[ "$1" = --askpass ] && [ "$2" = --reset-timestamp ] && [ "$3" = -- ] || exit 18
shift 3
case "$FIXTURE_POLICY" in
  password)
    grep -r -F -q -D skip fixture-password "$TMPDIR" "${SUDO_ASKPASS%/*}" && exit 21
    [ "$("$SUDO_ASKPASS" '')" = fixture-password ] || exit 19 ;;
  refused) "$SUDO_ASKPASS" '' >/dev/null; "$SUDO_ASKPASS" '' >/dev/null && exit 20; exit 1 ;;
esac
exec "$@"
""";

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('command-stdin-');
      await Directory('${temp.path}/bin').create();
      await Directory('${temp.path}/tmp').create();
      await File('${temp.path}/bin/sudo').writeAsString(sudo);
      await Process.run('chmod', <String>['700', '${temp.path}/bin/sudo']);
      await File('${temp.path}/runner.dart').writeAsString("""
import 'dart:io';
import 'package:ansiwise_core/ansiwise_core.dart';
Future<void> main() async {
  final result = await const RealShell(elevation: Elevation.of('fixture-password', from: 'test'))
    .run(const Command.detailed('cat', stdin: 'fixture-input', elevated: true, timeout: Duration(seconds: 5)));
  stdout.write(result.stdout);
  exitCode = result.exitCode;
}
""");
    });

    tearDown(() => temp.delete(recursive: true));

    Future<ProcessResult> elevate(String policy) => Process.run(
      Platform.resolvedExecutable,
      <String>[
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${temp.path}/runner.dart',
      ],
      environment: <String, String>{
        'PATH': '${temp.path}/bin:${Platform.environment['PATH']}',
        'TMPDIR': '${temp.path}/tmp',
        'FIXTURE_POLICY': policy,
      },
    );

    test('a policy that asks gets the password; the child gets only its input', () async {
      final ProcessResult result = await elevate('password');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, 'fixture-input');
      expect(Directory('${temp.path}/tmp').listSync(), isEmpty, reason: 'no channel is left');
    });

    test('a policy that does not ask never shows the child the password', () async {
      // PLANTED: sudo under NOPASSWD runs the command without reading anything.
      final ProcessResult result = await elevate('nopasswd');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, 'fixture-input');
      expect(result.stdout, isNot(contains('fixture-password')));
      expect(Directory('${temp.path}/tmp').listSync(), isEmpty, reason: 'no channel is left');
    });

    test('a second ask after a refused password fails at once instead of waiting', () async {
      final ProcessResult result = await elevate('refused');
      expect(result.exitCode, 1, reason: '${result.stderr}');
      expect(result.stdout, isNot(contains('fixture-password')));
      expect(Directory('${temp.path}/tmp').listSync(), isEmpty, reason: 'no channel is left');
    });
  });
}
