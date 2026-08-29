import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

/// An answer worked out from another, before the first step and inside the fingerprint.
///
/// Some values an installation needs are not questions anybody should be asked, because they follow
/// from a question already answered. Asking for both invites a pair that does not match, and a
/// selector built on the mismatch finds nothing and says nothing — which is the failure this exists
/// to remove, measured on a real tree before it was built.
void main() {
  ArgumentSpec text(String name) =>
      ArgumentSpec(name: name, kind: ArgumentKind.text, describes: 'the $name');

  ArgumentSpec derived(String name, DerivationRule rule, String from) => ArgumentSpec(
    name: name,
    kind: ArgumentKind.text,
    describes: 'the $name',
    required: false,
    derivation: Derivation(rule: rule, from: from),
  );

  const DeclaredAnswers nothing = DeclaredAnswers(<ArgumentSpec>[]);

  group('the rules themselves', () {
    test('the first DNS label is the piece before the first dot', () {
      expect(DerivationRule.firstDnsLabel.applyTo('m1.example.com'), 'm1');
      expect(DerivationRule.firstDnsLabel.applyTo('s1.a.b.example.com'), 's1');
    });

    test('a name with no dot is its own first label, and is not refused', () {
      // Whether the source is a domain at all is the shape check's question. A rule that also
      // refused would put the same judgement in two places, and they would disagree one day.
      expect(DerivationRule.firstDnsLabel.applyTo('localhost'), 'localhost');
      expect(DerivationRule.withoutFirstDnsLabel.applyTo('localhost'), 'localhost');
    });

    test('taking the first label off leaves the zone the name sits in', () {
      expect(DerivationRule.withoutFirstDnsLabel.applyTo('m1.example.com'), 'example.com');
      expect(DerivationRule.withoutFirstDnsLabel.applyTo('s1.a.b.example.com'), 'a.b.example.com');
    });

    test('a combined role splits into its first and its last part', () {
      // A machine doing several jobs at once carries them as ONE role value, and the selection
      // that admits workloads per part reads one part per slot — this pair is those two slots.
      expect(DerivationRule.firstPart.applyTo('master+slave'), 'master');
      expect(DerivationRule.lastPart.applyTo('master+slave'), 'slave');
    });

    test('a single-part role is its own first and last part, and is not refused', () {
      // Whether the source is a role at all is its declaration's question, exactly as with the
      // DNS rules above — a refusal here would put one judgement in two places.
      expect(DerivationRule.firstPart.applyTo('master'), 'master');
      expect(DerivationRule.lastPart.applyTo('slave'), 'slave');
    });

    test('the part rules are looked up by the names a program file writes', () {
      expect(DerivationRule.named('first_part_of'), DerivationRule.firstPart);
      expect(DerivationRule.named('last_part_of'), DerivationRule.lastPart);
    });

    test('a rule is looked up by the name a program file writes, and an unknown one is null', () {
      // Null rather than a throw, because the LOADER asks this in order to refuse a file naming a
      // rule that does not exist — and that refusal reads better than a stack trace.
      expect(DerivationRule.named('first_dns_label_of'), DerivationRule.firstDnsLabel);
      expect(DerivationRule.named('firstDnsLabel'), isNull);
      expect(DerivationRule.named('reverse'), isNull);
      expect(DerivationRule.allWritten.length, DerivationRule.values.length);
    });
  });

  group('what an operator supplies', () {
    test('a derived answer is worked out and stands beside the rest', () {
      const DeclaredAnswers declared = DeclaredAnswers(<ArgumentSpec>[]);
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        derived('cluster_name', DerivationRule.firstDnsLabel, 'fqdn'),
      ]);
      expect(declared.specs, isEmpty);

      final Arguments answers = program.validate(<String, Object?>{
        'fqdn': 'm1.example.com',
      }, program: 'p');

      expect(answers.text('fqdn'), 'm1.example.com');
      expect(answers.text('cluster_name'), 'm1');
    });

    test('it is NOT missing when nobody supplied it, which is the whole point', () {
      // Without holding it out of the required check, a program declaring one would refuse every
      // answer file that did not carry the value it exists to work out.
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        derived('cluster_name', DerivationRule.firstDnsLabel, 'fqdn'),
      ]);

      expect(
        () => program.validate(<String, Object?>{'fqdn': 'm1.example.com'}, program: 'p'),
        returnsNormally,
      );
    });

    test('supplying it as well is refused, naming it', () {
      // Two versions of one fact, and the pair not matching is exactly what deriving it prevents.
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        derived('cluster_name', DerivationRule.firstDnsLabel, 'fqdn'),
      ]);

      expect(
        () => program.validate(<String, Object?>{
          'fqdn': 'm1.example.com',
          'cluster_name': 'something-else',
        }, program: 'p'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected refused) => refused.message,
            'message',
            contains('cluster_name'),
          ),
        ),
      );
    });

    test('THE INNOCENT NEIGHBOUR: an ordinary answer is still required', () {
      // Without this, holding derived answers out of the check could quietly hold every answer out
      // of it, and a program would accept an answer file carrying nothing at all.
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        derived('cluster_name', DerivationRule.firstDnsLabel, 'fqdn'),
      ]);

      expect(
        () => program.validate(const <String, Object?>{}, program: 'p'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected refused) => refused.message,
            'message',
            contains('fqdn'),
          ),
        ),
      );
    });
  });

  group('what the declaration itself may not say', () {
    test('a source the program does not declare is refused, naming both', () {
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        derived('cluster_name', DerivationRule.firstDnsLabel, 'nowhere'),
      ]);

      expect(
        () => program.validate(const <String, Object?>{}, program: 'p'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected refused) => refused.message,
            'message',
            allOf(contains('cluster_name'), contains('nowhere')),
          ),
        ),
      );
    });

    test('a chain is refused, so no order of evaluation has to be understood', () {
      // One pass and not a chain. A chain is where an order of evaluation starts to matter, and an
      // order of evaluation is the beginning of the language a program file may not become.
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        derived('zone', DerivationRule.withoutFirstDnsLabel, 'fqdn'),
        derived('zone_label', DerivationRule.firstDnsLabel, 'zone'),
      ]);

      expect(
        () => program.validate(<String, Object?>{'fqdn': 'm1.example.com'}, program: 'p'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected refused) => refused.message,
            'message',
            allOf(contains('zone_label'), contains('itself worked out')),
          ),
        ),
      );
    });

    test('a source holding no text is refused rather than worked out from nothing', () {
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        const ArgumentSpec(name: 'count', kind: ArgumentKind.integer, describes: 'a count'),
        derived('label', DerivationRule.firstDnsLabel, 'count'),
      ]);

      expect(
        () => program.validate(<String, Object?>{'count': 3}, program: 'p'),
        throwsA(isA<AnswersRejected>()),
      );
    });

    test('a program with no answers at all is still fine', () {
      expect(nothing.validate(const <String, Object?>{}, program: 'p').names, isEmpty);
    });
  });

  group('an answer that falls back to another', () {
    ArgumentSpec fallsBack(String name, String from) => ArgumentSpec(
      name: name,
      kind: ArgumentKind.text,
      describes: 'the $name',
      required: false,
      defaultFrom: from,
    );

    test('takes the other value where nobody supplied it', () {
      // The case this exists for: a cluster naming which one keeps the books, where leaving it out
      // means this one. Without it the operator types the same domain twice and the two can differ.
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        fallsBack('books_cluster', 'fqdn'),
      ]);

      final Arguments answers = program.validate(<String, Object?>{
        'fqdn': 'm1.example.com',
      }, program: 'p');

      expect(answers.text('books_cluster'), 'm1.example.com');
    });

    test('keeps what was supplied, which is the half that makes it a fallback', () {
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        fallsBack('books_cluster', 'fqdn'),
      ]);

      final Arguments answers = program.validate(<String, Object?>{
        'fqdn': 's1.example.com',
        'books_cluster': 'm1.example.com',
      }, program: 'p');

      expect(answers.text('books_cluster'), 'm1.example.com');
    });

    test('a derivation may read one, because the fallback runs first', () {
      // A fallback is what the operator would have typed, so what is worked out from it is worked
      // out from an answer — not from another derivation.
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        fallsBack('books_cluster', 'fqdn'),
        derived('books_short', DerivationRule.firstDnsLabel, 'books_cluster'),
      ]);

      final Arguments answers = program.validate(<String, Object?>{
        'fqdn': 'm1.example.com',
      }, program: 'p');

      expect(answers.text('books_short'), 'm1');
    });

    test('a chain of fallbacks is refused', () {
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        fallsBack('one', 'fqdn'),
        fallsBack('two', 'one'),
      ]);

      expect(
        () => program.validate(<String, Object?>{'fqdn': 'm1.example.com'}, program: 'p'),
        throwsA(isA<AnswersRejected>()),
      );
    });

    test('a source nobody answered either is refused, not filled with nothing', () {
      final DeclaredAnswers program = DeclaredAnswers(<ArgumentSpec>[
        const ArgumentSpec(
          name: 'fqdn',
          kind: ArgumentKind.text,
          describes: 'the domain',
          required: false,
        ),
        fallsBack('books_cluster', 'fqdn'),
      ]);

      expect(
        () => program.validate(const <String, Object?>{}, program: 'p'),
        throwsA(isA<AnswersRejected>()),
      );
    });
  });

  group('a rule that reads a PAIR of answers', () {
    // The relation nobody types. Whether this cluster is also the one that builds is answered twice
    // over — both addresses are supplied — and a third answer stating whether they match would be
    // the same fact in two places, which is a pair that can disagree and fail much later.
    ArgumentSpec pair(String name, DerivationRule rule, String from, String and) => ArgumentSpec(
      name: name,
      kind: ArgumentKind.text,
      describes: 'the $name',
      required: false,
      derivation: Derivation(rule: rule, from: from, and: and),
    );

    DeclaredAnswers program(DerivationRule rule) => DeclaredAnswers(<ArgumentSpec>[
      text('fqdn'),
      text('build_plane'),
      pair('registry_is_local', rule, 'build_plane', 'fqdn'),
    ]);

    test('THE INNOCENT CASE: two equal answers work out to the word true', () {
      final Arguments answers = program(DerivationRule.sameAs).validate(<String, Object?>{
        'fqdn': 'm1.example.com',
        'build_plane': 'm1.example.com',
      }, program: 'p');

      expect(answers.text('registry_is_local'), 'true');
    });

    test('two different answers work out to the word false', () {
      final Arguments answers = program(DerivationRule.sameAs).validate(<String, Object?>{
        'fqdn': 'm1.example.com',
        'build_plane': 'b1.example.com',
      }, program: 'p');

      expect(answers.text('registry_is_local'), 'false');
    });

    test('the other direction is its own rule, not a negation somewhere else', () {
      final Arguments answers = program(DerivationRule.differsFrom).validate(<String, Object?>{
        'fqdn': 'm1.example.com',
        'build_plane': 'b1.example.com',
      }, program: 'p');

      expect(answers.text('registry_is_local'), 'true');
    });

    test('the two rules never answer alike on one pair', () {
      // Without this, a version that answered the same way for both would pass every assertion
      // above that drives only one of them.
      for (final String plane in <String>['m1.example.com', 'b1.example.com']) {
        final Map<String, Object?> given = <String, Object?>{
          'fqdn': 'm1.example.com',
          'build_plane': plane,
        };
        expect(
          program(DerivationRule.sameAs).validate(given, program: 'p').text('registry_is_local'),
          isNot(
            program(
              DerivationRule.differsFrom,
            ).validate(given, program: 'p').text('registry_is_local'),
          ),
          reason: 'on build_plane=$plane',
        );
      }
    });

    test('a pair rule given only one name is REFUSED, not measured against nothing', () {
      // The dangerous shape. Against the empty string the relation answers "false", which reads as
      // a measurement of the machine rather than as a declaration nobody finished.
      final DeclaredAnswers half = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        text('build_plane'),
        const ArgumentSpec(
          name: 'registry_is_local',
          kind: ArgumentKind.text,
          describes: 'the relation',
          required: false,
          derivation: Derivation(rule: DerivationRule.sameAs, from: 'build_plane'),
        ),
      ]);

      expect(
        () => half.validate(<String, Object?>{
          'fqdn': 'm1.example.com',
          'build_plane': 'm1.example.com',
        }, program: 'p'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected refused) => refused.message,
            'message',
            contains('PAIR'),
          ),
        ),
      );
    });

    test('a one-answer rule given a second name is REFUSED', () {
      final DeclaredAnswers extra = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        text('build_plane'),
        pair('label', DerivationRule.firstDnsLabel, 'fqdn', 'build_plane'),
      ]);

      expect(
        () => extra.validate(<String, Object?>{
          'fqdn': 'm1.example.com',
          'build_plane': 'b1.example.com',
        }, program: 'p'),
        throwsA(isA<AnswersRejected>()),
      );
    });

    test('THE SECOND SOURCE IS HELD TO WHAT THE FIRST IS: undeclared is refused', () {
      final DeclaredAnswers nowhere = DeclaredAnswers(<ArgumentSpec>[
        text('build_plane'),
        pair('registry_is_local', DerivationRule.sameAs, 'build_plane', 'nowhere'),
      ]);

      expect(
        () => nowhere.validate(<String, Object?>{'build_plane': 'm1.example.com'}, program: 'p'),
        throwsA(
          isA<AnswersRejected>().having(
            (AnswersRejected refused) => refused.message,
            'message',
            contains('nowhere'),
          ),
        ),
      );
    });

    test('and a chain through the second source is refused too', () {
      final DeclaredAnswers chained = DeclaredAnswers(<ArgumentSpec>[
        text('fqdn'),
        text('build_plane'),
        derived('label', DerivationRule.firstDnsLabel, 'fqdn'),
        pair('registry_is_local', DerivationRule.sameAs, 'build_plane', 'label'),
      ]);

      expect(
        () => chained.validate(<String, Object?>{
          'fqdn': 'm1.example.com',
          'build_plane': 'm1',
        }, program: 'p'),
        throwsA(isA<AnswersRejected>()),
      );
    });
  });
}
