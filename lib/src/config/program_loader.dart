/// Reads a program file into the data the resolver binds to the registry.
///
/// A program file is data and never logic, so this loader is deliberately dumb: it reads keys and
/// values, and it refuses everything it does not recognise. There is no loop, no expression, no
/// templating, no variable substitution, no include, and no anchor or alias that lets one part of a
/// file stand for another. A key nobody declared is refused rather than ignored — a loader that
/// ignores what it does not know turns a typo into a setting that silently went missing.
///
/// The one thing a row may name instead of writing a value is a MEASUREMENT — `{measured: <name>}`,
/// standing for the whole of one value an earlier row takes off the machine while the run happens.
/// It is a named slot and not an expression: it cannot stand inside a longer value, cannot be tested
/// or combined, and the name is either published by a row of this program or the program is refused.
///
/// What it does not do is check a step's arguments against what that step declares. That is the
/// resolver's job, against the registry, and doing it twice would mean two places to keep in step.
library;

import 'package:yaml/yaml.dart';

import '../domain/answers.dart';
import '../domain/arguments.dart';
import '../domain/derivation.dart';
import '../domain/value_shape.dart';
import '../domain/program.dart';
import '../model/failures.dart';
import '../model/names.dart';
import '../model/on_failure.dart';

/// Turns the text of a program file into a [Program].
///
/// [where] is the file it came from, and it is what a refusal is reported against.
///
/// Throws [ProgramInvalid] listing everything wrong with the file at once, one problem per line,
/// each carrying the line number wherever the parser gives one. An operator fixing a file one
/// refusal per run is an operator running it five times to learn five things.
Program loadProgram(String yaml, {required String where}) {
  final YamlNode root;
  try {
    root = loadYamlNode(yaml);
  } on YamlException catch (broken) {
    // Text that does not parse has no structure left to look for further problems in, so this is
    // the one refusal that reports a single thing. A duplicate key arrives here too: the parser
    // refuses it while composing the document, before there is anything to inspect.
    final int? line = broken.span?.start.line;
    throw ProgramInvalid(
      line == null ? broken.message : 'line ${line + 1}: ${broken.message}',
      where: where,
    );
  }

  final _Refusals refusals = _Refusals();
  _refuseAnchors(root, refusals);

  if (root is! YamlMap) {
    refusals.add(root.span.start.line, 'a program is a map, and its keys are $_programKeyList');
    refusals.refuse(where);
  }

  _refuseUnknownKeys(root, refusals);
  final ProgramName? name = _name(root, refusals);
  final List<Role> roles = _roles(root, refusals);
  final List<ProgramStep> steps = _steps(root, refusals);
  final DeclaredAnswers answers = _answers(root, refusals);
  final Arguments defaults = _defaults(root, refusals);

  // [_name] returns null only where it has already recorded a refusal, so the second half of this
  // condition never produces an empty message — and past it the name is a value rather than a
  // maybe, which is what lets the program be built without a null check.
  if (refusals.any || name == null) {
    refusals.refuse(where);
  }
  return Program(name: name, roles: roles, steps: steps, answers: answers, defaults: defaults);
}

/// The values this program gives to every step that takes them, as the file writes them.
///
/// A flat map of names to values, read exactly like a row's arguments so a value has the same shape
/// in both places. Whether a step declares the name at all is asked against the registry afterwards,
/// which is where a name that fills nothing is refused.
Arguments _defaults(YamlMap root, _Refusals refusals) {
  final YamlNode? node = root.nodes['defaults'];
  if (node == null) {
    return Arguments.none;
  }
  if (node is! YamlMap) {
    refusals.add(node.span.start.line, '"defaults" is a map of argument names to values');
    return Arguments.none;
  }
  final Map<String, Object> values = <String, Object>{};
  for (final MapEntry<Object?, YamlNode> pair in node.nodes.entries) {
    if (pair.key case YamlScalar(value: final String key)) {
      final Object? value = _argument(pair.value, key, 'defaults', refusals);
      if (value != null) {
        values[key] = value;
      }
      continue;
    }
    refusals.add(
      _lineOf(pair.key) ?? pair.value.span.start.line,
      'defaults: an argument name is text, and the file gives something else',
    );
  }
  return Arguments(values);
}

/// What an operator has to supply, as the file declares it.
///
/// Absent means a program that needs nothing, which is a normal thing to be — every problem found
/// here is recorded and the reading continues, so a file with three bad declarations is told about
/// all three.
DeclaredAnswers _answers(YamlMap document, _Refusals refusals) {
  final YamlNode? node = document.nodes['answers'];
  if (node == null) {
    return DeclaredAnswers.none;
  }
  if (node is! YamlList) {
    refusals.add(node.span.start.line, '"answers" is a list of declarations');
    return DeclaredAnswers.none;
  }

  final List<ArgumentSpec> specs = <ArgumentSpec>[];
  final Set<String> seen = <String>{};
  for (final YamlNode entry in node.nodes) {
    final int line = entry.span.start.line;
    if (entry is! YamlMap) {
      refusals.add(line, 'an answer is a map with "name", "kind" and "describes"');
      continue;
    }
    for (final MapEntry<Object?, YamlNode> pair in entry.nodes.entries) {
      if (pair.key case YamlScalar(value: final String key)) {
        if (!_answerKeys.contains(key)) {
          refusals.add(_lineOf(pair.key) ?? line, 'an answer has no key "$key"');
        }
      }
    }

    final Object? name = entry['name'];
    if (name is! String || name.isEmpty) {
      refusals.add(line, 'an answer needs a "name"');
      continue;
    }
    if (!seen.add(name)) {
      // Two declarations under one name would make which one the form asks depend on order, and
      // the second silently wins wherever a map is built from them.
      refusals.add(line, 'the answer "$name" is declared twice');
      continue;
    }

    final Object? kind = entry['kind'];
    final ArgumentKind? resolved = kind is String ? _answerKinds[kind] : null;
    if (resolved == null) {
      refusals.add(line, '"$name" needs a "kind": ${_answerKinds.keys.join(', ')}');
      continue;
    }

    final Object? describes = entry['describes'];
    if (describes is! String || describes.isEmpty) {
      // Without it the form shows a bare field name to somebody who has never seen this system,
      // which is the whole failure this declaration exists to prevent.
      refusals.add(line, '"$name" needs "describes" — it is what the form shows the operator');
      continue;
    }

    final Object? isRequired = entry['required'];
    if (isRequired != null && isRequired is! bool) {
      refusals.add(line, '"$name": "required" is true or false');
      continue;
    }
    final Object? isSecret = entry['secret'];
    if (isSecret != null && isSecret is! bool) {
      refusals.add(line, '"$name": "secret" is true or false');
      continue;
    }
    if (isSecret == true && resolved != ArgumentKind.text) {
      // What reads a secret answer reads it as TEXT — that is how a value gets into the redactor,
      // which is the one thing standing between a credential and a world-readable record. Declared
      // on another kind it passes every check here and then throws where the redactor is built,
      // after validation, with a message naming a type rather than this declaration.
      refusals.add(
        line,
        '"$name" is secret, so it holds text — a secret of another kind cannot be redacted',
      );
      continue;
    }

    final Object? fallback = entry['default'];
    if (fallback != null && isSecret == true) {
      // A default for a secret is a credential written into a file that ships to every
      // installation, which is the one thing this framework must never make easy.
      refusals.add(line, '"$name" is secret, so it cannot have a default');
      continue;
    }
    // The values this answer may hold, where it is one of a small closed set. Only text has one:
    // a flag already has two values, and a number or a list of text has no small closed set worth
    // writing out — so declaring one on those is refused rather than quietly ignored.
    final Object? permitted = entry['allowed'];
    final List<String> allowed = <String>[];
    if (permitted != null) {
      if (resolved != ArgumentKind.text) {
        refusals.add(line, '"$name" holds ${resolved.name}, and only text may name allowed values');
        continue;
      }
      if (permitted is! YamlList || permitted.isEmpty) {
        refusals.add(line, '"$name": "allowed" is a non-empty list of the values it may hold');
        continue;
      }
      for (final Object? each in permitted) {
        if (each is! String || each.isEmpty) {
          refusals.add(line, '"$name": "$each" is not a value it could hold');
          continue;
        }
        allowed.add(each);
      }
    }

    final Object? deniedNode = entry['denied'];
    final List<String> denied = <String>[];
    if (deniedNode != null) {
      if (resolved != ArgumentKind.text) {
        refusals.add(line, '"$name" holds ${resolved.name}, and only text may name denied values');
        continue;
      }
      if (deniedNode is! YamlList || deniedNode.isEmpty) {
        refusals.add(line, '"$name": "denied" is a non-empty list of values it must not hold');
        continue;
      }
      for (final Object? each in deniedNode) {
        if (each is! String || each.isEmpty) {
          refusals.add(line, '"$name": "$each" is not a value to deny');
          continue;
        }
        denied.add(each);
      }
    }

    final Object? shapeNode = entry['shape'];
    String? shape;
    if (shapeNode != null) {
      if (resolved != ArgumentKind.text && resolved != ArgumentKind.textList) {
        refusals.add(
          line,
          '"$name" holds ${resolved.name}, and only text or text_list may have a shape',
        );
        continue;
      }
      // The set of shapes is ValueShape's and not this file's. Written out here as well, the two
      // would drift the first time a shape is added, and the way that shows is the worst kind: the
      // loader accepts the declaration and the check quietly passes every value.
      if (shapeNode is! String || ValueShape.named(shapeNode) == null) {
        refusals.add(
          line,
          '"$name": "shape" is "$shapeNode", and it is one of ${ValueShape.allWritten.join(', ')}',
        );
        continue;
      }
      shape = shapeNode;
    }

    final Object? statedWhenNode = entry['stated_when'];
    StatedWhen? statedWhen;
    if (statedWhenNode != null) {
      if (isRequired == true) {
        refusals.add(line, '"$name" has "stated_when", so it cannot be "required: true"');
        continue;
      }
      // ONE REGISTERED NAME AND NOTHING ELSE. It used to be a comparison written here — an answer,
      // and either a literal or a second answer to match it against — which is a condition living in
      // a program file beside the registered ones. A file that can compare two values can compare
      // anything, and then what an operator debugs is the file rather than the code.
      if (statedWhenNode is! YamlMap ||
          statedWhenNode.length != 1 ||
          statedWhenNode['predicate'] is! String) {
        refusals.add(
          line,
          '"$name": "stated_when" names one registered condition, as {predicate: <name>} — the '
          'condition itself is bound in the installation\'s configuration, where a name is given to '
          'what it looks at',
        );
        continue;
      }
      statedWhen = StatedWhen(predicate: statedWhenNode['predicate']! as String);
    }

    // `default_from:` names the answer this one falls back to where nobody supplied it. The
    // difference from `derived:` is the trigger and nothing else, so the same refusals apply.
    final Object? fallbackNode = entry['default_from'];
    String? defaultFrom;
    if (fallbackNode != null) {
      if (resolved != ArgumentKind.text) {
        refusals.add(line, '"$name" holds ${resolved.name}, and only text falls back to text');
        continue;
      }
      if (isSecret == true) {
        refusals.add(line, '"$name" falls back to another answer, so it is not a secret');
        continue;
      }
      if (fallback != null) {
        refusals.add(
          line,
          '"$name" has both a "default" and a "default_from", and two values standing in for one '
          'absence is one of them never used',
        );
        continue;
      }
      if (fallbackNode is! String || fallbackNode.isEmpty) {
        refusals.add(
          line,
          '"$name": "default_from" is the name of the answer this one falls back to',
        );
        continue;
      }
      defaultFrom = fallbackNode;
    }

    // `derived:` names a rule out of the closed set, and `from:` names the answer it is worked out
    // from. Both or neither: half of it is a declaration nobody can act on.
    final Object? derivedNode = entry['derived'];
    final Object? fromNode = entry['from'];
    final Object? andNode = entry['and'];
    Derivation? derivation;
    if (derivedNode != null || fromNode != null) {
      if (derivedNode == null || fromNode == null) {
        refusals.add(
          line,
          '"$name": "derived" names the rule and "from" names the answer it is worked out from, '
          'and one without the other says nothing',
        );
        continue;
      }
      if (resolved != ArgumentKind.text) {
        refusals.add(line, '"$name" holds ${resolved.name}, and only text is worked out from text');
        continue;
      }
      // THE RULE IS READ FIRST, because what may stand beside it depends on which rule it is. One
      // that reads a file off the machine yields a secret, and a refusal written without knowing
      // that would tell the reader the opposite of the truth about their own declaration.
      if (derivedNode is! String || DerivationRule.named(derivedNode) == null) {
        refusals.add(
          line,
          '"$name": "derived" is "$derivedNode", and it is one of '
          '${DerivationRule.allWritten.join(', ')}',
        );
        continue;
      }
      final DerivationRule rule = DerivationRule.named(derivedNode)!;
      if (isSecret == true) {
        refusals.add(
          line,
          rule.readsAFile
              // The rule already says it, and the declaration saying it again is a second place the
              // same fact could come to disagree with the first.
              ? '"$name" is the secret in a file on this machine, which "$derivedNode" says already '
                    '— "secret" here is that same fact written twice'
              // A value that follows from another is not a secret of its own, and calling it one
              // would put the answer it came from one rule away from a redacted record while it
              // stayed plain.
              : '"$name" is worked out from another answer, so it is not a secret',
        );
        continue;
      }
      if (fallback != null) {
        // A default stands in wherever nobody supplied a value, and nobody ever supplies a derived
        // answer — so the default would win over the rule on every run and the rule would never be
        // read. Where the value is a credential that is the whole defect in one line: a literal in
        // a file that ships to every installation, standing in for what the machine holds.
        refusals.add(
          line,
          '"$name" is worked out from another answer, so a "default" would stand in its place on '
          'every run and the rule would never be read',
        );
        continue;
      }
      if (isRequired == true) {
        refusals.add(
          line,
          '"$name" is worked out from another answer, so nobody supplies it and it cannot be '
          '"required: true"',
        );
        continue;
      }
      if (fromNode is! String || fromNode.isEmpty) {
        refusals.add(line, '"$name": "from" is the name of the answer this one is worked out from');
        continue;
      }
      if (rule.sources == 2 && (andNode is! String || andNode.isEmpty)) {
        refusals.add(
          line,
          '"$name": "$derivedNode" reads a PAIR of answers, so "and" is the name of the second one',
        );
        continue;
      }
      if (rule.sources == 1 && andNode != null) {
        refusals.add(
          line,
          '"$name": "$derivedNode" reads one answer, and "and" names a second that nothing would '
          'read — a name sitting there looking as though it did',
        );
        continue;
      }
      derivation = Derivation(
        rule: rule,
        from: fromNode,
        and: rule.sources == 2 ? andNode! as String : null,
      );
    }

    final Object? unwrapped = fallback is YamlList
        ? <String>[for (final Object? v in fallback) '$v']
        : fallback;
    if (unwrapped != null) {
      final ArgumentSpec probe = ArgumentSpec(
        name: name,
        kind: resolved,
        describes: describes,
        allowed: allowed,
      );
      if (!probe.accepts(unwrapped)) {
        refusals.add(
          line,
          '"$name" holds ${resolved.name}, and its default is ${unwrapped.runtimeType}',
        );
        continue;
      }
      // A default outside the set the same declaration names is a value the file itself calls
      // illegal, standing in wherever a program says nothing about the answer.
      if (!probe.permits(unwrapped)) {
        refusals.add(
          line,
          '"$name" holds one of ${allowed.join(', ')}, and its default is "$unwrapped"',
        );
        continue;
      }
    }

    specs.add(
      ArgumentSpec(
        name: name,
        kind: resolved,
        describes: describes,
        required: isRequired as bool? ?? true,
        secret: isSecret as bool? ?? false,
        defaultValue: unwrapped,
        allowed: allowed,
        shape: shape,
        denied: denied,
        statedWhen: statedWhen,
        derivation: derivation,
        defaultFrom: defaultFrom,
      ),
    );
  }

  // WHETHER THE CONDITION EXISTS is not asked here, and that is deliberate: a condition is bound in
  // the INSTALLATION's configuration, which this loader has never read. The resolver asks it, once
  // the registry and the bound names are both in hand, and refuses there naming the program and the
  // answer — the same place it refuses a step or a predicate a row names and nothing registers.

  for (final ArgumentSpec spec in specs) {
    final String? fallsBackTo = spec.defaultFrom;
    if (fallsBackTo != null && !seen.contains(fallsBackTo)) {
      refusals.add(
        document.span.start.line,
        'the answer "$fallsBackTo" that "${spec.name}" falls back to does not exist',
      );
    }
    final Derivation? how = spec.derivation;
    if (how != null && !seen.contains(how.from)) {
      refusals.add(
        document.span.start.line,
        'the answer "${how.from}" that "${spec.name}" is worked out from does not exist',
      );
    }
  }

  return DeclaredAnswers(specs);
}

/// The keys a program file may write at the top level.
const Set<String> _programKeys = <String>{'name', 'roles', 'steps', 'answers', 'defaults'};

/// The keys above, as a refusal writes them.
///
/// Derived rather than written out a second time: the two lists were kept in step by hand until a
/// key was added and the refusals went on naming three, so an operator mistyping the new key was
/// told it does not exist.
final String _programKeyList = _programKeys.map((String key) => '"$key"').join(', ');

/// The keys one answer declaration may write.
const Set<String> _answerKeys = <String>{
  'name',
  'kind',
  'describes',
  'required',
  'secret',
  'default',
  'allowed',
  'shape',
  'denied',
  'stated_when',
  'derived',
  'from',
  'and',
  'default_from',
};

/// The kinds an answer may declare, as a program file writes them.
const Map<String, ArgumentKind> _answerKinds = <String, ArgumentKind>{
  'text': ArgumentKind.text,
  'integer': ArgumentKind.integer,
  'flag': ArgumentKind.flag,
  'text_list': ArgumentKind.textList,
};

/// The keys of a step entry the loader reads. Every other key of an entry is an argument.
const Set<String> _stepKeys = <String>{
  'step',
  'on_failure',
  'when',
  'undo',
  'rests_on_an_earlier_step',
  'keep_output',
  'publish',
};

/// One thing wrong with a file, and where in it.
final class _Problem {
  const _Problem(this.line, this.found, this.what);

  /// The source line, as the parser counts it, from zero.
  final int line;

  /// How many problems were already found when this one was, which orders two on the same line.
  final int found;

  /// What is wrong there.
  final String what;
}

/// Everything wrong with one file, collected so all of it can be said in one refusal.
final class _Refusals {
  final List<_Problem> _problems = <_Problem>[];

  /// Whether anything has been refused.
  bool get any => _problems.isNotEmpty;

  /// Records [what], at the source line the parser counts from zero.
  void add(int line, String what) => _problems.add(_Problem(line, _problems.length, what));

  /// Throws everything collected so far as one refusal against [where].
  ///
  /// Sorted by line, so the refusal reads down the file the operator has open. That is not the
  /// order the problems were found in: anchors are looked for in one walk of the whole tree before
  /// a single key is read, and an entry is read after the keys above it whatever line it is on.
  /// [_Problem.found] breaks the tie between two problems on one line, because [List.sort] gives no
  /// promise about equal elements.
  Never refuse(String where) {
    final List<_Problem> ordered = _problems.toList()
      ..sort((_Problem a, _Problem b) {
        final int byLine = a.line.compareTo(b.line);
        return byLine != 0 ? byLine : a.found.compareTo(b.found);
      });
    throw ProgramInvalid(
      ordered.map((_Problem p) => 'line ${p.line + 1}: ${p.what}').join('\n'),
      where: where,
    );
  }
}

/// Refuses every anchor and every alias in the tree under [root].
///
/// The `yaml` package resolves aliases while parsing and reports nothing about them afterwards, so
/// there is no flag to read. Two things it does leave are enough. The parser expands a node's span
/// backwards over its `&anchor`, so an anchored node is the one whose source text starts with `&` —
/// which no plain scalar may. And an alias is loaded as the very node the anchor registered, so the
/// same object stands at both places and one report covers the pair.
///
/// The identity set is also what stops this walking forever: `&a [*a]` builds a list that contains
/// itself, because the anchor is registered before the children are read.
void _refuseAnchors(YamlNode root, _Refusals refusals) {
  final Set<YamlNode> seen = Set<YamlNode>.identity();
  final List<YamlNode> pending = <YamlNode>[root];

  while (pending.isNotEmpty) {
    final YamlNode node = pending.removeLast();
    if (!seen.add(node)) {
      continue;
    }
    if (node.span.text.startsWith('&')) {
      refusals.add(
        node.span.start.line,
        'an anchor or alias — a program file is data, and an alias lets one part of it stand for '
        'another',
      );
    }
    if (node is YamlList) {
      pending.addAll(node.nodes);
    } else if (node is YamlMap) {
      for (final MapEntry<Object?, YamlNode> pair in node.nodes.entries) {
        if (pair.key case final YamlNode key) {
          pending.add(key);
        }
        pending.add(pair.value);
      }
    }
  }
}

/// Refuses every top-level key that is not one of [_programKeys].
void _refuseUnknownKeys(YamlMap document, _Refusals refusals) {
  for (final MapEntry<Object?, YamlNode> pair in document.nodes.entries) {
    final int line = _lineOf(pair.key) ?? pair.value.span.start.line;
    if (pair.key case YamlScalar(value: final String key)) {
      if (!_programKeys.contains(key)) {
        refusals.add(line, 'a program does not have a key "$key" — it has $_programKeyList');
      }
      continue;
    }
    refusals.add(line, 'a key is text, and the file gives something else');
  }
}

/// The declared program name, or null when there is none to read.
///
/// Null means a refusal has already been recorded, which is what [loadProgram] leans on to build
/// the program without a null check.
ProgramName? _name(YamlMap document, _Refusals refusals) {
  final YamlNode? node = document.nodes['name'];
  if (node == null) {
    refusals.add(document.span.start.line, 'the file has no "name"');
    return null;
  }
  if (node.value case final String written) {
    if (ProgramName.isValid(written)) {
      return ProgramName(written);
    }
    refusals.add(
      node.span.start.line,
      '"$written" is not a program name — lower case letters, digits and dashes, starting with a '
      'letter',
    );
    return null;
  }
  refusals.add(node.span.start.line, '"name" is text, and the file gives ${_kindOf(node)}');
  return null;
}

/// The machine roles the program applies to.
List<Role> _roles(YamlMap document, _Refusals refusals) {
  final YamlNode? node = document.nodes['roles'];
  if (node == null) {
    refusals.add(document.span.start.line, 'the file has no "roles"');
    return const <Role>[];
  }
  if (node is! YamlList) {
    refusals.add(
      node.span.start.line,
      '"roles" is a list of role names, and the file gives ${_kindOf(node)}',
    );
    return const <Role>[];
  }
  if (node.nodes.isEmpty) {
    // Roles are what the first gate matches a machine against, so an empty list is a program no
    // machine can ever be given.
    refusals.add(node.span.start.line, '"roles" is empty, and no machine would match it');
    return const <Role>[];
  }

  final List<Role> roles = <Role>[];
  for (final YamlNode element in node.nodes) {
    if (element.value case final String written) {
      roles.add(Role(written));
      continue;
    }
    refusals.add(
      element.span.start.line,
      '"roles" holds role names, and the file gives ${_kindOf(element)}',
    );
  }
  return roles;
}

/// The entries of the program, in the order they are written.
List<ProgramStep> _steps(YamlMap document, _Refusals refusals) {
  final YamlNode? node = document.nodes['steps'];
  if (node == null) {
    refusals.add(document.span.start.line, 'the file has no "steps"');
    return const <ProgramStep>[];
  }
  if (node is! YamlList) {
    refusals.add(
      node.span.start.line,
      '"steps" is a list of entries, and the file gives ${_kindOf(node)}',
    );
    return const <ProgramStep>[];
  }
  if (node.nodes.isEmpty) {
    refusals.add(
      node.span.start.line,
      '"steps" is empty, and a program with no steps does nothing',
    );
    return const <ProgramStep>[];
  }

  final List<ProgramStep> steps = <ProgramStep>[];
  for (int i = 0; i < node.nodes.length; i++) {
    final ProgramStep? entry = _step(node.nodes[i], i, refusals);
    if (entry != null) {
      steps.add(entry);
    }
  }
  return steps;
}

/// One entry of the program, or null when it could not be read.
///
/// Every part of the entry is read even after one of them has been refused, so a single run reports
/// the bad step name and the missing failure policy together rather than one per run.
ProgramStep? _step(YamlNode node, int index, _Refusals refusals) {
  if (node is! YamlMap) {
    refusals.add(
      node.span.start.line,
      'steps[$index] is not a map — an entry names a step and gives it values',
    );
    return null;
  }

  final StepName? step = _stepName(node, index, refusals);
  final String label = step == null ? 'steps[$index]' : 'steps[$index] $step';
  final OnFailure? onFailure = _onFailure(node, label, refusals);
  final List<PredicateName> when = _when(node, label, refusals);
  final bool undo = _undo(node, label, refusals);
  final bool restsOn = _flag(node, 'rests_on_an_earlier_step', label, refusals);
  final bool keepsOutput = _flag(node, 'keep_output', label, refusals);
  final Map<MeasurementName, MeasurementName> publish = _publish(node, label, refusals);
  final _Given given = _given(node, label, refusals);

  if (step == null || onFailure == null) {
    return null;
  }
  return ProgramStep(
    step: step,
    onFailure: onFailure,
    arguments: given.arguments,
    reads: given.reads,
    publish: publish,
    when: when,
    undo: undo,
    restsOnAnEarlierStep: restsOn,
    keepsOutput: keepsOutput,
  );
}

/// The name this row publishes each of its step's measurements under, by the name the step declares.
///
/// `publish: {http_field: run_id}` and nothing else — one name for one name, so a row that runs the
/// same step twice can say which value stands under which name. Whether the step declares the name
/// on the left is not asked here: this loader has never seen a registry, and the resolver refuses it
/// there naming the step and everything it does publish.
Map<MeasurementName, MeasurementName> _publish(YamlMap entry, String label, _Refusals refusals) {
  final YamlNode? node = entry.nodes['publish'];
  if (node == null) {
    return const <MeasurementName, MeasurementName>{};
  }
  if (node is! YamlMap) {
    refusals.add(
      node.span.start.line,
      '$label: "publish" maps a name the step declares to the name this row publishes it under, '
      'and the file gives ${_kindOf(node)}',
    );
    return const <MeasurementName, MeasurementName>{};
  }

  final Map<MeasurementName, MeasurementName> renamed = <MeasurementName, MeasurementName>{};
  for (final MapEntry<Object?, YamlNode> pair in node.nodes.entries) {
    final int line = _lineOf(pair.key) ?? pair.value.span.start.line;
    final Object? declared = (pair.key as YamlNode?)?.value;
    final Object? under = pair.value.value;
    if (declared is! String || !MeasurementName.isValid(declared)) {
      refusals.add(
        line,
        '$label: "publish" is keyed by a measurement name the step declares, and the file gives '
        '"$declared" — lower case letters, digits and underscores, in parts separated by dots',
      );
      continue;
    }
    if (under is! String || !MeasurementName.isValid(under)) {
      refusals.add(
        line,
        '$label: "publish" writes "$declared" under "$under", and that is not a measurement name — '
        'lower case letters, digits and underscores, in parts separated by dots',
      );
      continue;
    }
    renamed[MeasurementName(declared)] = MeasurementName(under);
  }
  return renamed;
}

/// A boolean an entry may write, false unless the file says otherwise.
bool _flag(YamlMap entry, String key, String label, _Refusals refusals) {
  final YamlNode? node = entry.nodes[key];
  if (node == null) {
    return false;
  }
  if (node.value case final bool written) {
    return written;
  }
  refusals.add(
    node.span.start.line,
    '$label: "$key" is true or false, and the file gives ${_kindOf(node)}',
  );
  return false;
}

/// Whether this entry may be taken back, which is true unless the file says otherwise.
///
/// The one key of an entry that HAS a default, and that is the opposite of how `on_failure` is
/// treated on purpose. A failure policy nobody chose gets applied to the step nobody thought about,
/// which is exactly the step whose policy turns out to be wrong — so it is required. Undo is the
/// other way round: a step that can be taken back should be, and switching that off is a decision
/// somebody makes about ONE installation. So the file says so where it is meant and stays quiet
/// everywhere else, and a reader who sees the key knows somebody decided.
bool _undo(YamlMap entry, String label, _Refusals refusals) {
  final YamlNode? node = entry.nodes['undo'];
  if (node == null) {
    return true;
  }
  if (node.value case final bool written) {
    return written;
  }
  refusals.add(
    node.span.start.line,
    '$label: "undo" is true or false, and the file gives ${_kindOf(node)}',
  );
  return true;
}

/// The registered step name an entry writes, or null when it is missing or malformed.
StepName? _stepName(YamlMap entry, int index, _Refusals refusals) {
  final YamlNode? node = entry.nodes['step'];
  if (node == null) {
    refusals.add(entry.span.start.line, 'steps[$index] has no "step"');
    return null;
  }
  if (node.value case final String written) {
    if (StepName.isValid(written)) {
      return StepName(written);
    }
    refusals.add(
      node.span.start.line,
      'steps[$index]: "$written" is not a step name — lower case letters, digits and underscores, '
      'starting with a letter',
    );
    return null;
  }
  refusals.add(
    node.span.start.line,
    'steps[$index]: "step" is text, and the file gives ${_kindOf(node)}',
  );
  return null;
}

/// What a failure of this entry costs the run.
///
/// There is no default. A default would be a policy nobody chose, applied to the step somebody
/// forgot to think about, and those are the steps whose failure policy turns out to be wrong.
OnFailure? _onFailure(YamlMap entry, String label, _Refusals refusals) {
  final YamlNode? node = entry.nodes['on_failure'];
  if (node == null) {
    refusals.add(entry.span.start.line, '$label has no "on_failure" — say exit or continue');
    return null;
  }
  if (node.value case final String written) {
    final OnFailure? policy = onFailureWritten[written];
    if (policy != null) {
      return policy;
    }
    refusals.add(
      node.span.start.line,
      '$label: "on_failure" is "$written", and it is exit or continue',
    );
    return null;
  }
  refusals.add(
    node.span.start.line,
    '$label: "on_failure" is exit or continue, and the file gives ${_kindOf(node)}',
  );
  return null;
}

/// The conditions that must all hold for this entry to run.
List<PredicateName> _when(YamlMap entry, String label, _Refusals refusals) {
  final YamlNode? node = entry.nodes['when'];
  if (node == null) {
    return const <PredicateName>[];
  }
  if (node is! YamlList) {
    refusals.add(
      node.span.start.line,
      '$label: "when" is a list of predicate names, and the file gives ${_kindOf(node)}',
    );
    return const <PredicateName>[];
  }

  final List<PredicateName> when = <PredicateName>[];
  for (final YamlNode element in node.nodes) {
    if (element.value case final String written) {
      if (PredicateName.isValid(written)) {
        when.add(PredicateName(written));
      } else {
        refusals.add(
          element.span.start.line,
          '$label: "$written" is not a predicate name — lower case letters, digits and '
          'underscores, starting with a letter',
        );
      }
      continue;
    }
    refusals.add(
      element.span.start.line,
      '$label: "when" holds predicate names, and the file gives ${_kindOf(element)}',
    );
  }
  return when;
}

/// What one row gives its step: the values written out, and the ones taken from a measurement.
///
/// Held apart because they are different things. A value is in the file and a reader sees it; a
/// measurement is a name standing for something the machine says while the run happens, and only the
/// resolver can tell whether any row produces it.
final class _Given {
  const _Given(this.arguments, this.reads);

  /// The values the row wrote out.
  final Arguments arguments;

  /// Which argument takes its value from which measurement.
  final Map<String, MeasurementName> reads;
}

/// Everything the entry says that is not [_stepKeys], as the values the step is given.
///
/// The values keep the types YAML gave them, so text stays a [String] and a whole number stays an
/// [int]. Whether the step declares the key at all, and whether the kind is the one it declared, is
/// checked against the registry afterwards.
_Given _given(YamlMap entry, String label, _Refusals refusals) {
  final Map<String, Object> values = <String, Object>{};
  final Map<String, MeasurementName> reads = <String, MeasurementName>{};
  for (final MapEntry<Object?, YamlNode> pair in entry.nodes.entries) {
    if (pair.key case YamlScalar(value: final String key)) {
      if (_stepKeys.contains(key)) {
        continue;
      }
      // Asked before the value is read, because the one map an argument may hold is not a value.
      // A key cannot carry both: the parser refuses a document that writes one key twice, so a row
      // saying where a value comes from cannot also write the value.
      if (_measured(pair.value, key, label, refusals) case final _Measured written) {
        if (written.name case final MeasurementName name) {
          reads[key] = name;
        }
        continue;
      }
      final Object? value = _argument(pair.value, key, label, refusals);
      if (value != null) {
        values[key] = value;
      }
      continue;
    }
    refusals.add(
      _lineOf(pair.key) ?? pair.value.span.start.line,
      '$label: an argument name is text, and the file gives something else',
    );
  }
  return _Given(Arguments(values), reads);
}

/// That a row wrote `{measured: <name>}` for an argument, and the name where it is one.
///
/// Null for the name means the shape was right and the name was not, which has already been refused
/// — the row is still known to take a measurement there, so nothing goes on to read it as a value.
final class _Measured {
  const _Measured(this.name);

  /// The name the row wrote, or null when it was refused.
  final MeasurementName? name;
}

/// The measurement [node] names, or null when it is not the one map an argument may hold.
///
/// `{measured: host.upstream_resolvers}` and nothing else. It is a MAP rather than a marker inside
/// text on purpose: a marker could stand in the middle of a longer value, and a value half written
/// by the file and half by the machine is a template — which is a program file computing, one step
/// away from being the thing that gets debugged instead of the code.
_Measured? _measured(YamlNode node, String key, String label, _Refusals refusals) {
  if (node is! YamlMap) {
    return null;
  }
  final YamlNode? named = node.nodes['measured'];
  if (named == null || node.nodes.length != 1) {
    // Left to [_argument], which refuses every map and says which single one is legal.
    return null;
  }
  if (named.value case final String written) {
    if (MeasurementName.isValid(written)) {
      return _Measured(MeasurementName(written));
    }
    refusals.add(
      named.span.start.line,
      '$label: "$key" takes "$written", and that is not a measurement name — lower case letters, '
      'digits and underscores, in parts separated by dots',
    );
    return const _Measured(null);
  }
  refusals.add(
    named.span.start.line,
    '$label: "$key" takes a measurement, and its name is text — the file gives ${_kindOf(named)}',
  );
  return const _Measured(null);
}

/// One argument value, or null when it is of a shape no step can hold.
Object? _argument(YamlNode node, String key, String label, _Refusals refusals) {
  if (node is YamlList) {
    // The only list an argument can hold is a list of text, so the element type is fixed here
    // rather than left as a list of whatever the file happened to write. A list built as
    // `List<Object>` would fail the registry's kind check with a message about a type nobody wrote.
    final List<String> texts = <String>[];
    bool whole = true;
    for (final YamlNode element in node.nodes) {
      if (element.value case final String text) {
        texts.add(text);
        continue;
      }
      refusals.add(
        element.span.start.line,
        '$label: the list "$key" holds text, and one entry is ${_kindOf(element)}',
      );
      whole = false;
    }
    return whole ? texts : null;
  }
  if (node is YamlMap) {
    if (node.nodes.containsKey('measured')) {
      // A map NAMING a measurement is the wiring, and it holds that one key and nothing else. A
      // second key beside it would make the value half the file's and half the machine's, which is
      // a slot becoming an expression — refused here rather than read as an ordinary mapping.
      refusals.add(
        node.span.start.line,
        '$label: "$key" takes a measurement, and {measured: <name>} is the whole of it — a second '
        'key beside it would make the value part written here and part measured there',
      );
      return null;
    }
    // Two maps are legal on a row and they are told apart by their shape, not by asking a registry
    // this loader has not got: `{measured: <name>}` takes the value from a measurement an earlier
    // row publishes, and is handled before this. Anything else is a MAPPING — a name on the left, a
    // small declaration under it — which a step may declare an argument of. Whether THIS argument
    // may hold one is the argument check's question, and it refuses with the step and the key named.
    //
    // What is read here is data and stays data: keys and scalars, one level of nesting, and nothing
    // that could be an expression. A map whose value is a list or a deeper map is refused, because a
    // shape nobody declared is a shape somebody would start putting meaning into.
    final Map<String, Object?> mapping = <String, Object?>{};
    bool whole = true;
    for (final MapEntry<Object?, Object?> pair in node.nodes.entries) {
      final Object? name = (pair.key as YamlNode?)?.value;
      final Object? under = pair.value;
      if (name is! String) {
        refusals.add(node.span.start.line, '$label: "$key" has an entry whose name is not text');
        whole = false;
        continue;
      }
      if (under is YamlMap) {
        final Map<String, Object?> body = <String, Object?>{};
        for (final MapEntry<Object?, Object?> inner in under.nodes.entries) {
          final Object? slot = (inner.key as YamlNode?)?.value;
          final Object? held = (inner.value as YamlNode?)?.value;
          if (slot is! String || held is! Object) {
            refusals.add(
              under.span.start.line,
              '$label: "$key.$name" holds a name and one value under it, and nothing deeper',
            );
            whole = false;
            continue;
          }
          body[slot] = held;
        }
        mapping[name] = body;
        continue;
      }
      if (under is YamlNode) {
        if (under.value case final Object held) {
          mapping[name] = held;
          continue;
        }
      }
      refusals.add(node.span.start.line, '$label: "$key.$name" has no value');
      whole = false;
    }
    return whole ? mapping : null;
  }
  if (node.value case final Object value) {
    return value;
  }
  refusals.add(node.span.start.line, '$label: "$key" has no value');
  return null;
}

/// What [node] is, in the words a refusal uses.
String _kindOf(YamlNode node) {
  if (node is YamlList) {
    return 'a list';
  }
  if (node is YamlMap) {
    return 'a map';
  }
  return switch (node.value) {
    null => 'nothing',
    String _ => 'text',
    int _ => 'a whole number',
    double _ => 'a decimal number',
    bool _ => 'true or false',
    _ => 'something else',
  };
}

/// The source line of [node] counted from zero, or null when it is not a node at all.
int? _lineOf(Object? node) => node is YamlNode ? node.span.start.line : null;
