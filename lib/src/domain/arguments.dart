import 'package:meta/meta.dart';

import '../model/names.dart';
import 'derivation.dart';

/// What kind of value an argument holds.
enum ArgumentKind {
  /// Text.
  text,

  /// A whole number.
  integer,

  /// True or false.
  flag,

  /// A list of text values.
  textList,

  /// The name of an answer.
  answerName,

  /// A mapping of a name to a small declaration under it.
  ///
  /// For the case a list cannot carry: a row that has to say WHICH of several things each of
  /// several names is filled from. A key on the left, a mapping of named slots on the right, and
  /// nothing that evaluates — no expression, no condition, no reference to another key. The step
  /// that declares one says in its own words which slots it reads and refuses anything else, the
  /// way it refuses an argument it does not declare.
  ///
  /// What one entry may say is [MappingSource] and it belongs to the framework, not to the step.
  mapping,
}

/// Where one entry of a mapping argument takes its value from.
///
/// **TWO WORDS ARE THE FRAMEWORK'S; THE REST OF A BODY IS THE STEP'S.** `answer:` takes the value
/// from an answer this run holds and `measured:` from a measurement an earlier row published. Those
/// two are declared here because the framework FILLS them — the engine writes a measured value into
/// a mapping entry, and a body the engine writes into is a body the engine has to be able to read.
///
/// **Everything else in a body is passed over, not refused.** A step that declares a mapping
/// argument may read properties of its own beside the source — `join`, `split`, `file`, `key` are
/// shipped examples — and a body naming NEITHER of the two words is a source the step resolves for
/// itself, which the engine has no business judging. Reading those would put a step's private
/// vocabulary inside the engine, which is the thing this file exists to prevent.
///
/// What IS refused is a body naming BOTH: two sources for one value, and nothing to say which.
///
/// **It is a named slot and not a language.** One name for one value, nothing nested under it,
/// nothing that evaluates.
@immutable
sealed class MappingSource {
  const MappingSource();
}

/// An entry filled from an answer this run holds.
@immutable
final class FromAnswer extends MappingSource {
  /// Binds an entry to the answer called [answer].
  const FromAnswer(this.answer);

  /// The name of the answer, as the program declares it.
  final String answer;
}

/// An entry filled from a measurement an earlier row of this program published.
@immutable
final class FromMeasurement extends MappingSource {
  /// Binds an entry to [measurement].
  const FromMeasurement(this.measurement);

  /// The name the value stands under.
  final MeasurementName measurement;
}

/// What the entries of one mapping argument say, read against the grammar [MappingSource] states.
@immutable
final class MappingEntries {
  /// Holds what was read out of one mapping.
  const MappingEntries({required this.sources, required this.refused});

  /// Nothing was written, so nothing is bound and nothing is wrong.
  static const MappingEntries nothing = MappingEntries(
    sources: <String, MappingSource>{},
    refused: <String, String>{},
  );

  /// Where each entry that names a source takes its value from, by the name the entry stands under.
  ///
  /// An entry whose value is written out in the file is not in here: it names no source.
  final Map<String, MappingSource> sources;

  /// What is wrong with each entry the framework could not read, by the name the entry stands under.
  ///
  /// Reported rather than passed over. An entry the framework cannot read is one nothing fills, and
  /// a run that passed over it would hand the step a slot that stays in the text as its own literal
  /// characters — which whatever reads the text next takes as content.
  ///
  /// The sentence says what is wrong and not where: only the caller knows the row and the argument
  /// the entry stands on, and a reader told the wrong thing about `{measured: Bad.Name}` goes
  /// looking in the wrong file.
  final Map<String, String> refused;
}

/// What each entry of [mapping] takes its value from, and what is wrong with the ones that name no
/// source and are not a value either.
///
/// A value that is not a mapping at all reads as nothing: whether this argument may hold a mapping
/// is the argument check's question, and answering it twice would put the same rule in two places.
MappingEntries mappingEntriesIn(Object? mapping) {
  if (mapping is! Map<String, Object?>) {
    return MappingEntries.nothing;
  }
  final Map<String, MappingSource> sources = <String, MappingSource>{};
  final Map<String, String> refused = <String, String>{};
  for (final MapEntry<String, Object?> each in mapping.entries) {
    final Object? body = each.value;
    if (body is! Map<String, Object?>) {
      // The value written out by the row. It names no source, and there is nothing here to check.
      continue;
    }
    final Object? fromAnswer = body['answer'];
    final Object? fromMeasurement = body['measured'];
    if (fromAnswer != null && fromMeasurement != null) {
      refused[each.key] =
          'names an answer and a measurement at once, and nothing says which of them the value '
          'comes from — a body carries one source or the other';
      continue;
    }
    if (fromAnswer case final String answer) {
      sources[each.key] = FromAnswer(answer);
      continue;
    }
    if (fromMeasurement case final String measured) {
      if (!MeasurementName.isValid(measured)) {
        refused[each.key] =
            'takes the measurement "$measured", and that is not a measurement name — lower case '
            'letters, digits and underscores, in parts separated by dots';
        continue;
      }
      sources[each.key] = FromMeasurement(MeasurementName(measured));
      continue;
    }
    // A body naming neither word. Where the value comes from is the step's own business, and it is
    // passed over exactly as a written-out scalar is.
  }
  return MappingEntries(sources: sources, refused: refused);
}

/// The condition that determines whether an answer must be provided.
///
/// An answer with a condition is requested only where the condition holds. Where it does not, the
/// answer must not be given, and one given anyway is refused — both before the first step runs,
/// which is the whole value of stating it here rather than letting a row fail later.
///
/// **The condition is a REGISTERED NAME, and never a comparison written in the file.** A program file
/// that can compare two values can compare anything, and then what gets debugged is the file. The
/// comparison lives in a class with its own probes, is bound to this installation's own facts in its
/// configuration, and the program row writes one bare word — the same rule `when:` has always had.
@immutable
final class StatedWhen {
  /// Declares that an answer is asked for only where the condition called [predicate] holds.
  const StatedWhen({required this.predicate});

  /// The registered condition that decides whether this answer is asked for.
  final String predicate;
}

/// What a whole number can plausibly MEAN, declared beside the argument that has the meaning.
///
/// **A BAND IS NOT A LIMIT.** It says what the number can plausibly stand for, never what this
/// platform requires. A floor on the memory of a machine that accepts three gigabytes and refuses
/// one is doing its whole job; whether four or eight is the right size for a product is a decision
/// somebody makes in a program file, where a person can read it. A band written as the number it
/// means refuses the values it means to accept — a machine's memory is compared against what the
/// kernel leaves after its own reservations, which is several per cent short of the size printed on
/// the part.
///
/// **[because] is required on both constructors**, so an edge is a sentence rather than a number
/// somebody typed. A refusal that fires on a legitimate value is widened in a hurry and then means
/// nothing, and the person widening it has to disagree with the reason rather than only with the
/// figure.
@immutable
final class IntegerBand {
  /// States the two edges of what this number can plausibly mean, and why they are where they are.
  ///
  /// Both edges, because an argument whose upper edge nobody can name is one nobody has thought
  /// about all the way through: a timeout of a thousand million seconds is not a long timeout, it is
  /// a value nobody meant.
  const IntegerBand.between({required this.least, required this.most, required this.because});

  /// States that this number has no plausible band at all, and why there is none.
  ///
  /// Written out rather than left off, because nothing can tell an argument whose value genuinely
  /// may be anything from one nobody has looked at, and the two are treated identically by every
  /// check that reads only the kind.
  const IntegerBand.none({required this.because}) : least = null, most = null;

  /// The lowest value that can plausibly be meant, or null where there is no such value.
  final int? least;

  /// The highest value that can plausibly be meant, or null where there is no such value.
  final int? most;

  /// Why the edges are where they are, or why there are none.
  final String because;

  /// What is wrong with [value] against this band, in the words a refusal uses, or null.
  String? refuses(int value) {
    final int? low = least;
    final int? high = most;
    if (low == null || high == null) {
      return null;
    }
    if (value >= low && value <= high) {
      return null;
    }
    return 'holds a whole number from $low to $high, and was given $value — $because';
  }
}

/// One argument a step accepts, declared by the step and checked before anything runs.
///
/// This is where the safety a compiler cannot give across a configuration boundary is restored. A
/// program file names a step and hands it values; nothing about that is type-checked at build time.
/// It is checked instead at the first gate, against these declarations, and a program that gives a
/// step an argument it does not have is refused before the first mutation.
@immutable
final class ArgumentSpec {
  /// Declares one argument.
  const ArgumentSpec({
    required this.name,
    required this.kind,
    required this.describes,
    this.required = true,
    bool secret = false,
    this.defaultValue,
    this.allowed = const <String>[],
    this.shape,
    this.band,
    this.denied = const <String>[],
    this.statedWhen,
    this.derivation,
    this.defaultFrom,
  }) : _declaredSecret = secret;

  /// The key a program file writes.
  final String name;

  /// What kind of value it holds.
  final ArgumentKind kind;

  /// What it is for, shown to whoever is filling it in.
  final String describes;

  /// Whether a program must give it.
  final bool required;

  final bool _declaredSecret;

  /// Whether the value is a credential or a key.
  ///
  /// Two things follow from it and neither is optional. The client shows a field that does not echo
  /// what is typed, and the value is never sent back out — a description of a program tells a reader
  /// that a secret is set, never what it is.
  ///
  /// **It is answered by the DECLARATION and by the rule together**, so that every reader of this
  /// one property is right about both. Whoever declares the answer says it; and an answer worked
  /// out by a rule that reads a file off the machine is one whatever the declaration says, because
  /// the value was never typed and a record is a file every account on the machine may read. Asked
  /// of the declaration alone, one program file forgetting the word would put a credential in the
  /// clear in a run record, in a log line, and in the description a client is given.
  bool get secret => _declaredSecret || (derivation?.rule.readsAFile ?? false);

  /// What it is when a program does not give it.
  final Object? defaultValue;

  /// The only values this may hold, or empty where any value of its kind will do.
  ///
  /// Most values are carried rather than decided: a domain, a mailbox, a credential. A few are
  /// DECIDED on — a role is one of two words, a stage one of three — and for those the kind is not
  /// the whole of what is legal. Saying so here rather than inside the step that reads it buys three
  /// things at once:
  ///
  /// - a value outside the set is refused BEFORE the run starts, with the set in the message, rather
  ///   than blocking a step somewhere in the middle of an installation
  /// - the client renders a CHOICE instead of a free-text box, which is the whole promise of building
  ///   the form from the declaration and is least keepable exactly where a typo is most likely
  /// - a check probing every step reads the legal values the way it already reads the kinds, instead
  ///   of carrying a hand-written list of its own that has to agree with the steps
  ///
  /// Only text has such a set: a flag already has two values, and a number or a list of text has no
  /// small closed one worth writing out.
  final List<String> allowed;

  /// A specific shape a text value must have, such as a hostname or a mailbox.
  final String? shape;

  /// What this whole number can plausibly mean, or null where nothing has been said about it.
  ///
  /// The three declarations above hold TEXT and only text — `allowed` is a closed set of words,
  /// `denied` a list of them, `shape` a grammar — so for a number the kind was the whole check and a
  /// memory floor of one kilobyte, a file mode of 0777 and a timeout of one second were each
  /// accepted by everything before the machine.
  ///
  /// Null is what nobody has said anything about, and a step registered with one is refused when the
  /// plugins are composed. An argument whose value genuinely may be any whole number states
  /// [IntegerBand.none] with the reason, which is what makes "there is no plausible band" tellable
  /// from "nobody looked".
  final IntegerBand? band;

  /// Values this argument must never hold, even if they are of the right kind.
  final List<String> denied;

  /// The condition that dictates whether this answer should be asked at all.
  final StatedWhen? statedWhen;

  /// How this answer is worked out from another, or null where somebody supplies it.
  ///
  /// An answer with one is never asked for and never accepted from an operator: it follows from a
  /// question already answered, and taking it as well would let a pair be given that does not match.
  final Derivation? derivation;

  /// Whether this answer is worked out rather than supplied.
  bool get isDerived => derivation != null;

  /// The name of the answer this one falls back to when nobody supplied it.
  ///
  /// The difference from [derivation] is the trigger and nothing else. A derived answer is worked
  /// out ALWAYS and may never be supplied; one with a fallback is supplied where it differs and
  /// falls back where it does not — which is how a value that is usually "the same as that one"
  /// stops being a second field somebody can type differently.
  final String? defaultFrom;

  /// Whether a value stands in for it when nobody answered, from wherever.
  bool get hasFallback => hasDefault || defaultFrom != null;

  /// Whether a value stands in for it when a program does not give it.
  bool get hasDefault => defaultValue != null;

  /// Whether [value] is of the kind this argument holds.
  ///
  /// The kind ONLY. Whether it is one of the values this argument may hold is [permits], asked
  /// separately so a wrong kind and a wrong value produce different sentences: "this holds text and
  /// was given an int" and "this holds one of master, slave" are different mistakes, and telling an
  /// operator the first when they made the second sends them looking in the wrong place.
  bool accepts(Object value) => switch (kind) {
    ArgumentKind.text => value is String,
    ArgumentKind.answerName => value is String,
    ArgumentKind.integer => value is int,
    ArgumentKind.flag => value is bool,
    ArgumentKind.textList => value is List<String>,
    ArgumentKind.mapping => value is Map<String, Object?>,
  };

  /// Whether [value] is one of the values this argument may hold.
  ///
  /// True where none are declared: an argument with no closed set permits anything of its kind.
  /// Refuses a value if it is on the denied list.
  bool permits(Object value) {
    if (value is String && denied.contains(value)) {
      return false;
    }
    return allowed.isEmpty || (value is String && allowed.contains(value));
  }
}

/// The values a program gave one step.
///
/// Already validated against the step's declared [ArgumentSpec] list by the time a step sees it, so
/// the accessors here fail loudly on a name the step never declared rather than returning null and
/// letting the mistake travel.
@immutable
final class Arguments {
  /// Holds the validated values for one step.
  const Arguments(this._values);

  /// No arguments.
  static const Arguments none = Arguments(<String, Object>{});

  final Map<String, Object> _values;

  /// Whether [name] was given.
  bool has(String name) => _values.containsKey(name);

  /// The keys a program gave, so the resolver can report one that no step declares.
  Iterable<String> get names => _values.keys;

  /// The raw value of [name], for the resolver to check against a declaration.
  Object? raw(String name) => _values[name];

  /// A copy of these values with [defaults] filled in wherever a key is missing.
  Arguments withDefaults(Map<String, Object> defaults) =>
      Arguments(<String, Object>{...defaults, ..._values});

  /// The text value of [name].
  String text(String name) => _read<String>(name);

  /// The whole number value of [name].
  int integer(String name) => _read<int>(name);

  /// The true-or-false value of [name].
  bool flag(String name) => _read<bool>(name);

  /// The list of text values of [name].
  List<String> textList(String name) => _read<List<String>>(name);

  /// The text value of [name], or null when it was not given.
  ///
  /// Absent and present-as-another-kind are different mistakes, and only the first is what an
  /// optional argument is for: nothing given is a null and the step builds. A value of another kind
  /// is a row that named its argument wrong, and it is refused in [_read]'s words — a cast here
  /// would report the operator's misspelling as a type failure inside the step.
  String? optionalText(String name) => _values[name] == null ? null : _read<String>(name);

  T _read<T>(String name) {
    final Object? value = _values[name];
    if (value == null) {
      throw ArgumentError.value(
        name,
        'name',
        'the step read an argument it did not declare, or the loader let a required one through',
      );
    }
    if (value case final T typed) {
      return typed;
    }
    throw ArgumentError.value(
      name,
      'name',
      'declared as $T but the program gave ${value.runtimeType}',
    );
  }
}

/// The argument a step declares when what it is pointed at may be reachable only as root.
///
/// **Written once because it is the same question everywhere.** Whether a path belongs to root, or
/// whether a tool refuses the account the run started as, is a property of the MACHINE and of what
/// the row pointed the step at — so the row answers, and a step that decided for every caller would
/// be a package knowing something about the product that used it. Twenty-eight steps ask it, and
/// twenty-eight copies of the same paragraph would disagree with each other within a month.
///
/// **It covers both ports, and one without the other is the failure to look for.** A step that reads
/// through the shell and writes through the file port needs the same answer on both; a step that
/// ASKS as the operator and ACTS as root gets an answer that is not the one it waits for, because a
/// refused tool very often writes the refusal on its output and exits zero.
///
/// **Reading and writing as root does not make either act anything else.** A read stays a read, so a
/// dry run performs it; a write stays a write, so a dry run refuses it. Elevation says what may be
/// REACHED, never whether anything changes.
///
/// A step declares it by putting this in its own argument list, carries it as a field, and passes it
/// to every call it makes. Passing it to some calls and not others is the failure to look for: the
/// call the row is obviously about carries it, and the backup written beside it does not.
const ArgumentSpec elevationArgument = ArgumentSpec(
  name: 'elevated',
  kind: ArgumentKind.flag,
  required: false,
  describes:
      'whether what this row points at is reachable only as root — a file root owns, or a tool that '
      'refuses the account the run started as. Leave it off where the account running the program '
      'owns the path and the tool answers it',
);
