/// Which packages a framework reaches that are not on pub.dev, and what reached them.
///
/// The direction is the whole design and only one way is forbidden. A plugin depending on the
/// framework is what a plugin IS. A plugin depending on another plugin is what makes units units.
/// The framework depending on anything below it is the one arrow that must not exist — the moment
/// it did, that unit would stop being optional and everybody using the framework would drag it
/// along whether they wanted it or not.
///
/// **WHY WALKING THE UNHOSTED EDGES IS THE WHOLE GRAPH**, and this is what makes a check of a few
/// hundred lines complete rather than approximate: every package of this organisation declares
/// `publish_to: none`. An unpublished package cannot be reached from a published one, because pub
/// refuses to publish a package that depends on one — so at every hop, the only way to reach one of
/// ours is `path:` or `git:`. A dependency resolved from pub.dev therefore cannot lead anywhere
/// this check needs to look, and stopping there loses nothing.
///
/// **WHAT IS MEASURED IS THE CIRCLE, because the circle is the danger.** A plugin is a package
/// that builds on the framework — it depends on `ansiwise_api`. So the framework depending on a
/// plugin closes a loop, and from that moment the plugin is not optional: whoever wants the
/// framework drags it along.
///
/// **IT IS NOT MEASURED BY ORIGIN.** Requiring every package reached from outside this repository
/// to be hosted on pub.dev rests on the reasoning that the only things of ours below the framework
/// are its plugins, and that does not hold: an audit library of ours stands beside the framework
/// with an empty dependency list. Such a package cannot be a plugin and cannot close a loop, and
/// refusing it teaches nobody anything.
///
/// So the question asked here is the one the rule's own title asks: **does this package lead back
/// to the framework?** For every plugin the answer is the same under either measure.
///
/// **A PACKAGE THAT CANNOT BE READ IS REPORTED, not passed over.** An edge this check cannot follow
/// is an edge whose answer is unknown, and answering "no loop" about something nobody looked at is
/// the one thing a gate must never do.
///
/// **A package inside this repository is not below the framework — it IS the framework's
/// repository.** The gate's own audits are such a package: they walk files, so they need `dart:io`,
/// which the shipped library may not have outside `infrastructure/`, so they cannot live in it. A
/// rule that forbade that edge would not be protecting anything — a sibling in the same checkout
/// cannot make a unit non-optional for anybody, and it reaches nothing that depends on the
/// framework. What it must still
/// do is be WALKED: a repository-local package that reaches a plugin is the same failure one hop
/// further out, and it is reported with the chain that got there.
library;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A package's two manifests, as far as this check reads them.
///
/// The overrides file is here because it is the quiet door. `dependency_overrides:` and a sibling
/// `pubspec_overrides.yaml` both redirect a name that reads as an ordinary hosted dependency to
/// something on disk, and a check that read only `dependencies:` would call such a tree clean.
typedef Manifests = ({String? pubspec, String? overrides});

/// One dependency edge that closes a loop back to the framework, or that could not be read.
final class UnhostedEdge {
  /// Records that [package] was declared as a [kind] dependency, reached along [chain].
  ///
  /// [why] says which of the two it is: a package that leads back to the framework, or one whose
  /// own manifests could not be read from here so that nobody knows whether it does.
  const UnhostedEdge({
    required this.package,
    required this.kind,
    required this.chain,
    this.why = 'leads back to the framework',
  });

  /// Why this edge is a finding.
  final String why;

  /// The name of the package depended on.
  final String package;

  /// How it was declared: `path`, `git`, or the section of a manifest that redirected it.
  final String kind;

  /// Every package from the framework to this one, in order.
  final List<String> chain;

  /// The finding, as the gate prints it.
  ///
  /// It names the dependency AND the chain that reached it, because on a transitive one those are
  /// different answers: knowing that `planted_plugin` is in the tree does not say which of the
  /// framework's own dependencies to take back out.
  @override
  String toString() => '$package — a $kind dependency that $why, reached by ${chain.join(' -> ')}';
}

/// Every package [root] reaches from outside this repository that is not hosted on pub.dev, with
/// the chain that reached each.
///
/// [manifestsOf] answers with the two manifests of the package at a directory given relative to the
/// repository root, or null where they cannot be read. A path whose manifests cannot be read still
/// produces its own finding where it points outside — the edge is what is being reported, and an
/// unreadable target does not make the edge allowed.
///
/// A declared path is resolved against the directory of the package that DECLARED it, which is what
/// pub does: `path: ..` written in `checks/pubspec.yaml` means the repository root and not the
/// parent of wherever the walk started.
///
/// Walking stops at a hosted dependency and at a directory already visited, so a cycle between two
/// path packages terminates.
List<UnhostedEdge> unhostedReachOf({
  required String root,
  required Manifests manifests,
  required Manifests? Function(String directory) manifestsOf,
}) {
  final List<UnhostedEdge> found = <UnhostedEdge>[];
  final Set<String> visited = <String>{''};

  void walk(Manifests here, String directory, List<String> chain) {
    for (final _Declared declared in _dependenciesIn(here)) {
      final List<String> reached = <String>[...chain, declared.name];
      if (declared.kind == _hosted || declared.kind == _sdk) {
        // Hosted goes no further for the reason in this library's own doc, and the SDK is not ours
        // — neither can lead to an unpublished package of this organisation.
        continue;
      }
      if (declared.name == root) {
        // The loop, closed. Whatever chain got here, this is the arrow that must not exist.
        found.add(UnhostedEdge(package: declared.name, kind: declared.kind, chain: reached));
        continue;
      }
      final String? declaredPath = declared.path;
      final String? at = declaredPath == null
          ? null
          : p.url.normalize(p.url.join(directory, declaredPath));
      final Manifests? beyond = at == null ? null : manifestsOf(at);
      if (beyond == null) {
        if (heldElsewhere.containsKey(declared.name)) {
          // Not followable from here, and answered where it CAN be read. See [heldElsewhere].
          continue;
        }
        // Not followable from here — a git dependency, or a path with nothing readable at it. What
        // it leads to is UNKNOWN, and unknown is reported rather than assumed clean.
        found.add(
          UnhostedEdge(
            package: declared.name,
            kind: declared.kind,
            chain: reached,
            why: 'cannot be read from here, so whether it leads back is unknown',
          ),
        );
        continue;
      }
      if (!visited.add(at!)) {
        continue;
      }
      walk(beyond, at, reached);
    }
  }

  walk(manifests, '', <String>[root]);
  return found;
}

const String _hosted = 'hosted';
const String _sdk = 'sdk';

/// One dependency as a manifest declares it.
final class _Declared {
  const _Declared({required this.name, required this.kind, this.path});

  final String name;
  final String kind;

  /// Where its own manifests are, relative to the package that declared it, or null when this edge
  /// leads somewhere that cannot be read from here.
  final String? path;
}

/// Every dependency the two manifests declare, overrides last so they win.
///
/// All three sections of the pubspec are read. A dev dependency on a plugin is the same coupling
/// wearing a different hat: the framework's own tests would then be running against a tree with the
/// platform in it, and the example a plugin author copies would be one that never proved the
/// framework stands alone.
List<_Declared> _dependenciesIn(Manifests manifests) {
  final Map<String, _Declared> byName = <String, _Declared>{};
  for (final (String? text, List<String> sections) in <(String?, List<String>)>[
    (manifests.pubspec, <String>['dependencies', 'dev_dependencies', 'dependency_overrides']),
    (manifests.overrides, <String>['dependency_overrides']),
  ]) {
    if (text == null) {
      continue;
    }
    final Object? document = loadYaml(text);
    if (document is! YamlMap) {
      throw const FormatException(
        'a manifest that is not a mapping cannot be read for dependencies',
      );
    }
    for (final String section in sections) {
      final Object? entries = document[section];
      if (entries == null) {
        continue;
      }
      if (entries is! YamlMap) {
        // Refused rather than read past. A section this check cannot read holds no dependencies as
        // far as it can tell, and answering "clean" there is the check claiming to have looked at
        // something it did not — which is the one thing a gate must never do.
        throw FormatException('"$section" is not a mapping, so its dependencies cannot be read');
      }
      for (final MapEntry<Object?, Object?> entry in entries.entries) {
        final Object? name = entry.key;
        if (name is! String) {
          continue;
        }
        byName[name] = _declaredAs(name, entry.value);
      }
    }
  }
  return byName.values.toList(growable: false);
}

/// What one entry of a dependency section declares.
///
/// A bare version constraint, and a name with nothing under it at all, are both pub.dev. Anything
/// else says where it really comes from, and `path` is the only one this check can follow.
_Declared _declaredAs(String name, Object? value) {
  if (value is! YamlMap) {
    return _Declared(name: name, kind: _hosted);
  }
  final Object? path = value['path'];
  if (path is String) {
    return _Declared(name: name, kind: 'path', path: path);
  }
  if (value.containsKey('git')) {
    return _Declared(name: name, kind: 'git');
  }
  if (value.containsKey('sdk')) {
    return _Declared(name: name, kind: _sdk);
  }
  return _Declared(name: name, kind: _hosted);
}

/// The unfollowable dependencies whose answer is given where their manifest CAN be read, and where.
///
/// **WHY AN ALLOWLIST AND NOT A LOOSER RULE.** A git dependency cannot be followed from here: the
/// package is not on this disk in a fresh clone, and this check will not guess. Reporting the
/// unknown is the correct default and it stays the default. But one of ours is reached on purpose,
/// and the honest answer is not to widen the rule until it fits — it is to say WHICH one, and where
/// somebody can go and see that the promise is kept.
///
/// **THE TWO HALVES ONLY WORK TOGETHER.** The entry below asserts nothing by itself; what holds it
/// is a check in the other package, over the other package's own manifest, which is readable from
/// there. Each names the other. Delete either and the pair is a claim with nothing behind it, which
/// is why the reason is written out rather than left as a bare name in a list.
///
/// **WHAT THIS DOES NOT MAKE SAFE.** It does not say the entry cannot lead back — it says somebody
/// else is measuring whether it does. A reader who wants the guarantee itself goes to the named
/// check and reads it, exactly as they would follow a path dependency from here.
const Map<String, String> heldElsewhere = <String, String>{
  'ansiwise_checks_gate':
      'the gate this repository runs, in ansiwise-checks beside the entry below and named at the '
      'same commit. A DEV dependency, so nothing compiled reaches it, and it reaches nothing '
      'itself: package:test and package:lints from pub.dev, and ansiwise-checks/tree for its own '
      'suite \u2014 which pub never resolves from here, because a dev dependency of a package that is '
      'not the root is not resolved at all. Whether that half leads back is held by the '
      'hosted-only check named below. WHAT NOTHING HOLDS is this half\'s own manifest: hosted-only '
      'cannot be declared by a package that reaches ansiwise-checks/tree, because the audit lives '
      'in it. So this entry names a gap as well as a holding, and says which is which',
  'ansiwise_checks_tree':
      'a DEV dependency, so nothing compiled reaches it. Whether it leads back is held by the '
      'hosted-only check in ansiwise-checks/tree, over that package\'s own manifest: every '
      'dependency it names has to be served by pub.dev, and a git, path or hosted block in any of '
      'its three dependency sections turns that tree red. It is measured there because from here it '
      'is a git dependency nothing can open',
};
