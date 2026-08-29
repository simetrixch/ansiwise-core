library;

import 'package:meta/meta.dart';

import '../model/names.dart';

/// The rules by which one answer is worked out from another, as a CLOSED set of names.
///
/// **Why this exists at all.** Some values an installation needs are not questions anybody should be
/// asked, because they follow from a question already answered. A cluster's short name is the first
/// label of its domain; asking for both invites somebody to type a pair that does not match, and a
/// selector built on the mismatch then finds nothing and says nothing.
///
/// **Why it is a closed set of NAMES and not an expression.** A program file may not compute — the
/// moment it can, what is being debugged stops being the code and becomes the configuration. So a
/// file names a rule and the rule is Dart: typed, tested, and the same for everybody. The file
/// carries a name and a reference; there is no place in it for a concatenation, a condition, or a
/// second value.
///
/// **Why it happens BEFORE the first step and not during the run.** A run in the mode that changes
/// things is admitted only where a run in the mode that changes nothing came back green for the same
/// fingerprint, and that fingerprint is built from the resolved program plus the ANSWERS, before any
/// step runs. A value worked out here is part of it. A value worked out later would not be, and a
/// real run would then be admitted against a dry run that had used different values.
///
/// Adding a rule is adding a member here, with its own test. It is deliberately a small act with a
/// visible cost: a set nobody can extend from a program file is a set that cannot grow into a
/// language by accident.

/// One rule by which an answer is worked out from another.
enum DerivationRule {
  /// The first DNS label of a name — `m1.example.com` gives `m1`.
  ///
  /// What a cluster is called inside a fleet, everywhere a full domain would be too long or would
  /// not be a legal name. A value with no dot in it is its own first label and comes back unchanged;
  /// what this must never do is refuse, because whether the source is a domain at all is the shape
  /// check's question and not this one's.
  firstDnsLabel('first_dns_label_of', _firstDnsLabel),

  /// The name with its first DNS label taken off — `m1.example.com` gives `example.com`.
  ///
  /// The zone a name sits in, which is what tells two names apart that share a fleet. A value with
  /// no dot has nothing to take off and comes back unchanged.
  withoutFirstDnsLabel('without_first_dns_label_of', _withoutFirstDnsLabel),

  /// The value itself, unchanged.
  ///
  /// For the case where an answer is only ever ANOTHER answer when nobody supplied it — a cluster
  /// naming which one keeps the books, where leaving it out means "this one". Written as a default
  /// rather than as a derivation, it fills only what was not answered, and the two are the same rule
  /// under two triggers: `derived` always, `default_from` where nothing was given.
  itself('itself', _itself),

  /// Whether two answers hold the same text, as the word `true` or the word `false`.
  ///
  /// The relation a file gates on where nobody types the relation itself. Whether this cluster is
  /// also the one that builds is such a fact: both addresses are answered, and a third answer
  /// stating whether they match would be the same fact twice, which is a pair that can disagree.
  ///
  /// The two words and not a flag, because what reads it is a template slot, and a slot holds text.
  sameAs('same_as', _sameAs, sources: 2),

  /// Whether two answers hold different text, as the word `true` or the word `false`.
  ///
  /// The other direction, written out rather than reached by a negation somewhere else, for the
  /// reason the conditions of a program are two names rather than one and a `not:`.
  differsFrom('differs_from', _differsFrom, sources: 2),

  /// The first part of a role that names several joined by `+` — `master+slave` gives `master`.
  ///
  /// A machine doing several jobs at once carries them as ONE role value ([Role]), and what admits
  /// workloads per part reads one part per slot — so a selection stamped from a combined role
  /// takes it apart here instead of a program file computing on it. A value with no `+` in it is
  /// its own first part and comes back unchanged; whether the source is a role at all is its
  /// declaration's question and not this one's.
  firstPart('first_part_of', _firstPart),

  /// The last part of such a role — `master+slave` gives `slave`, and a value with no `+` comes
  /// back unchanged.
  ///
  /// The other slot of the same selection. Unlike the first part, the last is always a SINGLE
  /// part, so the pair covers a two-part union whole — a union of three parts would need a third
  /// slot wherever this pair is read, and that reading is the reader's to declare.
  lastPart('last_part_of', _lastPart);

  /// Declares a rule under the name a program file writes.
  const DerivationRule(this.written, this._apply, {this.sources = 1});

  /// The name a program file writes for this rule.
  final String written;

  final String Function(String, String) _apply;

  /// How many answers this rule reads: one, or a pair.
  final int sources;

  /// [source] under this rule.
  /// The value this rule works out. [other] is given exactly for the rules that read a pair.
  String applyTo(String source, [String other = '']) => _apply(source, other);

  /// The rule [written] names, or null when nothing here is called that.
  ///
  /// Null and not a throw: the LOADER asks this to refuse a program file naming a rule that does not
  /// exist, and that refusal reads better than a stack trace. Everything past the loader holds a
  /// rule rather than a name.
  static DerivationRule? named(String written) {
    for (final DerivationRule rule in values) {
      if (rule.written == written) {
        return rule;
      }
    }
    return null;
  }

  /// Every rule's name, for a refusal that has to list them.
  static List<String> get allWritten => <String>[
    for (final DerivationRule rule in values) rule.written,
  ];
}

String _itself(String source, String _) => source;

String _sameAs(String source, String other) => '${source == other}';

String _differsFrom(String source, String other) => '${source != other}';

String _firstDnsLabel(String source, String _) => source.split('.').first;

String _firstPart(String source, String _) => Role(source).parts.first.value;

String _lastPart(String source, String _) => Role(source).parts.last.value;

String _withoutFirstDnsLabel(String source, String _) {
  final int dot = source.indexOf('.');
  return dot < 0 ? source : source.substring(dot + 1);
}

/// How one declared answer is worked out from another.
@immutable
final class Derivation {
  /// Declares that this answer is [rule] applied to the answer named [from].
  const Derivation({required this.rule, required this.from, this.and});

  /// The rule that works it out.
  final DerivationRule rule;

  /// The name of the answer it is worked out from.
  final String from;

  /// The name of the SECOND answer, for the rules that read a pair, and null for the rest.
  final String? and;
}
