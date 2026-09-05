import 'arguments.dart';
import 'value_shape.dart';

/// Checks values against the specifications that declare them, and names every problem at once.
///
/// Two callers check the same thing for the same reason, and this is here so they cannot drift: a
/// program file hands a STEP its arguments, and an operator hands a PROGRAM its answers. Neither is
/// checked when the code is compiled — one crosses a configuration boundary, the other crosses the
/// wire — so both are checked here, before anything is looked at or touched.
///
/// Every problem, never the first: an operator fixing one refusal per run is an operator running it
/// five times to learn five things it could have been told at once.
///
/// [filledElsewhere] names what this check cannot see and the caller has already accounted for. One
/// case has it: a program row saying that an argument's value is measured during the run. Such a
/// name is not a missing value, and reporting it as one would send an operator to write a value on a
/// row that already says where its value comes from.
List<String> argumentProblems({
  required String where,
  required Arguments given,
  required List<ArgumentSpec> declared,
  required String noun,
  Set<String> filledElsewhere = const <String>{},
  Set<String> conditionsThatHold = const <String>{},
}) {
  final List<String> problems = <String>[];
  final Set<String> known = declared.map((ArgumentSpec s) => s.name).toSet();

  // A name nothing implements is a REFUSAL and never a pass. Answering true and leaving it to the
  // loader accepts every value for a shape that slipped past the loader, and the run then reads
  // exactly like one where every value had been checked.
  bool checkShape(String shape, String text) {
    final ValueShape? known = ValueShape.named(shape);
    if (known == null) {
      throw StateError(
        '"$shape" is not a shape anything here can check, and it reached the check anyway — the '
        'shapes are ${ValueShape.allWritten.join(', ')}',
      );
    }
    return known.holds(text);
  }

  for (final ArgumentSpec spec in declared) {
    final Object? value = given.raw(spec.name);

    // WHETHER THIS ANSWER WAS ASKED FOR AT ALL, decided by a registered condition rather than by a
    // comparison written into the program file. [conditionsThatHold] is what the caller measured
    // before validating: the conditions are about this installation, and only the caller has the
    // machine to ask them on.
    final StatedWhen? trigger = spec.statedWhen;
    final bool shouldBeAsked = trigger == null || conditionsThatHold.contains(trigger.predicate);

    if (value != null && !shouldBeAsked) {
      problems.add('$where: "${spec.name}" is given but its trigger does not hold');
    }

    if (value == null) {
      // A default is an answer nobody had to give, so a missing value with one behind it is not a
      // missing value at all.
      // Not missing where something stands in for it: a literal default, the value of another
      // answer, or a rule that works it out. An answer nobody has to supply is not one an operator
      // can have forgotten.
      if (shouldBeAsked &&
          spec.required &&
          !spec.hasFallback &&
          !spec.isDerived &&
          !filledElsewhere.contains(spec.name)) {
        problems.add('$where: needs the $noun "${spec.name}" — ${spec.describes}');
      }
      continue;
    }
    if (!spec.accepts(value)) {
      problems.add(
        '$where: "${spec.name}" holds ${spec.kind.name}, and was given ${value.runtimeType}',
      );
      continue;
    }

    if (spec.shape != null) {
      if (spec.kind == ArgumentKind.text) {
        if (!checkShape(spec.shape!, value as String)) {
          problems.add('$where: "${spec.name}" is of the wrong shape (must be ${spec.shape})');
        }
      } else if (spec.kind == ArgumentKind.textList) {
        for (final String item in value as List<String>) {
          if (!checkShape(spec.shape!, item.trim())) {
            problems.add(
              '$where: "${spec.name}" item "$item" is of the wrong shape (must be ${spec.shape})',
            );
          }
        }
      }
    }

    // WHAT THE NUMBER CAN MEAN, asked here because the three declarations beside it hold text and
    // only text, so until now the kind was the whole check for a whole number. A band says what the
    // value can plausibly stand for and never what the platform requires, which is why it belongs to
    // the argument and not to the program row that writes the figure.
    if (spec.band case final IntegerBand band when value is int) {
      if (band.refuses(value) case final String wrong) {
        problems.add('$where: "${spec.name}" $wrong');
      }
    }

    // Asked only once the kind is right: "holds one of master, slave" said about an int would be
    // true and useless.
    if (!spec.permits(value)) {
      if (value is String && spec.denied.contains(value)) {
        problems.add(
          '$where: "${spec.name}" must not be one of ${spec.denied.join(', ')}, and was given "$value"',
        );
      } else {
        problems.add(
          '$where: "${spec.name}" holds one of ${spec.allowed.join(', ')}, and was given "$value"',
        );
      }
    }
  }
  for (final String name in given.names) {
    if (!known.contains(name)) {
      problems.add('$where: has no $noun "$name"');
    }
  }
  return problems;
}
