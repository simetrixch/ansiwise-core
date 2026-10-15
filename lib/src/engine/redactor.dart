/// Removes secret values from everything on its way into the record.
///
/// The record is written to a file an operator reads without elevated rights, and it is exported
/// and pasted into messages when something has gone wrong. That is only safe if a secret cannot be
/// in it, and the only way to be sure of that is to have one place it must pass through.
///
/// This is that place. Every port reports through the recorder, and the recorder redacts. No step
/// can write to the record another way, so no step can forget.
///
/// **One instance belongs to one run, and it grows during that run.** The recording shell, the http
/// port, the logger and the file the record is written to all hold the same object, which is what
/// makes [register] worth anything: a credential minted in the middle of a run is hidden on every
/// one of those surfaces from the moment it is registered.
final class Redactor {
  /// Creates a redactor that hides [secrets].
  Redactor(Iterable<String> secrets)
    : _secrets = secrets.where((String s) => s.isNotEmpty).toList()
        ..sort((String a, String b) => b.length.compareTo(a.length));

  /// A redactor that hides nothing and cannot be made to hide anything.
  ///
  /// For a context that is not a run: something which has to be handed a redactor and will never
  /// register a value with it. [register] on this one throws.
  ///
  /// **A RUN NEVER USES THIS, and the throw is how a caller finds out.** What a redactor hides is
  /// not fixed when it is built, so a run's redactor is one object that every surface of that run
  /// holds. Handed out as a fresh instance per caller, this name would give two surfaces of one run
  /// two separate redactors, and a credential registered through one would go on being written in
  /// the clear by the other with nothing saying so. Handed out as one shared MUTABLE object, it
  /// would carry a value registered by one run into the records of every later run in the same
  /// process. It is neither: nothing can be registered with it, so it is the same object for
  /// everybody and there is nothing in it to leak. A run builds its own with
  /// `Redactor(const <String>[])`, which hides nothing yet and can still grow.
  static final Redactor none = _HidesNothing();

  /// What replaces a secret. Fixed text rather than a variable number of stars, so that the length
  /// of the value is not readable from the record either.
  static const String marker = '[redacted]';

  /// Longest first, so that a secret containing another secret is replaced whole rather than being
  /// broken into a marker and a leftover fragment.
  final List<String> _secrets;

  /// Whether anything is being hidden.
  bool get isEmpty => _secrets.isEmpty;

  /// Hides [value] from here on.
  ///
  /// For the credential that does not exist before the run starts: one a step mints or reads while
  /// the run happens. Nothing can be taken out of a line that is already written, so this is called
  /// where the value is PUBLISHED and not where it is used — the run's own measurement sink, which
  /// is the first moment the framework knows the value exists. Whatever the step wrote before that
  /// stands.
  ///
  /// Kept in the same longest-first order the constructor builds, so a value registered now and a
  /// value given at the start are replaced by the same rule.
  ///
  /// Empty values are ignored, exactly as ones handed to the constructor are.
  ///
  /// [Redactor.none] refuses instead: it belongs to no run, so nothing it was told to hide would be
  /// hidden on any surface.
  void register(String value) {
    if (value.isEmpty || _secrets.contains(value)) {
      return;
    }
    final int shorter = _secrets.indexWhere((String each) => each.length < value.length);
    _secrets.insert(shorter < 0 ? _secrets.length : shorter, value);
  }

  /// Returns [text] with every known secret replaced by [marker].
  ///
  /// Replaces the value wherever it appears rather than dropping the line that carries it. A
  /// dropped line takes its context with it, and the context is what an operator needs when a
  /// command failed while handling a credential.
  String hide(String text) {
    if (_secrets.isEmpty || text.isEmpty) {
      return text;
    }
    String result = text;
    for (final String secret in _secrets) {
      if (result.contains(secret)) {
        result = result.replaceAll(secret, marker);
      }
    }
    return result;
  }

  /// Returns [values] with every known secret replaced by [marker].
  List<String> hideAll(Iterable<String> values) => values.map(hide).toList(growable: false);

  /// Returns [headers] with every value redacted whose name names a credential.
  ///
  /// Names and not values, because a credential that arrives in a header is often assembled at the
  /// call site and was never registered as a secret. The rule is deliberately blunt: anything
  /// called authorization, cookie, or ending in key, secret or password.
  Map<String, String> hideHeaders(Map<String, String> headers) => <String, String>{
    for (final MapEntry<String, String> e in headers.entries)
      e.key: _isCredentialHeader(e.key) ? marker : hide(e.value),
  };

  static bool _isCredentialHeader(String name) {
    final String n = name.toLowerCase();
    return n == 'authorization' ||
        n == 'cookie' ||
        n == 'set-cookie' ||
        n == 'proxy-authorization' ||
        n.endsWith('-key') ||
        n.endsWith('-secret') ||
        n.endsWith('-password') ||
        n.endsWith('-credential');
  }
}

/// What [Redactor.none] is.
final class _HidesNothing extends Redactor {
  _HidesNothing() : super(const <String>[]);

  @override
  void register(String value) {
    // The value is not in the message. Whatever went wrong, this is a credential, and a refusal
    // that named it would put in the record exactly what the caller was trying to keep out of it.
    throw StateError(
      'this redactor belongs to no run, so a value registered with it would be hidden nowhere. A '
      'run holds ONE redactor and every one of its surfaces holds that same object; build it with '
      'Redactor(const <String>[]) where there is nothing to hide yet',
    );
  }
}
