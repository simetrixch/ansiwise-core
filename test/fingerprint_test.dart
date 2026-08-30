import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// What makes two runs the same input, and what must therefore not be missing from it.
///
/// A real run is admitted only where a dry run of the same fingerprint came back green. Everything
/// a step can act on has to reach this hash, or the gate hands an operator a green verdict for a run
/// nobody performed — the one failure this framework must never produce, because it is discovered at
/// the moment it is relied on.
void main() {
  Registry registry() => registryOf(
    steps: <String, (String, Step Function(Arguments))>{
      'writes_a_file': (
        'x:1',
        (Arguments a) => WritesAFile(path: a.text('path'), content: a.text('content')),
      ),
    },
    arguments: <String, List<ArgumentSpec>>{
      'writes_a_file': const <ArgumentSpec>[
        ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file to write'),
        // One required and one with a default is what the forging case needs: the value of the
        // first can be made to end where the second's field would begin, and the second then
        // supplies the rest out of its own default.
        ArgumentSpec(
          name: 'content',
          kind: ArgumentKind.text,
          describes: 'what goes in it',
          required: false,
          defaultValue: 'three',
        ),
      ],
    },
  );

  /// A program declaring two answers, so a run can differ in one of them and nothing else.
  Program programWithAnswers({bool undo = true, String path = '/one'}) => Program(
    name: const ProgramName('p'),
    roles: <Role>[const Role('master')],
    answers: const DeclaredAnswers(<ArgumentSpec>[
      ArgumentSpec(name: 'fqdn', kind: ArgumentKind.text, describes: 'the domain'),
      ArgumentSpec(
        name: 'stage',
        kind: ArgumentKind.text,
        describes: 'which stage',
        required: false,
        defaultValue: 'dev',
      ),
    ]),
    steps: <ProgramStep>[
      ProgramStep(
        step: const StepName('writes_a_file'),
        onFailure: OnFailure.exit,
        arguments: Arguments(<String, Object>{'path': path}),
        undo: undo,
      ),
    ],
  );

  String fingerprintFor({
    Map<String, Object> answers = const <String, Object>{},
    bool undo = true,
    String path = '/one',
    String commit = 'abc',
  }) => fingerprintOf(
    program: ProgramResolver(registry()).resolve(programWithAnswers(undo: undo, path: path)),
    commit: commit,
    answers: Arguments(answers),
  );

  group('an answer WORKED OUT from another is in the input too', () {
    // This is the reason a derived answer is worked out before the first step rather than during
    // the run. A real run is admitted only where a dry run of the SAME fingerprint came back green,
    // and the fingerprint is built from the resolved program plus the answers. A value that came
    // into being later would be outside it, and a real run would be admitted against a dry run that
    // had used different values.
    Program withDerived() => const Program(
      name: ProgramName('p'),
      roles: <Role>[Role('master')],
      answers: DeclaredAnswers(<ArgumentSpec>[
        ArgumentSpec(name: 'fqdn', kind: ArgumentKind.text, describes: 'the domain'),
        ArgumentSpec(
          name: 'cluster_name',
          kind: ArgumentKind.text,
          describes: 'the short name',
          required: false,
          derivation: Derivation(rule: DerivationRule.firstDnsLabel, from: 'fqdn'),
        ),
      ]),
      steps: <ProgramStep>[
        ProgramStep(
          step: StepName('writes_a_file'),
          onFailure: OnFailure.exit,
          arguments: Arguments(<String, Object>{'path': '/one'}),
        ),
      ],
    );

    String forFqdn(String fqdn) {
      final Program program = withDerived();
      return fingerprintOf(
        program: ProgramResolver(registry()).resolve(program),
        commit: 'abc',
        answers: program.answers.validate(<String, Object?>{'fqdn': fqdn}, program: 'p'),
      );
    }

    test('two domains whose SHORT names differ do not share a fingerprint', () {
      expect(forFqdn('m1.example.com'), isNot(forFqdn('m2.example.com')));
    });

    test('the same domain twice gives the same fingerprint', () {
      expect(forFqdn('m1.example.com'), forFqdn('m1.example.com'));
    });

    test('the worked-out value is what differs, not only the domain it came from', () {
      // Two domains sharing a first label. If the derived answer were NOT in the material, these
      // two would still differ — because the domain itself is in it — so the case that proves the
      // derived value is carried is the one where the domains differ and something else must too.
      final Program program = withDerived();
      final Arguments answers = program.answers.validate(<String, Object?>{
        'fqdn': 'm1.example.com',
      }, program: 'p');

      expect(
        answers.text('cluster_name'),
        'm1',
        reason: 'the value the fingerprint carries is the one worked out, not the one supplied',
      );
      expect(answers.names, contains('cluster_name'));
    });
  });

  group('an answer that is the SECRET IN A FILE carries its PATH into the input, not its value', () {
    // The one derived answer that is NOT in the material, and the trade is written out here so a
    // reader meets it where they read what the gate covers. The value does not exist when this is
    // computed — the file is on the machine and this may run at a door somewhere else — so what
    // stands in for it is the answer naming the PATH, exactly as the WIRING stands in for a value
    // measured while the run happens.
    //
    // What it costs: a dry run proves the file was there and readable, not that the real run will
    // read the same text out of it. What it buys: a credential minted again between the two runs
    // does not leave the real run refused by the gate for ever.
    Program withSecretInAFile() => const Program(
      name: ProgramName('p'),
      roles: <Role>[Role('master')],
      answers: DeclaredAnswers(<ArgumentSpec>[
        ArgumentSpec(name: 'key_file', kind: ArgumentKind.text, describes: 'where it stands'),
        ArgumentSpec(
          name: 'auth_key',
          kind: ArgumentKind.text,
          describes: 'the credential in that file',
          required: false,
          derivation: Derivation(rule: DerivationRule.secretInFileAt, from: 'key_file'),
        ),
      ]),
      steps: <ProgramStep>[
        ProgramStep(
          step: StepName('writes_a_file'),
          onFailure: OnFailure.exit,
          arguments: Arguments(<String, Object>{'path': '/one'}),
        ),
      ],
    );

    String forKeyFile(String keyFile) {
      final Program program = withSecretInAFile();
      return fingerprintOf(
        program: ProgramResolver(registry()).resolve(program),
        commit: 'abc',
        answers: program.answers.validate(<String, Object?>{'key_file': keyFile}, program: 'p'),
      );
    }

    test('two runs reading DIFFERENT files do not share a fingerprint', () {
      // The wiring is covered: a program pointed at another file is another input, and a dry run of
      // the one may not admit a real run of the other.
      expect(forKeyFile('/tmp/one'), isNot(forKeyFile('/tmp/two')));
    });

    test('the same file twice gives the same fingerprint', () {
      expect(forKeyFile('/tmp/one'), forKeyFile('/tmp/one'));
    });

    test('THE PLANTED DEFECT: what the file HELD is in no part of the material', () {
      // The assertion that would go red if the value were ever worked into the answers here. It is
      // written as the value's absence rather than as two hashes being equal, because two hashes
      // built from the same absent value are equal for the uninteresting reason as well.
      final Program program = withSecretInAFile();
      final Arguments answers = program.answers.validate(<String, Object?>{
        'key_file': '/tmp/one',
      }, program: 'p');

      expect(answers.names, isNot(contains('auth_key')));
      expect(answers.text('key_file'), '/tmp/one');
    });
  });

  group("the operator's answers decide what a step does, so they are part of the input", () {
    test('two runs differing only in one answer do not share a fingerprint', () {
      // The scenario this closes: a dry run for one installation admitting a real run against
      // another. Steps take the branch name, the configuration file and the master from answers.
      expect(
        fingerprintFor(answers: <String, Object>{'fqdn': 'a.example'}),
        isNot(fingerprintFor(answers: <String, Object>{'fqdn': 'b.example'})),
      );
    });

    test('the same answers twice are one input', () {
      expect(
        fingerprintFor(answers: <String, Object>{'fqdn': 'a.example', 'stage': 'prod'}),
        fingerprintFor(answers: <String, Object>{'fqdn': 'a.example', 'stage': 'prod'}),
      );
    });

    test('the order they were given in is not part of the input', () {
      // An answer file listing them the other way round is the same run, and an operator repeating
      // a dry run over a reordered file would be repeating it for nothing.
      expect(
        fingerprintFor(answers: <String, Object>{'fqdn': 'a.example', 'stage': 'prod'}),
        fingerprintFor(answers: <String, Object>{'stage': 'prod', 'fqdn': 'a.example'}),
      );
    });

    test('an answer left out and an answer given as nothing are different inputs', () {
      // A step reads them differently on purpose — an empty domain is a domain somebody cleared,
      // and a missing one is a question nobody answered.
      expect(fingerprintFor(answers: <String, Object>{'fqdn': ''}), isNot(fingerprintFor()));
    });

    test("an answer's declared default is what an unanswered one hashes as", () {
      // Otherwise the gate would see a change where the run sees none: the step is handed the
      // default either way.
      expect(
        fingerprintFor(answers: <String, Object>{'fqdn': 'a.example'}),
        fingerprintFor(answers: <String, Object>{'fqdn': 'a.example', 'stage': 'dev'}),
      );
    });
  });

  group('what the run cannot take back is part of the input', () {
    test('the same row with its undo switched off is a different input', () {
      // A row whose undo is off moves the point of no return, and the operator read that boundary
      // off the dry run. Invisible here, it could be switched off behind a green one.
      expect(fingerprintFor(), isNot(fingerprintFor(undo: false)));
    });
  });

  group('a value cannot forge a field', () {
    /// A step whose REQUIRED argument sorts before its DEFAULTED one.
    ///
    /// That order is what the collision needs: the required value is written first and can be made
    /// to end where the next field would begin, and the defaulted one then supplies the rest out of
    /// its own default without anybody writing it.
    Registry forging() => registryOf(
      steps: <String, (String, Step Function(Arguments))>{
        'writes_a_file': (
          'x:1',
          (Arguments a) => WritesAFile(path: a.text('b'), content: a.text('a')),
        ),
      },
      arguments: <String, List<ArgumentSpec>>{
        'writes_a_file': const <ArgumentSpec>[
          ArgumentSpec(name: 'a', kind: ArgumentKind.text, describes: 'what goes in the file'),
          ArgumentSpec(
            name: 'b',
            kind: ArgumentKind.text,
            describes: 'the file',
            required: false,
            defaultValue: 'three',
          ),
        ],
      },
    );

    String forOf(Map<String, Object> arguments) => fingerprintOf(
      program: ProgramResolver(forging()).resolve(
        Program(
          name: const ProgramName('p'),
          roles: <Role>[const Role('master')],
          steps: <ProgramStep>[
            ProgramStep(
              step: const StepName('writes_a_file'),
              onFailure: OnFailure.exit,
              arguments: Arguments(arguments),
            ),
          ],
        ),
      ),
      commit: 'abc',
      answers: Arguments.none,
    );

    test('two different inputs that would write the same lines are different', () {
      // The collision this closes, as it would look written one `<field>=<value>` line each. The
      // injected text spells the field name the material actually uses, so this measures the length
      // prefix and not the choice of name — a name a value cannot guess is not a guarantee, it is
      // an obstacle, and the next name somebody picks would be guessable again.
      //
      //   left    argument.a = one, newline, argument.b=two   b left out, so its default three
      //   right   argument.a = one                            b = two, newline, argument.b=three
      //
      // Both then read: argument.a=one / argument.b=two / argument.b=three. Two runs writing a
      // different file with different text, one hash, and the gate admits the second on the first's
      // dry run. Both values are ordinary quoted YAML scalars.
      final String left = forOf(<String, Object>{'a': 'one\nargument.b=two'});
      final String right = forOf(<String, Object>{'a': 'one', 'b': 'two\nargument.b=three'});

      expect(left, isNot(right));
    });

    test('a value that looks like a length prefix is still one value', () {
      // The same attack against the notation that replaced it: the length is written in front of
      // the value, so a value beginning with digits and a colon must not be read as one.
      expect(forOf(<String, Object>{'a': '5:/one'}), isNot(forOf(<String, Object>{'a': '/one'})));
    });
  });

  group('a list is a list, and not the text it prints as', () {
    /// A step taking a list of text, so two runs can differ only in where one entry ends.
    Registry listing() => registryOf(
      steps: <String, (String, Step Function(Arguments))>{
        'writes_a_file': (
          'x:1',
          (Arguments a) => WritesAFile(path: a.textList('commands').join('|'), content: ''),
        ),
      },
      arguments: <String, List<ArgumentSpec>>{
        'writes_a_file': const <ArgumentSpec>[
          ArgumentSpec(
            name: 'commands',
            kind: ArgumentKind.textList,
            describes: 'the commands a gate demands',
          ),
        ],
      },
    );

    String forList(List<String> commands) => fingerprintOf(
      program: ProgramResolver(listing()).resolve(
        Program(
          name: const ProgramName('p'),
          roles: <Role>[const Role('master')],
          steps: <ProgramStep>[
            ProgramStep(
              step: const StepName('writes_a_file'),
              onFailure: OnFailure.exit,
              arguments: Arguments(<String, Object>{'commands': commands}),
            ),
          ],
        ),
      ),
      commit: 'abc',
      answers: Arguments.none,
    );

    test('two entries and one entry holding the separator are different inputs', () {
      // Written through toString both are the text `[first, second]`: a gate demanding two commands
      // and a gate demanding one tool whose name contains a comma. Two different runs, one hash,
      // and the second is admitted on the first's dry run.
      expect(forList(<String>['first', 'second']), isNot(forList(<String>['first, second'])));
    });

    test('one empty entry and no entry at all are different inputs', () {
      expect(forList(<String>['']), isNot(forList(<String>[])));
    });

    test('the same list twice is one input', () {
      expect(forList(<String>['first', 'second']), forList(<String>['first', 'second']));
    });

    test('the order of the entries is part of the input', () {
      // A list is ordered on purpose: the words a command is started with, the value files a render
      // layers. Two orders are two runs.
      expect(forList(<String>['first', 'second']), isNot(forList(<String>['second', 'first'])));
    });
  });

  group('a mapping is a mapping, and not the text it prints as', () {
    /// A step taking a mapping, so two runs can differ only in where one entry ends.
    Registry filling() => registryOf(
      steps: <String, (String, Step Function(Arguments))>{
        'fills': ('x:1', FillsSlotsFromAMapping.fromArguments),
      },
      arguments: <String, List<ArgumentSpec>>{'fills': FillsSlotsFromAMapping.arguments},
    );

    String forMapping(Map<String, Object?> values) => fingerprintOf(
      program: ProgramResolver(filling()).resolve(
        Program(
          name: const ProgramName('p'),
          roles: <Role>[const Role('master')],
          steps: <ProgramStep>[
            ProgramStep(
              step: const StepName('fills'),
              onFailure: OnFailure.exit,
              arguments: Arguments(<String, Object>{
                'path': '/one',
                'template': 'a=<a> b=<b>',
                'values': values,
              }),
            ),
          ],
        ),
      ),
      commit: 'abc',
      answers: Arguments.none,
    );

    test('two entries and one entry holding the separator are different inputs', () {
      // Written through toString both are the text `{a: x, b: y}`: a text with two slots filled, and
      // a text with ONE slot whose value happens to contain a comma and a colon. Two different files
      // get written, one hash, and the second is admitted on the first's dry run. This is the list
      // case above one level up, and a mapping needs its own boundary for the same reason.
      expect(
        forMapping(const <String, Object?>{'a': 'x', 'b': 'y'}),
        isNot(forMapping(const <String, Object?>{'a': 'x, b: y'})),
      );
    });

    test('one empty entry and no entry at all are different inputs', () {
      expect(
        forMapping(const <String, Object?>{'a': ''}),
        isNot(forMapping(const <String, Object?>{})),
      );
    });

    test('the same mapping twice is one input', () {
      expect(
        forMapping(const <String, Object?>{'a': 'x', 'b': 'y'}),
        forMapping(const <String, Object?>{'a': 'x', 'b': 'y'}),
      );
    });

    test('the order the entries were written in is not part of the input', () {
      // A mapping is named slots, and a step reads them by name. A file listing them the other way
      // round is the same run, exactly as an answer file listing its answers in another order is.
      expect(
        forMapping(const <String, Object?>{'a': 'x', 'b': 'y'}),
        forMapping(const <String, Object?>{'b': 'y', 'a': 'x'}),
      );
    });
  });

  group('what stays out of it', () {
    test('the commit is in, because the same program at another commit is other steps', () {
      expect(fingerprintFor(commit: 'abc'), isNot(fingerprintFor(commit: 'def')));
    });
  });
}
