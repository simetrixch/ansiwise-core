import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import 'support/example_steps.dart';
import 'support/harness.dart';

/// From which step a run cannot be taken back, said before it starts.
///
/// The data is all there and no row says what it adds up to: every step answers whether it can be
/// undone, and an operator reading thirty rows each carrying a flag has to find the boundary
/// themselves. The moment they need it is the moment a run has gone wrong, which is the worst
/// moment to be counting.
///
/// TWO WAYS PAST THE LINE, and an operator is told which. A step may be irreversible by its own
/// nature and then it says why; or the program may say `undo: false`, and then somebody decided so
/// for this installation. The second moves the boundary exactly as the first does — which is the
/// whole reason it has to be said before the run rather than at the moment an unwind reaches the
/// step and stops.
void main() {
  ResolvedProgram programWith(
    List<(String, OnFailure, List<String>)> entries, {
    Set<String> undoOff = const <String>{},
  }) => ProgramResolver(
    registryOf(
      steps: <String, (String, Step Function(Arguments))>{
        'writes_one': ('x:1', (Arguments a) => WritesAFile(path: '/one', content: '1')),
        'writes_two': ('x:2', (Arguments a) => WritesAFile(path: '/two', content: '2')),
        'mints': (
          'x:3',
          (Arguments a) => RunsACommand(argv: const <String>['mint'], leaves: '/minted'),
        ),
        'measures': ('x:4', (Arguments a) => const Measures('the machine is as it should be')),
      },
    ),
  ).resolve(programOf('p', entries, undoOff: undoOff));

  group('a program every step of which can be taken back', () {
    final ResolvedProgram reversible = programWith(<(String, OnFailure, List<String>)>[
      ('writes_one', OnFailure.exit, <String>[]),
      ('writes_two', OnFailure.exit, <String>[]),
    ]);

    test('has no point of no return', () {
      expect(pointOfNoReturn(reversible), isNull);
    });

    test('says nothing about one, rather than saying there is none at step zero', () {
      expect(
        pointOfNoReturnSaid(reversible),
        isNull,
        reason:
            'a sentence about a boundary that does not exist is a sentence an operator has to work '
            'out is empty',
      );
    });
  });

  group('a step that cannot be taken back by its own nature', () {
    final ResolvedProgram withAMint = programWith(<(String, OnFailure, List<String>)>[
      ('writes_one', OnFailure.exit, <String>[]),
      ('mints', OnFailure.exit, <String>[]),
      ('writes_two', OnFailure.exit, <String>[]),
    ]);

    test('is the boundary, and it is the FIRST such step', () {
      final NoWayBack? boundary = pointOfNoReturn(withAMint);
      expect(boundary?.step, const StepName('mints'));
      expect(
        boundary?.position,
        1,
        reason:
            'the unwind walks backwards and stops at the earliest thing it cannot reverse, so '
            'everything from there onward stands together',
      );
    });

    test('the reason is the step\'s own words', () {
      expect(pointOfNoReturn(withAMint)?.because, Irreversibility.byNature);
      expect(
        pointOfNoReturn(withAMint)?.reason,
        isNot(contains('does not say')),
        reason:
            'a step that declared itself irreversible gave a reason, and that reason is what an '
            'operator can weigh — "no undo was written" is a statement about our code',
      );
    });

    test('the sentence names the step and where it stands', () {
      final String said = pointOfNoReturnSaid(withAMint)!;
      expect(said, contains('mints'));
      expect(said, contains('step 2 of 3'), reason: 'counted the way a person counts, from one');
    });
  });

  group('a reversible step the program switched off', () {
    final ResolvedProgram withUndoOff = programWith(
      <(String, OnFailure, List<String>)>[
        ('writes_one', OnFailure.exit, <String>[]),
        ('writes_two', OnFailure.exit, <String>[]),
      ],
      undoOff: <String>{'writes_two'},
    );

    test('moves the boundary although the step itself could take it back', () {
      final NoWayBack? boundary = pointOfNoReturn(withUndoOff);
      expect(boundary?.step, const StepName('writes_two'));
      expect(boundary?.because, Irreversibility.byDecision);
    });

    test('and the reason says a decision was made, not that no undo exists', () {
      expect(
        pointOfNoReturn(withUndoOff)?.reason,
        allOf(contains('undo: false'), contains('could take it back')),
        reason:
            'an operator who reads that the step cannot be undone would go looking for a defect; '
            'what happened is that somebody chose this for this installation',
      );
    });

    test('the same program with the switch left alone has no boundary at all', () {
      expect(
        pointOfNoReturn(
          programWith(<(String, OnFailure, List<String>)>[
            ('writes_one', OnFailure.exit, <String>[]),
            ('writes_two', OnFailure.exit, <String>[]),
          ]),
        ),
        isNull,
        reason: 'the switch is what made the difference, and nothing else about the program moved',
      );
    });
  });

  group('a step that changes nothing', () {
    test('is not a boundary, whatever kind it is', () {
      // An observing step measures and refuses. There is nothing to take back and nothing left
      // behind, so it cannot be the point past which a run stands — even though it is not a
      // ReversibleStep and would be caught by a test that only asked that question.
      expect(
        pointOfNoReturn(
          programWith(<(String, OnFailure, List<String>)>[
            ('measures', OnFailure.exit, <String>[]),
            ('writes_one', OnFailure.exit, <String>[]),
          ]),
        ),
        isNull,
      );
    });
  });

  group('everything a run would leave behind', () {
    test('is listed in the order the steps run, not only the first', () {
      final ResolvedProgram several = programWith(
        <(String, OnFailure, List<String>)>[
          ('writes_one', OnFailure.exit, <String>[]),
          ('mints', OnFailure.exit, <String>[]),
          ('writes_two', OnFailure.exit, <String>[]),
        ],
        undoOff: <String>{'writes_two'},
      );

      expect(whatStands(several).map((NoWayBack each) => each.step.value), <String>[
        'mints',
        'writes_two',
      ]);
      expect(whatStands(several).map((NoWayBack each) => each.because), <Irreversibility>[
        Irreversibility.byNature,
        Irreversibility.byDecision,
      ]);
    });
  });
}
