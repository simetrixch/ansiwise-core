import '../domain/argument_check.dart';
import '../domain/arguments.dart';
import '../domain/measurement.dart';
import '../domain/program.dart';
import '../domain/registry.dart';
import '../domain/resolved_program.dart';
import '../model/failures.dart';
import '../model/names.dart';

/// Finds every name a program writes in the registry, and refuses the program when one is missing.
///
/// This is where the safety a compiler cannot give across a configuration boundary is restored. A
/// program file hands a step some values, and nothing about that is checked when the code is
/// compiled. It is checked here instead, before the first thing is looked at: every step name,
/// every predicate name, every argument key, every argument kind, every required argument, and
/// every answer name — wherever one appears, which is on a step, in an argument, in one entry of a
/// mapping, and in what a condition of the installation was pointed at.
///
/// A program that does not resolve is refused whole. Not the first bad entry — all of them, in one
/// message, because an operator fixing a program file one refusal per run is an operator running it
/// five times to learn five things it could have said at once.
final class ProgramResolver {
  /// Creates a resolver against [registry].
  const ProgramResolver(this.registry);

  /// What the names must be found in.
  final Registry registry;

  /// Binds [program] to the registry.
  ///
  /// Throws [ProgramInvalid] listing everything wrong with it.
  ResolvedProgram resolve(Program program) {
    final List<String> problems = <String>[];
    final List<ResolvedStep> resolved = <ResolvedStep>[];
    // Which program-wide defaults some step DECLARES, and which ones actually filled a row. Both
    // are needed because they fail differently: a name nothing declares is a misspelling, and a
    // name every row overrides is dead config. Neither is visible from the file, where both look
    // exactly like a key that decides something.
    final Set<String> defaultsDeclared = <String>{};
    final Set<String> defaultsFilled = <String>{};
    // Built before the rows are walked. Whether a row may take a value from a measurement is a
    // question about the WHOLE program — which row produces it, where that row stands, and what it
    // is gated on — and none of that can be answered from the row in front of us.
    final _Published published = _Published.of(program, registry, problems);

    for (int i = 0; i < program.steps.length; i++) {
      final ProgramStep entry = program.steps[i];
      final String where = '${program.name}[$i] ${entry.step}';

      final RegisteredStep? registered = registry.step(entry.step);
      if (registered == null) {
        problems.add('$where: no step is registered under that name');
        continue;
      }

      // Folded in HERE and not where a step is executed, so everything downstream reads one set of
      // values: the argument check below, the plan, the record, and the fingerprint a run is gated
      // against. A default applied later than this would leave the fingerprint blind to it, and a
      // run would pass the gate of a dry run made under other values.
      final ProgramStep filled = _filled(
        entry,
        registered,
        program.defaults,
        defaultsDeclared,
        defaultsFilled,
        problems,
      );

      for (final String answer in registered.answers) {
        if (program.answers.named(answer) == null) {
          problems.add('$where: reads the answer "$answer", and this program does not declare it');
        }
      }
      for (final ArgumentSpec spec in registered.arguments) {
        if (spec.kind == ArgumentKind.answerName && filled.arguments.has(spec.name)) {
          final String answerName = filled.arguments.text(spec.name);
          if (program.answers.named(answerName) == null) {
            problems.add(
              '$where: the argument "${spec.name}" names the answer "$answerName", and this program does not declare it',
            );
          }
        }
        // A MAPPING NAMES ANSWERS TOO, one per entry, and this walk is what checks them.
        //
        // `values: {build-plane: {answer: build_plane}}` binds a slot to an answer, and a resolver
        // that looks only at arguments whose whole value IS an answer name resolves a row binding a
        // slot to an answer nobody declared. What an operator then meets is a refusal at the moment
        // the template is filled — naming the SLOT, which is the half they did not get wrong, on a
        // run that has already begun.
        //
        // Both halves are named here because either can be the mistake: the slot may be misspelt
        // against the template, or the answer against the program, and a message carrying one of
        // them sends half the readers to the wrong file.
        if (spec.kind == ArgumentKind.mapping && filled.arguments.has(spec.name)) {
          final MappingEntries entries = mappingEntriesIn(filled.arguments.raw(spec.name));
          for (final MapEntry<String, String> refused in entries.refused.entries) {
            problems.add('$where: "${spec.name}" entry "${refused.key}" ${refused.value}');
          }
          for (final MapEntry<String, MappingSource> bound in entries.sources.entries) {
            if (bound.value case FromAnswer(:final String answer)) {
              if (program.answers.named(answer) == null) {
                problems.add(
                  '$where: "${spec.name}" fills "${bound.key}" from the answer "$answer", and '
                  'this program does not declare it',
                );
              }
            }
          }
        }
      }
      problems.addAll(
        argumentProblems(
          where: where,
          given: filled.arguments,
          declared: registered.arguments,
          noun: 'argument',
          // An argument the row takes from a measurement is not a missing one. What is wrong with
          // such a wiring is said below, in the words of the wiring — reporting it here as well
          // would tell the operator to write a value on a row that already says where the value
          // comes from.
          filledElsewhere: entry.reads.keys.toSet(),
        ),
      );

      final List<RegisteredPredicate> when = <RegisteredPredicate>[];
      for (final PredicateName name in entry.when) {
        final RegisteredPredicate? predicate = registry.predicate(name);
        if (predicate == null) {
          problems.add('$where: no predicate is registered under "$name"');
          continue;
        }
        if (predicate.takesArguments) {
          // A generic condition is the same code pointed at different facts, and a program row is a
          // list of bare names with nowhere to say which facts. Naming it directly would leave the
          // condition reading nothing, which is a condition that cannot answer — so it is refused
          // here, and the installation's configuration is where a name for it is made.
          problems.add(
            '$where: "$name" has to be told what to look at, and it is a name a program row '
            'cannot tell — give it a name of its own in the configuration and write that name here',
          );
          continue;
        }
        // WHAT A BOUND CONDITION READS IS ASKED HERE, and nowhere before this can ask it. The
        // installation's configuration points a generic condition at answers BY NAME, the program
        // declares its answers, and neither file has seen the other: the binding holds no program
        // and the loader holds no registry. Unchecked, the row resolves, the plan is drawn and
        // every check reports green, and the condition refuses instead — at the start of the
        // program it gates, which in an installation of several programs is after the ones before
        // it have already changed the machine.
        //
        // Read off the KIND and never off a list of condition names: which of a condition's values
        // are answer names is what its own declaration says, so one registered tomorrow is covered
        // without a line here being edited.
        for (final ArgumentSpec spec in predicate.arguments) {
          if (spec.kind != ArgumentKind.answerName || !predicate.bound.has(spec.name)) {
            continue;
          }
          final String answer = predicate.bound.text(spec.name);
          if (program.answers.named(answer) == null) {
            problems.add(
              '$where: "$name" reads the answer "$answer", and this program does not declare it',
            );
          }
        }
        if (_wrongSide(registered, predicate) case final String refusal) {
          problems.add('$where: $refusal');
        }
        when.add(predicate);
      }

      final _Measured measured = _measured(
        // With the program-wide defaults already folded in, because whether the step can be built
        // while one value is missing depends on the other values it is given.
        filled,
        registered,
        position: i,
        where: where,
        published: published,
        problems: problems,
      );

      resolved.add(
        ResolvedStep(
          entry: filled,
          registered: registered,
          when: when,
          measured: measured.arguments,
          measuredSlots: measured.slots,
        ),
      );
    }

    // A CONDITION AN ANSWER IS STATED UNDER HAS TO BE REGISTERED, and this is the first place that
    // can be asked: the loader reads a program file and has never seen the installation's
    // configuration, which is where a condition is given its name. Unchecked, a misspelt name would
    // make the answer look unconditional — never asked for, never refused — and an installation
    // would run without a value nobody noticed was missing.
    for (final ArgumentSpec spec in program.answers.specs) {
      if (spec.statedWhen case final StatedWhen stated) {
        if (registry.predicate(PredicateName(stated.predicate)) == null) {
          problems.add(
            '${program.name}: the answer "${spec.name}" is stated only under "${stated.predicate}", '
            'and no condition is registered under that name',
          );
        }
      }
    }

    for (final String name in program.defaults.names) {
      if (!defaultsDeclared.contains(name)) {
        problems.add(
          '${program.name}: no step of this program declares an argument named "$name", so the '
          'default written for it fills nothing',
        );
        continue;
      }
      if (!defaultsFilled.contains(name)) {
        problems.add(
          '${program.name}: every row that takes "$name" writes its own, so the default written '
          'for it fills nothing — leave it off a row, or take the default away',
        );
      }
    }

    if (problems.isNotEmpty) {
      throw ProgramInvalid(problems.join('\n'), where: program.name.value);
    }
    return ResolvedProgram(declared: program, steps: resolved);
  }

  /// Why [registered] may not be gated on [condition], or null where it may.
  ///
  /// **THE ONE THING A CHECK COULD NOT ASK UNTIL THE PAIRING WAS DECLARED.** Two registered names
  /// over one reading are how this framework writes a negation, and a row gated on the wrong one of
  /// them resolves, plans and reports every check green: the row is simply skipped, and the first
  /// honest answer comes from the machine. With the pair declared beside the predicate and the side
  /// declared beside the step, the swap is a refusal here, in the same list as an argument of the
  /// wrong kind.
  ///
  /// A step that says NOTHING about a pair it is gated on is refused as well. The alternative is
  /// that silence means "either side", and then a rule everything can opt out of by saying nothing
  /// holds nothing.
  String? _wrongSide(RegisteredStep registered, RegisteredPredicate condition) {
    if (condition.opposite case final PredicateName opposite) {
      // The condition as the program row names it, and what it READS where an installation gave one
      // use of a generic condition a name of its own. The reader has to be sent to both: the name is
      // in the program file, the pairing is in the plugin.
      final String said = condition.name == condition.generic
          ? '"${condition.name}"'
          : '"${condition.name}" reads "${condition.generic}"';

      Sidedness? side;
      for (final Sidedness each in registered.gatedOn) {
        if (each.predicate == condition.generic || each.predicate == opposite) {
          side = each;
          break;
        }
      }
      if (side == null) {
        return '$said, one side of the opposing pair "${condition.generic}" and "$opposite", and '
            'this step does not say which side of that pair it may run on';
      }
      if (side.eitherSide || side.predicate == condition.generic) {
        return null;
      }
      // Which name the operator is meant to write instead. The step names the plugin's condition,
      // the program file names the installation's, and only the registry holds both — so a refusal
      // that stopped at the plugin's name would send them looking in a file that does not carry it.
      final List<String> instead = <String>[
        for (final RegisteredPredicate each in registry.predicates.values)
          if (each.generic == opposite && !each.takesArguments) each.name.value,
      ]..sort();
      return '$said, and this step may run only where "$opposite" holds'
          '${instead.isEmpty ? '' : ' — gate this row on ${instead.join(' or ')}'}';
    }
    return null;
  }

  /// [entry] with every program-wide default it takes written into its arguments.
  ///
  /// A default is taken when the step DECLARES an argument of that name and the row did not write
  /// one. Declaring is what decides it: handing a step a value it has no argument for would be an
  /// unknown key, and the argument check would refuse the row for a name the row does not carry.
  ///
  /// A default that fills a SECRET argument is refused into [problems] rather than folded in.
  ProgramStep _filled(
    ProgramStep entry,
    RegisteredStep registered,
    Arguments defaults,
    Set<String> declaredSomewhere,
    Set<String> filledSomewhere,
    List<String> problems,
  ) {
    final Map<String, ArgumentSpec> declared = <String, ArgumentSpec>{
      for (final ArgumentSpec spec in registered.arguments) spec.name: spec,
    };
    final Map<String, Object> applicable = <String, Object>{};
    for (final String name in defaults.names) {
      final ArgumentSpec? spec = declared[name];
      if (spec == null) {
        continue;
      }
      if (spec.secret) {
        // A program file ships inside the binary to every installation, so a credential written into
        // one is the same credential everywhere. The loader refuses this for a declared ANSWER for
        // the same reason; without it here, the block added for paths and key names would be the way
        // around that refusal.
        problems.add(
          'the default "$name" fills a secret argument, and a program file ships to every '
          'installation — a credential belongs in a declared answer, never here',
        );
        // Counted as filled as well, or the sweep below would add "every row writes its own" on top
        // of a refusal that has already said what is wrong.
        declaredSomewhere.add(name);
        filledSomewhere.add(name);
        continue;
      }
      declaredSomewhere.add(name);
      // A row that says where the value comes from has decided the same thing as a row that writes
      // it out, so the program-wide default does not reach past it. Without this the row would carry
      // a default nothing ever uses — the measurement fills the argument when the step is built —
      // and the sweep below could not report it, because the default did technically fill a row.
      if (defaults.raw(name) case final Object value
          when entry.arguments.raw(name) == null && !entry.reads.containsKey(name)) {
        applicable[name] = value;
        filledSomewhere.add(name);
      }
    }
    if (applicable.isEmpty) {
      return entry;
    }
    return ProgramStep(
      step: entry.step,
      onFailure: entry.onFailure,
      arguments: entry.arguments.withDefaults(applicable),
      reads: entry.reads,
      publish: entry.publish,
      when: entry.when,
      undo: entry.undo,
      // Every field of the row is carried, and the only thing standing between them and being
      // silently dropped is that they are listed here. A field added to a row and forgotten in this
      // one place reaches the resolver as its default and nothing anywhere says so: the file states
      // it, the loader parses it, and the run behaves as though the line were not written.
      restsOnAnEarlierStep: entry.restsOnAnEarlierStep,
      keepsOutput: entry.keepsOutput,
    );
  }

  /// Where everything on [entry] that names a measurement takes its value from.
  ///
  /// Two places name one, and they are answered against the same table by the same rules: a whole
  /// ARGUMENT, written `content: {measured: <name>}`, and one ENTRY of a mapping argument, written
  /// `values: {run-id: {measured: <name>}}`.
  ///
  /// Every wiring that does not add up is refused into [problems] and left out of the result, so a
  /// program is only resolved once every one of them is bound to a row that produces it.
  _Measured _measured(
    ProgramStep entry,
    RegisteredStep registered, {
    required int position,
    required String where,
    required _Published published,
    required List<String> problems,
  }) {
    final Map<String, ArgumentSpec> declared = <String, ArgumentSpec>{
      for (final ArgumentSpec spec in registered.arguments) spec.name: spec,
    };
    // Sorted by the argument name, so the fingerprint's material and every message read the same
    // way whatever order the file happened to write the keys in.
    final List<MapEntry<String, MeasurementName>> readings = entry.reads.entries.toList()
      ..sort(
        (MapEntry<String, MeasurementName> a, MapEntry<String, MeasurementName> b) =>
            a.key.compareTo(b.key),
      );

    final List<MeasuredArgument> arguments = <MeasuredArgument>[];
    for (final MapEntry<String, MeasurementName> reading in readings) {
      final String argument = reading.key;
      final MeasurementName measurement = reading.value;
      final String takes = 'takes "$argument" from the measurement "$measurement"';

      final ArgumentSpec? spec = declared[argument];
      if (spec == null) {
        problems.add('$where: $takes, and this step has no argument "$argument"');
        continue;
      }
      if (spec.kind != ArgumentKind.text) {
        problems.add(
          '$where: $takes, and "$argument" holds ${spec.kind.name} — a measurement is text',
        );
        continue;
      }
      final _Publisher? publisher = _publisherOf(
        measurement,
        position: position,
        when: entry.when,
        where: where,
        takes: takes,
        published: published,
        problems: problems,
      );
      if (publisher == null) {
        continue;
      }
      // SECRECY MATCHES OR THE WIRING IS REFUSED, and it is one rule read in both directions. What
      // makes a credential safe is that the sink registers it with the redactor the moment it is
      // published — and only a measurement that DECLARES itself secret is registered. So an argument
      // the step calls secret may take only such a measurement: filled from an unregistered value it
      // would tell every reader the value is hidden while the record carries it in the clear. And an
      // argument that is not secret may not take one either: nothing would then say the value is a
      // credential, and a description of this program hands back what is not marked.
      if (spec.secret != publisher.spec.secret) {
        problems.add(
          '$where: $takes, and ${spec.secret ? '"$argument" is secret while that measurement is not' : 'that measurement is secret while "$argument" is not'} '
          '— what hides a credential is the sink registering it where it is published, and only a '
          'measurement declared secret is registered. Declare both or neither.',
        );
        continue;
      }

      arguments.add(
        MeasuredArgument(
          argument: argument,
          measurement: measurement,
          publisher: publisher.step,
          position: publisher.position,
        ),
      );
    }

    final List<MeasuredSlot> slots = _measuredSlots(
      entry,
      registered,
      position: position,
      where: where,
      published: published,
      problems: problems,
    );

    if (arguments.isNotEmpty || slots.isNotEmpty) {
      if (_whyNotBuildable(entry, registered) case final String refusal) {
        problems.add(
          '$where: takes a value from a measurement and cannot be built without it — $refusal. '
          'Everything that examines a program before it runs has to build the step, because the '
          'registry holds a factory and only an instance says whether a run can be taken back. '
          'Read that argument as an optional one, and read a mapping entry that names a '
          'measurement as one holding no value yet, so the step still builds while the value does '
          'not exist.',
        );
        return const _Measured(arguments: <MeasuredArgument>[], slots: <MeasuredSlot>[]);
      }
    }
    return _Measured(arguments: arguments, slots: slots);
  }

  /// Where each entry of [entry]'s mapping arguments that names a measurement takes its value from.
  ///
  /// The grammar of an entry is the framework's — [mappingEntriesIn] reads it — so the engine that
  /// writes the value in knows the shape it is writing into without knowing anything about the step
  /// that declared the mapping.
  List<MeasuredSlot> _measuredSlots(
    ProgramStep entry,
    RegisteredStep registered, {
    required int position,
    required String where,
    required _Published published,
    required List<String> problems,
  }) {
    final List<MeasuredSlot> slots = <MeasuredSlot>[];
    // Sorted by the argument and then by the entry, for the same reason the readings above are: the
    // order the file wrote the keys in is not part of what a run is.
    final List<ArgumentSpec> mappings = <ArgumentSpec>[
      for (final ArgumentSpec spec in registered.arguments)
        if (spec.kind == ArgumentKind.mapping && entry.arguments.has(spec.name)) spec,
    ]..sort((ArgumentSpec a, ArgumentSpec b) => a.name.compareTo(b.name));

    for (final ArgumentSpec spec in mappings) {
      final MappingEntries entries = mappingEntriesIn(entry.arguments.raw(spec.name));
      final List<String> named = entries.sources.keys.toList()..sort();
      for (final String slot in named) {
        if (entries.sources[slot] case FromMeasurement(:final MeasurementName measurement)) {
          final String takes =
              'fills "${spec.name}" entry "$slot" from the measurement "$measurement"';
          final _Publisher? publisher = _publisherOf(
            measurement,
            position: position,
            when: entry.when,
            where: where,
            takes: takes,
            published: published,
            problems: problems,
          );
          if (publisher == null) {
            continue;
          }
          if (publisher.spec.secret) {
            // A mapping entry carries no declaration of its own: nothing between the row and the
            // step says the value is a credential. What the record keeps of it then depends on the
            // text the step composes it into — the address of a request is recorded and its body is
            // not — and nothing here knows which of them this entry fills. A credential goes into an
            // argument the step declares secret, where the declaration says so to everything that
            // reads the program.
            problems.add(
              '$where: $takes, and that measurement is secret — a mapping entry says nothing about '
              'what it holds, and what the record keeps depends on the text this entry ends up in: '
              'the address of a request is recorded and its body is not, and nothing here knows '
              'which of them this is. Take a credential through an argument the step declares '
              'secret, where the declaration says so to everything that reads this program.',
            );
            continue;
          }
          slots.add(
            MeasuredSlot(
              argument: spec.name,
              slot: slot,
              measurement: measurement,
              publisher: publisher.step,
              position: publisher.position,
            ),
          );
        }
      }
    }
    return slots;
  }

  /// The one row that produces [measurement] for a row at [position] gated on [when], or null when
  /// the wiring does not add up — in which case the refusal has been added to [problems].
  ///
  /// ONE TABLE, ONE SET OF RULES. Whether a value exists when a row is built is a question about the
  /// whole program, and it is the same question whether the value fills an argument or one entry of
  /// a mapping. [takes] is how the caller says which of the two, so the refusal reads as the row
  /// wrote it.
  _Publisher? _publisherOf(
    MeasurementName measurement, {
    required int position,
    required List<PredicateName> when,
    required String where,
    required String takes,
    required _Published published,
    required List<String> problems,
  }) {
    final List<_Publisher> publishers = published.rowsFor(measurement);
    if (publishers.isEmpty) {
      final Iterable<String> names = published.names;
      problems.add(
        '$where: $takes, and no step of this program publishes it — this program publishes '
        '${names.isEmpty ? 'nothing' : names.join(', ')}',
      );
      return null;
    }
    if (publishers.length > 1) {
      // Already reported once against the program, naming both rows. A second message here would
      // say the same thing about the row that happens to read it.
      return null;
    }
    final _Publisher publisher = publishers.first;
    if (publisher.position >= position) {
      problems.add(
        '$where: $takes, and ${publisher.said} publishes it — that row runs after this one, so '
        'the value does not exist yet when this row is built',
      );
      return null;
    }
    final List<PredicateName> ungated = <PredicateName>[
      for (final PredicateName condition in publisher.when)
        if (!when.contains(condition)) condition,
    ];
    if (ungated.isNotEmpty) {
      problems.add(
        '$where: $takes, and ${publisher.said} publishes it only when '
        '${ungated.join(' and ')} holds, which this row does not ask for — so the value may be '
        'missing exactly when this row runs. Put the same condition on this row.',
      );
      return null;
    }
    return publisher;
  }

  /// Why [entry] cannot be built without the values it measures, or null when it can.
  ///
  /// MEASURED RATHER THAN DECLARED. Whether a step survives the absence of an argument is a property
  /// of its factory and not of its declaration: an argument declared optional and read as a required
  /// one throws exactly the same way. So the step is built, here, where a refusal still costs
  /// nothing — the alternative is a program that resolves and then throws in the endpoint that
  /// describes it and in the sentence that tells the operator what a run cannot take back.
  ///
  /// Every throwable is caught, and an [Error] is the one that matters: a step reading an argument
  /// that is not there throws [ArgumentError]. It is caught to be REPORTED, which is the whole of
  /// this method.
  String? _whyNotBuildable(ProgramStep entry, RegisteredStep registered) {
    final Map<String, Object> defaults = <String, Object>{
      for (final ArgumentSpec spec in registered.arguments)
        if (spec.defaultValue case final Object value) spec.name: value,
    };
    try {
      registered.create(entry.arguments.withDefaults(defaults));
      return null;
    } on Object catch (failure) {
      return failure.toString();
    }
  }
}

/// The table this whole mechanism is: which row of a program publishes which name, and what that
/// name stands for.
///
/// Keyed by the EFFECTIVE name — the one a row publishes under, which is the name the step declares
/// unless the row renamed it. Every question asked of a measurement is asked of this one table: does
/// anything produce this name, where does that row stand, what is it gated on, and is what it
/// produces a credential. A row that reads a value and a row that renames one are the same table
/// seen from two sides.
final class _Published {
  const _Published(this._rows);

  /// Reads [program] against [registry], refusing into [problems] a name two rows publish and a
  /// rename of a name its step does not publish.
  factory _Published.of(Program program, Registry registry, List<String> problems) {
    final Map<MeasurementName, List<_Publisher>> rows = <MeasurementName, List<_Publisher>>{};
    for (int i = 0; i < program.steps.length; i++) {
      final ProgramStep entry = program.steps[i];
      final RegisteredStep? registered = registry.step(entry.step);
      if (registered == null) {
        // The row itself is refused where the steps are walked. Saying it twice would make one
        // misspelled step name look like two problems.
        continue;
      }
      for (final MeasurementName renamed in entry.publish.keys) {
        if (!registered.publishes.any((MeasurementSpec spec) => spec.name == renamed)) {
          final Iterable<String> declared = registered.publishes.map(
            (MeasurementSpec spec) => spec.name.value,
          );
          problems.add(
            '${program.name}[$i] ${entry.step}: publishes "$renamed" under '
            '"${entry.publish[renamed]}", and this step publishes '
            '${declared.isEmpty ? 'nothing' : declared.join(', ')}',
          );
        }
      }
      for (final MeasurementSpec spec in registered.publishes) {
        rows
            .putIfAbsent(entry.publish[spec.name] ?? spec.name, () => <_Publisher>[])
            .add(_Publisher(position: i, step: entry.step, when: entry.when, spec: spec));
      }
    }

    for (final MapEntry<MeasurementName, List<_Publisher>> each in rows.entries) {
      if (each.value.length > 1) {
        // Refused even where nothing reads it yet. Two rows publishing one name make the value
        // depend on which of them ran last, and the row that starts reading it tomorrow would be
        // admitted against a wiring the file never states.
        problems.add(
          '${program.name}: the measurement "${each.key}" is published by '
          '${each.value.map((_Publisher p) => p.said).join(' and ')}, so nothing says which value a '
          'row taking it would get',
        );
      }
    }
    return _Published(rows);
  }

  final Map<MeasurementName, List<_Publisher>> _rows;

  /// The rows that publish [name], which is none, one, or the ambiguity refused above.
  List<_Publisher> rowsFor(MeasurementName name) => _rows[name] ?? const <_Publisher>[];

  /// Everything this program publishes, for a refusal that has to say what there was.
  Iterable<String> get names => _rows.keys.map((MeasurementName name) => name.value);
}

/// One row that publishes a measurement.
final class _Publisher {
  const _Publisher({
    required this.position,
    required this.step,
    required this.when,
    required this.spec,
  });

  /// Where it stands in the program, counted from zero.
  final int position;

  /// The step it names.
  final StepName step;

  /// The conditions that decide whether it runs at all.
  final List<PredicateName> when;

  /// What the step declared about the value, which is where secrecy is read from.
  ///
  /// The NAME in here is the one the step publishes, not the one this row publishes it under. The
  /// two differ wherever a row renamed it, and everything except secrecy is read from the table's
  /// key rather than from this.
  final MeasurementSpec spec;

  /// How a refusal names it, counting from one because a person reading a file counts that way.
  String get said => 'step ${position + 1} $step';
}

/// Everything on one row that takes its value from a measurement.
final class _Measured {
  const _Measured({required this.arguments, required this.slots});

  /// The whole arguments the row takes from a measurement.
  final List<MeasuredArgument> arguments;

  /// The entries of the row's mapping arguments it takes from a measurement.
  final List<MeasuredSlot> slots;
}
