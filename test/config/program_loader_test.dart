import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';

/// A program file is data, and everything that is not data is refused by name and with its line.
///
/// The loader reads keys and values and nothing else. What it cannot recognise it refuses, and it
/// refuses all of it at once — an operator fixing a file one problem per run is an operator running
/// it five times to learn five things.
void main() {
  Matcher refusesWith(Object matcher) =>
      throwsA(isA<ProgramInvalid>().having((ProgramInvalid e) => e.message, 'message', matcher));

  group('a program that adds up', () {
    const String source = '''
name: deploy-cluster
roles: [master, slave]
steps:
  - step: write_config_file
    channel: "1.34/stable"
    on_failure: exit
  - step: enable_addons
    addons: [dns, hostpath-storage, ingress]
    retries: 3
    on_failure: exit
  - step: configure_public_source_routing
    when: [has_two_nics]
    on_failure: continue
''';

    test('reads the name, the roles and every entry in order', () {
      final Program program = loadProgram(source, where: 'deploy-cluster.yaml');

      expect(program.name.value, 'deploy-cluster');
      expect(program.roles.map((Role r) => r.value), <String>['master', 'slave']);
      expect(program.steps.map((ProgramStep s) => s.step.value), <String>[
        'write_config_file',
        'enable_addons',
        'configure_public_source_routing',
      ]);
      expect(program.appliesTo(const Role('slave')), isTrue);
      // The union role: a machine doing both jobs is each of them, so a program declared for
      // either part applies to it — and a role sharing no part still does not.
      expect(program.appliesTo(const Role('master+slave')), isTrue);
      expect(program.appliesTo(const Role('workstation')), isFalse);
    });

    test('reads the failure policy of every entry, and there is no default to fall back on', () {
      final Program program = loadProgram(source, where: 'deploy-cluster.yaml');

      expect(program.steps.map((ProgramStep s) => s.onFailure), <OnFailure>[
        OnFailure.exit,
        OnFailure.exit,
        OnFailure.continueRun,
      ]);
    });

    test('reads the conditions behind when, and leaves an entry without one empty', () {
      final Program program = loadProgram(source, where: 'deploy-cluster.yaml');

      expect(program.steps.first.when, isEmpty);
      expect(program.steps.last.when.single.value, 'has_two_nics');
    });

    test('gives every other key to the step, typed as YAML gave it', () {
      final Program program = loadProgram(source, where: 'deploy-cluster.yaml');

      expect(program.steps[0].arguments.text('channel'), '1.34/stable');
      expect(program.steps[1].arguments.integer('retries'), 3);
      expect(program.steps[1].arguments.textList('addons'), <String>[
        'dns',
        'hostpath-storage',
        'ingress',
      ]);
      expect(
        program.steps[1].arguments.raw('addons'),
        isA<List<String>>(),
        reason: 'a list argument has to satisfy ArgumentSpec.accepts for textList',
      );
    });

    test('a true or false argument stays true or false', () {
      final Program program = loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    classic: true
    on_failure: exit
''', where: 'p.yaml');

      expect(program.steps.single.arguments.flag('classic'), isTrue);
    });
  });

  group('the file itself', () {
    test('YAML that does not parse is refused rather than thrown raw', () {
      expect(
        () => loadProgram('name: [a, b\n', where: 'broken.yaml'),
        refusesWith(contains('expected')),
      );
    });

    test('the refusal of unparseable YAML carries its line', () {
      expect(
        () => loadProgram('name: [a, b\n', where: 'broken.yaml'),
        refusesWith(contains('line ')),
      );
    });

    test('a duplicate key is refused', () {
      expect(
        () => loadProgram('name: a\nname: b\nroles: [master]\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('Duplicate mapping key')),
      );
    });

    test('an empty file is refused', () {
      expect(() => loadProgram('', where: 'p.yaml'), refusesWith(contains('a program is a map')));
    });

    test('a file that is not a map is refused', () {
      expect(
        () => loadProgram('- one\n- two\n', where: 'p.yaml'),
        refusesWith(contains('a program is a map')),
      );
    });

    test('the file it came from is what the refusal is reported against', () {
      try {
        loadProgram('', where: 'deploy-cluster.yaml');
        fail('the file must be refused');
      } on ProgramInvalid catch (refused) {
        expect(refused.where, 'deploy-cluster.yaml');
        expect(refused.toString(), startsWith('deploy-cluster.yaml: '));
      }
    });

    test('a key nobody declared is refused rather than ignored', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
stpes:
  - step: write_config_file
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('a program does not have a key "stpes"')),
      );
    });
  });

  group('anchors and aliases', () {
    test('an alias is refused, because it lets one part of the file stand for another', () {
      expect(
        () => loadProgram('''
name: p
roles: &roles [master]
steps:
  - step: write_config_file
    hosts: *roles
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('an anchor or alias')),
      );
    });

    test('an anchor nobody refers to is refused too', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    channel: &channel "1.34/stable"
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('line 5: an anchor or alias')),
      );
    });

    test('a merge key is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
defaults: &defaults
  on_failure: exit
steps:
  - step: write_config_file
    <<: *defaults
''', where: 'p.yaml'),
        refusesWith(contains('an anchor or alias')),
      );
    });
  });

  group('name', () {
    test('a missing name is refused', () {
      expect(
        () => loadProgram('roles: [master]\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('the file has no "name"')),
      );
    });

    test('a name that is not text is refused, and the refusal says what was given', () {
      expect(
        () => loadProgram('name: 7\nroles: [master]\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('"name" is text, and the file gives a whole number')),
      );
    });

    test('a name of the wrong shape is refused', () {
      expect(
        () => loadProgram('name: Deploy_Cluster\nroles: [master]\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('"Deploy_Cluster" is not a program name')),
      );
    });
  });

  group('roles', () {
    test('missing roles are refused', () {
      expect(
        () => loadProgram('name: p\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('the file has no "roles"')),
      );
    });

    test('roles that are not a list are refused', () {
      expect(
        () => loadProgram('name: p\nroles: master\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('"roles" is a list of role names, and the file gives text')),
      );
    });

    test('an empty roles list is refused, because no machine would match it', () {
      expect(
        () => loadProgram('name: p\nroles: []\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('"roles" is empty')),
      );
    });

    test('a role that is not text is refused', () {
      expect(
        () => loadProgram('name: p\nroles: [master, 7]\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('"roles" holds role names, and the file gives a whole number')),
      );
    });
  });

  group('steps', () {
    test('missing steps are refused', () {
      expect(
        () => loadProgram('name: p\nroles: [master]\n', where: 'p.yaml'),
        refusesWith(contains('the file has no "steps"')),
      );
    });

    test('a program with no steps is refused', () {
      expect(
        () => loadProgram('name: p\nroles: [master]\nsteps: []\n', where: 'p.yaml'),
        refusesWith(contains('"steps" is empty, and a program with no steps does nothing')),
      );
    });

    test('steps that are not a list are refused', () {
      expect(
        () => loadProgram('name: p\nroles: [master]\nsteps: go\n', where: 'p.yaml'),
        refusesWith(contains('"steps" is a list of entries, and the file gives text')),
      );
    });

    test('an entry that is not a map is refused, by its position', () {
      expect(
        () => loadProgram(
          'name: p\nroles: [master]\nsteps:\n  - write_config_file\n',
          where: 'p.yaml',
        ),
        refusesWith(contains('steps[0] is not a map')),
      );
    });

    test('an entry with no step key is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('steps[0] has no "step"')),
      );
    });

    test('a step name of the wrong shape is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: Copy-Files
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"Copy-Files" is not a step name')),
      );
    });

    test('a step name that is not text is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: [a]
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"step" is text, and the file gives a list')),
      );
    });
  });

  group('on_failure', () {
    test('a missing failure policy is refused — there is no default', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
''', where: 'p.yaml'),
        refusesWith(
          contains('steps[0] write_config_file has no "on_failure" — say exit or continue'),
        ),
      );
    });

    test('a failure policy outside the three is refused, and the refusal lists them', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    on_failure: abort
''', where: 'p.yaml'),
        refusesWith(contains('"on_failure" is "abort", and it is exit or continue')),
      );
    });

    test('a failure policy that is not text is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    on_failure: true
''', where: 'p.yaml'),
        refusesWith(contains('"on_failure" is exit or continue, and the file gives true or false')),
      );
    });
  });

  group('when', () {
    test('a when that is not a list is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    when: has_two_nics
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"when" is a list of predicate names, and the file gives text')),
      );
    });

    test('a when holding something that is not text is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    when: [7]
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"when" holds predicate names, and the file gives a whole number')),
      );
    });

    test('a predicate name of the wrong shape is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    when: [HasTwoNics]
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"HasTwoNics" is not a predicate name')),
      );
    });
  });

  group('keep_output', () {
    test('a row that says it carries it, and a row that does not stays quiet', () {
      final Program program = loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    keep_output: true
    on_failure: exit
  - step: write_config_file
    on_failure: exit
''', where: 'p.yaml');

      expect(program.steps.first.keepsOutput, isTrue);
      expect(program.steps.last.keepsOutput, isFalse, reason: 'output is noise unless a row says');
    });

    test('it is a key of the row, not an argument handed to the step', () {
      final Program program = loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    keep_output: true
    on_failure: exit
''', where: 'p.yaml');

      expect(
        program.steps.single.arguments.has('keep_output'),
        isFalse,
        reason: 'as an argument it would be refused against every step that does not declare it',
      );
    });

    test('a value that is not true or false is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    keep_output: always
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"keep_output" is true or false, and the file gives text')),
      );
    });
  });

  group('an argument taking its value from a measurement', () {
    test('the row says which argument takes which measurement', () {
      final Program program = loadProgram('''
name: p
roles: [master]
steps:
  - step: detect_backend
    on_failure: exit
  - step: align_backend
    namespace: kube-system
    backend: {measured: host.iptables_backend}
    on_failure: exit
''', where: 'p.yaml');

      final ProgramStep row = program.steps.last;
      expect(row.reads, <String, MeasurementName>{
        'backend': const MeasurementName('host.iptables_backend'),
      });
      expect(
        row.arguments.has('backend'),
        isFalse,
        reason: 'a value the file does not hold is not among the values the file wrote',
      );
      expect(row.arguments.text('namespace'), 'kube-system');
    });

    test('a name of the wrong shape is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: align_backend
    backend: {measured: Host.Backend}
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('takes "Host.Backend", and that is not a measurement name')),
      );
    });

    test('a name that is not text is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: align_backend
    backend: {measured: 7}
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"backend" takes a measurement, and its name is text')),
      );
    });

    test('a second key beside it is refused, because a slot is not an expression', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: align_backend
    backend: {measured: host.backend, unless: something}
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(
          allOf(
            contains('"backend" takes a measurement'),
            contains('{measured: <name>} is the whole of it'),
          ),
        ),
      );
    });

    test('one inside a list is refused, so nothing can be composed out of parts', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: align_backend
    servers: ["10.0.0.1", {measured: host.resolvers}]
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('the list "servers" holds text, and one entry is a map')),
      );
    });

    test('a program-wide default cannot be one, because a default is a value', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
defaults:
  backend: {measured: host.backend}
steps:
  - step: align_backend
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(
          allOf(
            contains('"backend" takes a measurement'),
            contains('{measured: <name>} is the whole of it'),
          ),
        ),
      );
    });
  });

  group('arguments', () {
    test('an argument with no value is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    channel:
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('"channel" has no value')),
      );
    });

    test('a map that is not a measurement is READ, and the argument check decides', () {
      // The law changed when a step gained the ability to declare an argument that holds a mapping
      // — a name on the left and a small declaration under it. The loader has no registry, so it
      // cannot know whether THIS argument may hold one; what it can do is read the shape and leave
      // the judgement to the check that knows the step. A loader that refused every map would make
      // the kind undeclarable from a file.
      final Program program = loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    channel:
      track: {answer: stage}
    on_failure: exit
''', where: 'p.yaml');

      expect(program.steps.single.arguments.raw('channel'), <String, Object?>{
        'track': <String, Object?>{'answer': 'stage'},
      });
    });

    test('and a mapping the step does not declare is refused, naming the step and the key', () {
      // The other half, and without it the change above would be a hole: the judgement moved, it
      // did not disappear.
      expect(
        () =>
            ProgramResolver(
              registryOf(
                steps: <String, (String, Step Function(Arguments))>{
                  'write_config_file': ('x:1', (Arguments a) => const Blocks('never runs')),
                },
                arguments: <String, List<ArgumentSpec>>{
                  'write_config_file': <ArgumentSpec>[
                    const ArgumentSpec(
                      name: 'channel',
                      kind: ArgumentKind.text,
                      describes: 'a channel',
                    ),
                  ],
                },
              ),
            ).resolve(
              loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    channel:
      track: {answer: stage}
    on_failure: exit
''', where: 'p.yaml'),
            ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid refused) => refused.message,
            'message',
            allOf(contains('write_config_file'), contains('channel')),
          ),
        ),
      );
    });

    test('a list argument holding something that is not text is refused', () {
      expect(
        () => loadProgram('''
name: p
roles: [master]
steps:
  - step: enable_addons
    addons: [dns, 7]
    on_failure: exit
''', where: 'p.yaml'),
        refusesWith(contains('the list "addons" holds text, and one entry is a whole number')),
      );
    });
  });

  group('reporting', () {
    test('every problem is reported at once, not one run at a time', () {
      try {
        loadProgram('''
name: Deploy_Cluster
roles: []
steps:
  - step: Install
    on_failure: abort
''', where: 'p.yaml');
        fail('the file must be refused');
      } on ProgramInvalid catch (refused) {
        expect(refused.message, contains('is not a program name'));
        expect(refused.message, contains('"roles" is empty'));
        expect(refused.message, contains('is not a step name'));
        expect(refused.message, contains('is exit or continue'));
        expect(refused.message.split('\n'), hasLength(4));
      }
    });

    test('the problems read down the file, and not in the order they were found', () {
      try {
        loadProgram('''
name: Deploy_Cluster
roles: []
steps:
  - step: write_config_file
    channel: &channel "1.34/stable"
    on_failure: exit
''', where: 'p.yaml');
        fail('the file must be refused');
      } on ProgramInvalid catch (refused) {
        expect(refused.message.split('\n').map((String line) => line.split(':').first), <String>[
          'line 1',
          'line 2',
          'line 5',
        ]);
      }
    });

    test('every problem carries the line it is on', () {
      try {
        loadProgram('''
name: p
roles: [master]
steps:
  - step: Install
    on_failure: abort
''', where: 'p.yaml');
        fail('the file must be refused');
      } on ProgramInvalid catch (refused) {
        expect(refused.message, contains('line 4: '));
        expect(refused.message, contains('line 5: '));
      }
    });

    test('a bad entry does not stop the ones after it from being read', () {
      try {
        loadProgram('''
name: p
roles: [master]
steps:
  - step: write_config_file
    on_failure: abort
  - step: enable_addons
    when: [HasTwoNics]
    on_failure: exit
''', where: 'p.yaml');
        fail('the file must be refused');
      } on ProgramInvalid catch (refused) {
        expect(refused.message, contains('"on_failure" is "abort"'));
        expect(refused.message, contains('"HasTwoNics" is not a predicate name'));
      }
    });
  });
}
