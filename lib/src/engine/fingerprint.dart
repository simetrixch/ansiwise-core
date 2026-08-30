import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/arguments.dart';
import '../domain/registry.dart';
import '../domain/resolved_program.dart';

/// What makes two runs the same input.
///
/// The gate refuses a real run unless a clean dry run exists for exactly this value, so what goes
/// into it decides what an operator is allowed to change between the two. Each part is here for a
/// reason a reader should not have to guess:
///
/// - **the program's name** — the obvious one
/// - **every argument every step resolved to**, defaults included, because a default that changed
///   in the code between the dry run and the real one is a changed input even though nobody typed
///   anything
/// - **every ANSWER the program declared**, because a step reads answers by name out of the run and
///   they decide what it does: which branch is cut, which configuration file is written, which
///   machine is treated as the master. A dry run of one installation would otherwise admit a real
///   run of another
/// - **whether each row may be taken back**, because a row whose undo is switched off moves the
///   point of no return, and the operator read that boundary off the dry run
/// - **the WIRING of every place whose value is measured while the run happens** — the name it
///   takes, and the row that produces it. The value itself cannot be here: it does not exist yet
///   when this is computed. What the material therefore states is exactly which places were left
///   out and where each of them will come from, so a row rewired between two runs cannot hash like
///   the one before it. There are TWO such places and both are written: a whole ARGUMENT, and one
///   ENTRY of a mapping argument. The entry needs its own field even though the mapping's value is
///   already here, because the body an entry carries names only the MEASUREMENT — which row
///   publishes that name is decided by the renames the rows carry, and a rename is nowhere in this
///   material
/// - **every condition a row is gated on, and what that condition was pointed at** — a generic
///   condition is named by the installation and told what to look at there, so the name alone says
///   only half of what decides whether a row runs
/// - **the commit** the branch is on, because the same program at a different commit is a different
///   set of steps
///
/// What is deliberately NOT in it: the time, the run's own id, and the machine's own name. Those
/// differ between any two runs, and including them would mean no dry run ever satisfied the gate.
///
/// **Nor is the value of an answer that is the secret in a FILE on the machine**, and for the same
/// reason a measured argument's value is not here: it does not exist when this is computed. The
/// answer that names the PATH is an ordinary answer and IS in the material, so the wiring is
/// covered and a program pointed at another file cannot hash like this one. What a dry run
/// therefore proves about such an answer is that the file was there and readable, not that the real
/// run will read the same text out of it. Putting the value in would have cost more than it bought:
/// a credential minted again between the dry run and the real one would leave the real run refused
/// by the gate for ever, with no retry able to clear it.
///
/// **A value cannot forge a field.** Every part is written with its length in front of it, so a
/// value carrying a newline is one value and not the start of another. Written as plain lines, a
/// step declaring text `a` and text `b` would fingerprint `a: "1\nb=2"` exactly like `a: "1"` with
/// `b: "2"` — two different runs, one hash, and the gate cannot tell them apart. Both are ordinary
/// quoted YAML scalars, so this is not a theoretical shape.
///
/// **What this still rests on:** a step's behaviour comes entirely from its declared arguments and
/// the answers it names. A step that reaches for a value from neither — a constant baked into its
/// constructor, something read from the environment — is invisible here, and two runs that differ
/// only in that value would fingerprint the same. That is the remaining way the gate can be fooled,
/// and it is a defect in the step: those are the two ways a value reaches a step, and a step taking
/// a third is a step nothing can gate.
String fingerprintOf({
  required ResolvedProgram program,
  required String commit,
  required Arguments answers,
}) {
  final StringBuffer material = StringBuffer();
  _field(material, 'program', program.declared.name.value);
  _field(material, 'commit', commit);

  // Sorted by the name the PROGRAM declared, so an answer file listing them in another order is the
  // same input. A declared answer that was not given is written as absent rather than skipped: an
  // answer going missing between the dry run and the real one is a changed input, and skipping it
  // would make the two hash alike.
  for (final ArgumentSpec spec in _sortedByName(program.declared.answers.specs)) {
    _valued(material, 'answer.${spec.name}', answers.raw(spec.name) ?? spec.defaultValue);
  }

  for (final ResolvedStep step in program.steps) {
    _field(material, 'step', step.entry.step.value);
    _field(material, 'on_failure', step.entry.onFailure.name);
    _field(material, 'undo', step.entry.undo.toString());
    for (final ArgumentSpec spec in _sortedByName(step.registered.arguments)) {
      // A value measured DURING the run cannot be in here, and what stands in its place is the
      // WIRING: which measurement fills this argument, and which row produces it. That is what
      // keeps two runs whose wiring differs from sharing a hash — rewiring a row to another
      // measurement, or to the same name published by another row, writes different material.
      // Without it the wiring would be nowhere in the material and a binary rebuilt with a row
      // rewired would fingerprint identically.
      //
      // The value is NOT written beside it, not even the step's own default. That default is what
      // makes the row examinable before the run; it is not what the step will run with, and writing
      // it would say the gate had seen a value it never sees.
      if (step.measurementFor(spec.name) case final MeasuredArgument measured) {
        _field(material, 'argument.${spec.name}.measured', measured.measurement.value);
        _field(
          material,
          'argument.${spec.name}.measured.from',
          '${measured.position}:${measured.publisher.value}',
        );
        continue;
      }
      final Object? given = step.entry.arguments.raw(spec.name);
      _valued(material, 'argument.${spec.name}', given ?? spec.defaultValue);
    }
    // The same wiring, one level down, for the ENTRY of a mapping argument. The body the row wrote
    // is already in the material above — it is part of the mapping's own value — and the body says
    // only which NAME the entry takes. Which row publishes that name is decided by the renames the
    // rows carry, and a rename is nowhere in this material: two programs writing the same words in
    // the same order, with the renames of two measuring rows swapped between them, put a different
    // row's reading in the slot and would otherwise hash alike.
    //
    // Already sorted by argument and then by entry, by the resolver that read them out of the
    // mapping, so the order the file happened to write the keys in is not part of the input.
    for (final MeasuredSlot slot in step.measuredSlots) {
      final String entry = 'argument.${slot.argument}.entry.${slot.slot}';
      _field(material, '$entry.measured', slot.measurement.value);
      _field(material, '$entry.measured.from', '${slot.position}:${slot.publisher.value}');
    }
    for (final RegisteredPredicate predicate in step.when) {
      _field(material, 'when', predicate.name.value);
      // What the condition was pointed at, where an installation pointed it. The name alone would
      // make two installations that gate on the same word and read different facts hash alike, and
      // then a clean dry run of one would admit a real run of the other. Sorted, so the order the
      // configuration file happened to write the keys in is not part of the input.
      for (final String value in predicate.bound.names.toList()..sort()) {
        _valued(material, 'when.${predicate.name.value}.$value', predicate.bound.raw(value));
      }
    }
  }

  return sha256.convert(utf8.encode(material.toString())).toString();
}

/// Writes one part of the material so nothing inside it can be read as a boundary.
///
/// The length is in BYTES rather than characters, because that is what is hashed — a character count
/// would let two values of different byte length share a prefix on a multi-byte character.
void _field(StringBuffer material, String name, String value) {
  final int nameBytes = utf8.encode(name).length;
  final int valueBytes = utf8.encode(value).length;
  material.write('$nameBytes:$name$valueBytes:$value');
}

/// Writes [name] against [value], or records that there was none.
///
/// **Absence is a different FIELD, not a reserved value.** An answer nobody gave and an answer given
/// as nothing lead a step to do different things, so the two must not hash alike - and any marker
/// written in the value's place would be a value some run could legitimately hold.
///
/// **A LIST and a MAPPING are written entry by entry, and never as one string.** `['a', 'b']` and
/// `['a, b']` both print as `[a, b]`, and `{'a': 'x', 'b': 'y'}` and `{'a': 'x, b: y'}` both print as
/// `{a: x, b: y}` — so either written through `toString` hashes two different runs alike: a gate
/// demanding two commands and a gate demanding one command whose name contains a comma, a text with
/// two slots filled and a text with one slot whose value contains the separator. The length in front
/// of a field guards the boundary between FIELDS; this is the boundary between ENTRIES, and it needs
/// its own.
void _valued(StringBuffer material, String name, Object? value) {
  if (value == null) {
    _field(material, '$name.absent', '');
    return;
  }
  if (value case final List<Object?> entries) {
    // The count goes in as well. Without it a list holding one empty entry and a list holding none
    // would write the same nothing, and they are different values.
    _field(material, '$name.count', entries.length.toString());
    for (int at = 0; at < entries.length; at += 1) {
      _valued(material, '$name.$at', entries[at]);
    }
    return;
  }
  if (value case final Map<String, Object?> entries) {
    // The list case one level up, and it needs its own boundary for the same reason.
    // `{'a': 'x, b: y'}` and `{'a': 'x', 'b': 'y'}` both print as `{a: x, b: y}`, so a mapping
    // written through toString hashes two different runs alike: a text with two slots filled, and a
    // text with one slot whose value contains the separator.
    //
    // SORTED, unlike a list. A list is ordered on purpose — the words a command is started with —
    // while a mapping is named slots a step reads by name, so a file writing them in another order
    // is the same run.
    _field(material, '$name.count', entries.length.toString());
    for (final String key in entries.keys.toList()..sort()) {
      _valued(material, '$name.$key', entries[key]);
    }
    return;
  }
  _field(material, name, value.toString());
}

List<ArgumentSpec> _sortedByName(List<ArgumentSpec> specs) {
  // Sorted, so that reordering a step's declared arguments in the code does not change the
  // fingerprint of a program nobody touched.
  final List<ArgumentSpec> copy = List<ArgumentSpec>.of(specs)
    ..sort((ArgumentSpec a, ArgumentSpec b) => a.name.compareTo(b.name));
  return copy;
}
