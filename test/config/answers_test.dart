import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

/// What a program has to be told before it runs, and what happens when it is told the wrong thing.
///
/// This is what makes the client agnostic: the app renders a form out of these declarations and
/// hard-codes no field, so an input added to a program file appears in the app without a line
/// changing there, and an app in front of a different plugin shows that plugin's questions.
void main() {
  Program load(String yaml) => loadProgram(yaml, where: 'test.yaml');

  // A program with no steps at all is refused by the loader, and rightly: it would do nothing. The
  // step name here is never resolved — loadProgram parses, and binding to the registry is later.
  const String head =
      'name: deploy-thing\nroles: [master]\nsteps:\n  - step: a_step\n    on_failure: exit\n';

  group('the condition an answer is stated under', () {
    test('is one registered name, and nothing that compares', () {
      final Program program = load(
        '${head}answers:\n'
        '  - name: db_host\n'
        '    kind: text\n'
        '    describes: the database host\n'
        '    stated_when: {predicate: a_database_is_wanted}\n',
      );

      expect(program.answers.specs.single.statedWhen?.predicate, 'a_database_is_wanted');
    });

    test('THE PLANTED DEFECT: a comparison written in the file is refused', () {
      // The shape this replaced. A file that can compare two values can compare anything, and then
      // what an operator debugs is the file — so the loader refuses it rather than reading it.
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: use_db\n'
          '    kind: flag\n'
          '    describes: whether to use a db\n'
          '  - name: db_host\n'
          '    kind: text\n'
          '    describes: the database host\n'
          '    stated_when: {answer: use_db, equals: "true"}\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid each) => each.message,
            'message',
            allOf(contains('stated_when'), contains('registered condition')),
          ),
        ),
      );
    });

    test('a second key beside the name is refused too', () {
      // Half a comparison is still a comparison, and reading it would let the shape back in through
      // a key nobody declared.
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: db_host\n'
          '    kind: text\n'
          '    describes: the database host\n'
          '    stated_when: {predicate: a_thing, equals: "true"}\n',
        ),
        throwsA(isA<ProgramInvalid>()),
      );
    });
  });

  group('declaring them', () {
    test('reads a declaration in the order the file wrote it', () {
      final Program program = load(
        '${head}answers:\n'
        '  - name: fqdn\n'
        '    kind: text\n'
        '    describes: the domain name this installation is reached under\n'
        '  - name: workers\n'
        '    kind: integer\n'
        '    describes: how many workers to run\n',
      );

      expect(program.answers.specs.map((ArgumentSpec s) => s.name), <String>['fqdn', 'workers']);
      expect(program.answers.specs.first.kind, ArgumentKind.text);
      expect(program.answers.specs.last.kind, ArgumentKind.integer);
    });

    test('a program that declares nothing needs nothing', () {
      expect(load(head).answers.specs, isEmpty);
    });

    test('names the secret ones', () {
      final Program program = load(
        '${head}answers:\n'
        '  - name: fqdn\n    kind: text\n    describes: the domain\n'
        '  - name: repo_pat\n    kind: text\n    describes: a credential\n    secret: true\n',
      );

      expect(program.answers.secretNames, <String>['repo_pat']);
    });

    test('refuses a secret with a default', () {
      // A default for a secret is a credential written into a file that ships to every
      // installation, which is the one thing this must never make easy.
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: repo_pat\n    kind: text\n    describes: a credential\n'
          '    secret: true\n    default: hunter2\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('is secret, so it cannot have a default'),
          ),
        ),
      );
    });

    test('refuses a declaration with no describes, because the form would show a bare name', () {
      expect(
        () => load('${head}answers:\n  - name: fqdn\n    kind: text\n'),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('it is what the form shows the operator'),
          ),
        ),
      );
    });

    test('reads an answer that is the secret in a file, and calls it secret unasked', () {
      // The whole point of the rule saying it rather than the file: an answer worked out from a
      // file on the machine holds a value nobody typed, and one program file forgetting the word
      // would be one word between a credential and a record every account may read.
      final Program program = load(
        '${head}answers:\n'
        '  - name: key_file\n    kind: text\n    describes: where the credential stands\n'
        '  - name: auth_key\n    kind: text\n    required: false\n'
        '    derived: secret_in_file_at\n    from: key_file\n'
        '    describes: the credential the earlier run left in that file\n',
      );

      expect(program.answers.specs.last.derivation?.rule, DerivationRule.secretInFileAt);
      expect(program.answers.secretNames, <String>['auth_key']);
      expect(program.answers.secretNamesInFiles, <String>['auth_key']);
    });

    test('THE INNOCENT NEIGHBOUR: an answer worked out from TEXT is not called secret', () {
      // Without this, a version that called every derived answer secret would satisfy the test
      // above and turn ordinary worked-out values into markers all through a record.
      final Program program = load(
        '${head}answers:\n'
        '  - name: fqdn\n    kind: text\n    describes: the domain\n'
        '  - name: cluster_name\n    kind: text\n    required: false\n'
        '    derived: first_dns_label_of\n    from: fqdn\n    describes: the short name\n',
      );

      expect(program.answers.secretNames, isEmpty);
      expect(program.answers.secretNamesInFiles, isEmpty);
    });

    test(
      'THE PLANTED DEFECT: writing "secret" beside that rule is refused as the same fact twice',
      () {
        expect(
          () => load(
            '${head}answers:\n'
            '  - name: key_file\n    kind: text\n    describes: where the credential stands\n'
            '  - name: auth_key\n    kind: text\n    required: false\n    secret: true\n'
            '    derived: secret_in_file_at\n    from: key_file\n    describes: the credential\n',
          ),
          throwsA(
            isA<ProgramInvalid>().having(
              (ProgramInvalid p) => p.message,
              'message',
              allOf(contains('is the secret in a file'), contains('written twice')),
            ),
          ),
        );
      },
    );

    test('and writing it beside a rule that works out TEXT is refused in the other words', () {
      // The two refusals say opposite things about the same key, and each has to be the one the
      // reader of that declaration actually needs. Told "it is not a secret" about an answer that
      // is one, they would take the word out and ship the credential in the clear.
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: fqdn\n    kind: text\n    describes: the domain\n'
          '  - name: cluster_name\n    kind: text\n    required: false\n    secret: true\n'
          '    derived: first_dns_label_of\n    from: fqdn\n    describes: the short name\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('is worked out from another answer, so it is not a secret'),
          ),
        ),
      );
    });

    test('THE PLANTED DEFECT: a "default" beside a rule is refused, because it would always win', () {
      // Nobody supplies a derived answer, so a default stands in on every run and the rule is never
      // read. Beside the rule that reads a credential off the machine, that is a literal in a file
      // shipped to every installation standing where the machine's own value belongs.
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: key_file\n    kind: text\n    describes: where the credential stands\n'
          '  - name: auth_key\n    kind: text\n    required: false\n    default: nothing-real\n'
          '    derived: secret_in_file_at\n    from: key_file\n    describes: the credential\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('the rule would never be read'),
          ),
        ),
      );
    });

    test('THE INNOCENT NEIGHBOUR: a default on an answer nobody works out is still read', () {
      // Without this, a version that refused every default would satisfy the test above and take
      // every optional answer in every program file with it.
      final Program program = load(
        '${head}answers:\n'
        '  - name: workers\n    kind: integer\n    required: false\n    default: 3\n'
        '    describes: how many\n',
      );

      expect(program.answers.specs.single.defaultValue, 3);
    });

    test('refuses two declarations under one name', () {
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: fqdn\n    kind: text\n    describes: one\n'
          '  - name: fqdn\n    kind: integer\n    describes: two\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('declared twice'),
          ),
        ),
      );
    });

    test('refuses an unknown kind, and says which kinds there are', () {
      expect(
        () => load(
          '${head}answers:\n  - name: fqdn\n    kind: hostname\n    describes: the domain\n',
        ),
        throwsA(
          isA<ProgramInvalid>()
              .having((ProgramInvalid p) => p.message, 'message', contains('needs a "kind"'))
              .having((ProgramInvalid p) => p.message, 'message', contains('text')),
        ),
      );
    });

    test('refuses a key nobody declared rather than ignoring it', () {
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: fqdn\n    kind: text\n    describes: the domain\n    hidden: true\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('has no key "hidden"'),
          ),
        ),
      );
    });

    test('refuses a default of the wrong kind', () {
      expect(
        () => load(
          '${head}answers:\n  - name: workers\n    kind: integer\n'
          '    describes: how many\n    default: many\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('holds integer'),
          ),
        ),
      );
    });

    test('reads the values an answer may hold', () {
      final Program program = load(
        '${head}answers:\n'
        '  - name: role\n    kind: text\n    allowed: [master, slave]\n'
        '    describes: what this machine is\n',
      );

      expect(program.answers.specs.single.allowed, <String>['master', 'slave']);
    });

    test('an answer with no closed set permits anything of its kind', () {
      final Program program = load(
        '${head}answers:\n  - name: fqdn\n    kind: text\n    describes: the domain\n',
      );

      expect(program.answers.specs.single.allowed, isEmpty);
      expect(program.answers.specs.single.permits('anything at all'), isTrue);
    });

    test('only text may name allowed values', () {
      // A flag already has two values, and a number or a list of text has no small closed set worth
      // writing out — so declaring one there is a mistake, refused rather than quietly ignored.
      expect(
        () => load(
          '${head}answers:\n  - name: workers\n    kind: integer\n'
          '    allowed: ["1", "2"]\n    describes: how many\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('only text may name allowed values'),
          ),
        ),
      );
    });

    test('refuses an empty allowed list, which would permit nothing at all', () {
      expect(
        () => load(
          '${head}answers:\n  - name: role\n    kind: text\n'
          '    allowed: []\n    describes: what this machine is\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('non-empty list'),
          ),
        ),
      );
    });

    test('refuses a default outside the set the same file declares', () {
      // A value the file itself calls illegal, standing in wherever a program says nothing.
      expect(
        () => load(
          '${head}answers:\n  - name: role\n    kind: text\n'
          '    allowed: [master, slave]\n    default: gateway\n'
          '    describes: what this machine is\n',
        ),
        throwsA(
          isA<ProgramInvalid>().having(
            (ProgramInvalid p) => p.message,
            'message',
            contains('holds one of master, slave'),
          ),
        ),
      );
    });

    test('names every bad declaration at once', () {
      // One refusal per run is an operator running it three times to learn three things.
      expect(
        () => load(
          '${head}answers:\n'
          '  - name: a\n    kind: nope\n    describes: one\n'
          '  - name: b\n    kind: text\n'
          '  - kind: text\n    describes: three\n',
        ),
        throwsA(
          isA<ProgramInvalid>()
              .having((ProgramInvalid p) => p.message, 'message', contains('"a" needs a "kind"'))
              .having((ProgramInvalid p) => p.message, 'message', contains('"b" needs "describes"'))
              .having(
                (ProgramInvalid p) => p.message,
                'message',
                contains('an answer needs a "name"'),
              ),
        ),
      );
    });
  });

  group('answering them', () {
    const DeclaredAnswers declared = DeclaredAnswers(<ArgumentSpec>[
      ArgumentSpec(name: 'fqdn', kind: ArgumentKind.text, describes: 'the domain'),
      ArgumentSpec(
        name: 'workers',
        kind: ArgumentKind.integer,
        describes: 'how many',
        required: false,
        defaultValue: 3,
      ),
      ArgumentSpec(
        name: 'repo_pat',
        kind: ArgumentKind.text,
        describes: 'a credential',
        secret: true,
      ),
    ]);

    // An answer whose legal values are a closed set, kept apart from [declared] so the tests around
    // it keep measuring exactly what they measured before.
    const DeclaredAnswers closed = DeclaredAnswers(<ArgumentSpec>[
      ArgumentSpec(
        name: 'role',
        kind: ArgumentKind.text,
        describes: 'what this machine is',
        allowed: <String>['master', 'slave'],
      ),
    ]);

    test('takes a value the declaration names', () {
      expect(
        closed.validate(<String, Object?>{'role': 'slave'}, program: 'deploy-thing').text('role'),
        'slave',
      );
    });

    test('refuses a value outside the set, and says what the set is', () {
      // Naming the set is the difference between an operator fixing it and an operator guessing:
      // the values live in the program file and nowhere the message would otherwise reach.
      expect(
        () => closed.validate(<String, Object?>{'role': 'gateway'}, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>()
              .having(
                (AnswersRejected r) => r.message,
                'message',
                contains('holds one of master, slave'),
              )
              .having((AnswersRejected r) => r.message, 'message', contains('"gateway"')),
        ),
      );
    });

    test('a wrong kind and a wrong value are two different sentences', () {
      // Both are "that will not do", and an operator who is told the wrong one looks in the wrong
      // place: one is a value of the right sort that this answer does not offer, the other is not
      // even that sort of value.
      String refusalFor(Object value) {
        try {
          closed.validate(<String, Object?>{'role': value}, program: 'deploy-thing');
        } on AnswersRejected catch (rejected) {
          return rejected.message;
        }
        return 'nothing was refused';
      }

      expect(refusalFor(7), contains('holds text'));
      expect(refusalFor(7), isNot(contains('holds one of')));
      expect(refusalFor('gateway'), contains('holds one of'));
    });

    test('takes what was supplied and fills in what was not', () {
      final Arguments answered = declared.validate(<String, Object?>{
        'fqdn': 'm1.example.com',
        'repo_pat': 'a-credential',
      }, program: 'deploy-thing');

      expect(answered.text('fqdn'), 'm1.example.com');
      expect(answered.integer('workers'), 3);
    });

    test('refuses a missing required answer, naming what it is for', () {
      expect(
        () =>
            declared.validate(<String, Object?>{'fqdn': 'm1.example.com'}, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>()
              .having((AnswersRejected r) => r.message, 'message', contains('"repo_pat"'))
              .having((AnswersRejected r) => r.message, 'message', contains('a credential')),
        ),
      );
    });

    test('refuses a value of the wrong kind', () {
      expect(
        () => declared.validate(<String, Object?>{
          'fqdn': 'm1.example.com',
          'repo_pat': 'a-credential',
          'workers': 'three',
        }, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected r) => r.message,
            'message',
            contains('holds integer'),
          ),
        ),
      );
    });

    test('refuses an answer nobody declared rather than ignoring it', () {
      // Ignoring it turns a typo into a value that silently went missing, which is exactly the
      // failure a declaration exists to prevent.
      expect(
        () => declared.validate(<String, Object?>{
          'fqdn': 'm1.example.com',
          'repo_pat': 'a-credential',
          'fqnd': 'm1.example.com',
        }, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected r) => r.message,
            'message',
            contains('has no answer "fqnd"'),
          ),
        ),
      );
    });

    test('names every problem at once', () {
      expect(
        () => declared.validate(<String, Object?>{
          'workers': 'three',
          'nonsense': 1,
        }, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>()
              .having((AnswersRejected r) => r.message, 'message', contains('"fqdn"'))
              .having((AnswersRejected r) => r.message, 'message', contains('"repo_pat"'))
              .having((AnswersRejected r) => r.message, 'message', contains('holds integer'))
              .having((AnswersRejected r) => r.message, 'message', contains('"nonsense"')),
        ),
      );
    });

    const DeclaredAnswers shaped = DeclaredAnswers(<ArgumentSpec>[
      ArgumentSpec(
        name: 'color',
        kind: ArgumentKind.text,
        describes: 'the color',
        denied: <String>['black', 'white'],
      ),
      ArgumentSpec(
        name: 'email',
        kind: ArgumentKind.text,
        describes: 'the email',
        shape: 'mailbox',
      ),
      ArgumentSpec(name: 'use_db', kind: ArgumentKind.flag, describes: 'whether to use a db'),
      ArgumentSpec(
        name: 'db_host',
        kind: ArgumentKind.text,
        describes: 'the database host',
        statedWhen: StatedWhen(predicate: 'a_database_is_wanted'),
      ),
    ]);

    test('refuses a value on the denied list', () {
      expect(
        () => shaped.validate(<String, Object?>{
          'color': 'black',
          'email': 'a@b.com',
          'use_db': false,
        }, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected r) => r.message,
            'message',
            contains('must not be one of black, white'),
          ),
        ),
      );
    });

    test('refuses a value with wrong shape', () {
      expect(
        () => shaped.validate(<String, Object?>{
          'color': 'red',
          'email': 'not_an_email',
          'use_db': false,
        }, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected r) => r.message,
            'message',
            contains('is of the wrong shape (must be mailbox)'),
          ),
        ),
      );
    });

    test('validates stated_when trigger', () {
      // WHICH CONDITIONS HOLD IS THE CALLER'S TO MEASURE. They are about one installation, and only
      // whoever has the machine can ask them — so validation is TOLD, and a probe says so directly
      // instead of arranging an answer for a comparison to read.
      const Set<String> wanted = <String>{'a_database_is_wanted'};

      // Condition met, but not provided
      expect(
        () => shaped.validate(
          <String, Object?>{'color': 'red', 'email': 'a@b.com', 'use_db': true},
          program: 'deploy-thing',
          conditionsThatHold: wanted,
        ),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected r) => r.message,
            'message',
            contains('needs the answer "db_host"'),
          ),
        ),
      );

      // Condition not met, but provided
      expect(
        () => shaped.validate(<String, Object?>{
          'color': 'red',
          'email': 'a@b.com',
          'use_db': false,
          'db_host': 'localhost',
        }, program: 'deploy-thing'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected r) => r.message,
            'message',
            contains('is given but its trigger does not hold'),
          ),
        ),
      );

      // Correctly provided
      expect(
        shaped
            .validate(
              <String, Object?>{
                'color': 'red',
                'email': 'a@b.com',
                'use_db': true,
                'db_host': 'localhost',
              },
              program: 'deploy-thing',
              conditionsThatHold: wanted,
            )
            .text('db_host'),
        'localhost',
      );
    });
  });
}
