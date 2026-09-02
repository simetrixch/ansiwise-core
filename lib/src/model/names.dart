/// The identifiers this framework passes around.
///
/// Each is an extension type over [String]: a distinct static type at zero runtime cost. A function
/// taking a step name and a program name cannot be called with the two the wrong way round, which
/// two bare strings would have allowed.
library;

/// The registered name of a step, as a program file writes it and as the record reports it.
extension type const StepName(String value) implements Object {
  /// Whether [value] is a name the registry will accept: lower case, digits and underscores.
  ///
  /// The same shape as a Dart identifier, so a step's registered name and its class name stay
  /// mechanically related and a reader can find one from the other.
  static bool isValid(String value) => _identifier.hasMatch(value);
}

/// The registered name of a predicate — one named condition a program may put behind `when:`.
extension type const PredicateName(String value) implements Object {
  /// Whether [value] is a name the registry will accept.
  static bool isValid(String value) => _identifier.hasMatch(value);
}

/// The name a measured value is published under, and the name a later row takes it by.
///
/// Dots as well as underscores, and the dots are what they are for: a measurement crosses from the
/// step that took it to a row that names another package's step, so the name carries where it came
/// from — `host.upstream_resolvers` rather than `resolvers`. Two plugins each measuring "the
/// backend" would otherwise publish one name, and the program could not say which of them it meant.
extension type const MeasurementName(String value) implements Object {
  /// Whether [value] is a name the registry and a program file will accept.
  ///
  /// Identifiers joined by dots. A leading, trailing or doubled dot is refused: the name is what a
  /// refusal and a plan print back to the operator, and `host..resolvers` reads as a typo nobody
  /// can act on.
  static bool isValid(String value) => _measurementName.hasMatch(value);
}

/// The name of a program, which is also the sub-command that runs it.
extension type const ProgramName(String value) implements Object {
  /// Whether [value] is a name the loader will accept: lower case, digits and dashes.
  ///
  /// Dashes rather than underscores, because a program name is typed on a command line —
  /// `deploy-cluster`, not `deploy_cluster`.
  static bool isValid(String value) => _programName.hasMatch(value);
}

/// The identifier of one run, unique on the machine that produced it.
extension type const RunId(String value) implements Object {}

/// The name of one machine role a program may apply to.
///
/// A machine that does several jobs at once carries a role that names them ALL, joined by `+` —
/// one machine that is both master and slave writes `master+slave`. The union is one value
/// everywhere a role travels (the header, the record, a refusal); [parts] is how a reader that
/// decides per part takes it apart, and a role with no `+` in it is its own single part.
extension type const Role(String value) implements Object {
  /// The parts this role carries, in the order the value writes them.
  List<Role> get parts => <Role>[for (final String part in value.split('+')) Role(part)];
}

/// A deployment stage.
extension type const Stage(String value) implements Object {}

/// A fully qualified domain name.
///
/// Its own type because an installation carries several strings that look alike — a machine's own
/// name, the name a service is reached under, the apex those sit below — and swapping two of them
/// produces a working deployment pointed at the wrong place.
extension type const Fqdn(String value) implements Object {}

final RegExp _identifier = RegExp(r'^[a-z][a-z0-9_]*$');
final RegExp _programName = RegExp(r'^[a-z][a-z0-9-]*$');
final RegExp _measurementName = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');
