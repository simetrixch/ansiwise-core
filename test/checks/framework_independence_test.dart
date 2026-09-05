import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:ansiwise_checks_tree/ansiwise_checks_tree.dart';

import 'framework_independence.dart';

/// framework-independence — this framework depends on no plugin, directly or through one.
///
/// The vocabulary is already guarded: a check turns the tree red when a platform word appears
/// outside the plugin directories, so the framework cannot MENTION a cluster, a chart tool or a
/// secret store. Nothing guarded the DEPENDENCY. The manifest could name a plugin tomorrow and
/// every check would stay green — the words would be in the plugin, where they are allowed, and the
/// framework would be importing them anyway.
///
/// It matters now because the generic parts of the platform plugin are being carved into units, one
/// per concern, so another vendor can build on them without taking this platform along. The moment
/// the framework reached into one of those, that unit would stop being optional and become part of
/// the core through the back door.
void main() {
  final Directory root = repositoryRoot();

  test('this framework reaches nothing that is not on pub.dev', () {
    expect(
      unhostedReachOf(
        root: 'ansiwise_api',
        manifests: _manifestsIn(root.path)!,
        manifestsOf: (String directory) => _manifestsIn(p.join(root.path, directory)),
      ),
      isEmpty,
      reason:
          'every package of this organisation is publish_to: none, so anything reached by path or '
          'git is one of ours — and the only things of ours below the framework are its plugins',
    );
  });

  test('there is a manifest here to read', () {
    // A check whose input is missing passes over everything. This one reads exactly one file, so
    // that failure mode is one typo away.
    expect(_manifestsIn(root.path)?.pubspec, isNotNull);
  });

  group('counter-probe', () {
    // The check run again over manifests this test writes, carrying the dependency it must report
    // and the innocent neighbours it must leave alone.

    test('a plugin named directly is reported', () {
      final List<UnhostedEdge> found = _reach(<String, String>{
        '': _manifest('ansiwise_api', <String, String>{
          'yaml': '^3.1.3',
          'planted_plugin': '\n    path: ../planted-plugins/planted-plugin',
        }),
      });

      expect(found.single.package, 'planted_plugin');
      expect(found.single.kind, 'path');
    });

    test('a loop closed over TWO hops is reported, with the chain', () {
      // Transitive is the case this exists for. Naming the far package alone would not say which of
      // the framework's OWN dependencies to take back out.
      final List<UnhostedEdge> found = _reach(<String, String>{
        '': _manifest('ansiwise_api', <String, String>{
          'planted_unit': '\n    path: ../planted-unit',
        }),
        '../planted-unit': _manifest('planted_unit', <String, String>{
          'planted_plugin': '\n    path: ../planted-plugin',
        }),
        '../planted-plugin': _manifest('planted_plugin', <String, String>{
          'ansiwise_api': '\n    path: ../ansiwise-api',
        }),
      });

      expect(found.single.package, 'ansiwise_api');
      expect(found.single.chain, <String>[
        'ansiwise_api',
        'planted_unit',
        'planted_plugin',
        'ansiwise_api',
      ]);
      expect(
        found.single.toString(),
        contains('ansiwise_api -> planted_unit -> planted_plugin -> ansiwise_api'),
        reason: 'the finding has to say what to take out, not only that a loop exists',
      );
    });

    test('THE INNOCENT NEIGHBOUR: a package of ours that leads nowhere is not reported', () {
      // Without this, a check that refused every package of ours would pass every probe above and
      // be exactly as wrong as the one it replaced. This is the case that made the rule change:
      // something of ours, reached by the framework, that cannot be a plugin because it depends on
      // nothing at all.
      expect(
        _reach(<String, String>{
          '': _manifest('ansiwise_api', <String, String>{
            'planted_leaf': '\n    path: ../planted-leaf',
          }),
          '../planted-leaf': _manifest('planted_leaf', <String, String>{}),
        }),
        isEmpty,
      );
    });

    test('a git dependency is reported even though it cannot be followed', () {
      // Its own manifest is not on this disk, so the walk stops — but the EDGE is the finding, and
      // an unreadable target does not make it allowed.
      final List<UnhostedEdge> found = _reach(<String, String>{
        '': _manifest('ansiwise_api', <String, String>{
          // The host is invented. What the walk stops on is that the edge is declared as a
          // repository at all, so an address anybody could resolve would add nothing and would
          // name one forge in a framework that knows none.
          'planted_plugin':
              '\n    git:\n      url: https://forge.example.invalid/planted-plugins.git',
        }),
      });

      expect(found.single.package, 'planted_plugin');
      expect(found.single.kind, 'git');
    });

    test('THE ONE UNFOLLOWABLE EDGE THAT IS HELD ELSEWHERE is passed over, and only that one', () {
      // The audits this gate runs are a git dependency of this manifest, so the walk cannot open
      // them and would report the unknown — correctly, if nobody were measuring. Somebody is: the
      // hosted-only check in that package, over its own manifest, where it IS readable. This entry
      // is the pointer between the two halves, and it is a NAME rather than a rule so that a second
      // unfollowable edge is still reported.
      final List<UnhostedEdge> found = _reach(<String, String>{
        '': _manifest('ansiwise_api', <String, String>{
          'ansiwise_checks_tree':
              '\n    git:\n      url: https://forge.example.invalid/checks.git\n      path: tree',
          'another_unreadable': '\n    git:\n      url: https://forge.example.invalid/another.git',
        }),
      });

      expect(
        found.map((UnhostedEdge each) => each.package),
        <String>['another_unreadable'],
        reason:
            'the held edge is passed over and every other one is still reported — an exception that '
            'widened the rule would have hidden both',
      );
    });

    test('every held edge carries its reason and names where it is held', () {
      // A bare name in a list is a claim with nothing behind it. What makes this pair work is that
      // a reader arriving here is told which check, in which package, over which file. The names
      // are listed as well as looped over, because WHICH edges are excused is the thing a reviewer
      // has to see change.
      expect(heldElsewhere.keys, <String>['ansiwise_checks_gate', 'ansiwise_checks_tree']);
      for (final MapEntry<String, String> held in heldElsewhere.entries) {
        expect(
          held.value,
          allOf(contains('hosted-only'), contains('ansiwise-checks'), contains('DEV dependency')),
          reason:
              'the reason for ${held.key} has to say what holds it and where, or the other half '
              'cannot be found',
        );
      }
    });

    test('a dev dependency counts, because it is the same coupling in a different hat', () {
      final List<UnhostedEdge> found = _reach(<String, String>{
        '':
            'name: ansiwise_api\n'
            'dependencies:\n'
            '  yaml: ^3.1.3\n'
            'dev_dependencies:\n'
            '  test: ^1.31.2\n'
            '  planted_plugin:\n'
            '    path: ../planted-plugin\n',
      });

      expect(found.single.package, 'planted_plugin');
    });

    test('an override is reported, which is the quiet door', () {
      // `dependency_overrides:` redirects a name that reads as an ordinary hosted dependency to
      // something on disk. A check reading only `dependencies:` would call this tree clean.
      final List<UnhostedEdge> found = _reach(<String, String>{
        '':
            'name: ansiwise_api\n'
            'dependencies:\n'
            '  planted_plugin: ^0.1.0\n'
            'dependency_overrides:\n'
            '  planted_plugin:\n'
            '    path: ../planted-plugin\n',
      });

      expect(found.single.package, 'planted_plugin');
      expect(found.single.kind, 'path');
    });

    test('a sibling overrides file is reported too', () {
      // The same door, in the file that is conventionally left out of version control — which is
      // exactly why a check has to look at it rather than trust that it is not there.
      final List<UnhostedEdge> found = unhostedReachOf(
        root: 'ansiwise_api',
        manifests: (
          pubspec: 'name: ansiwise_api\ndependencies:\n  planted_plugin: ^0.1.0\n',
          overrides: 'dependency_overrides:\n  planted_plugin:\n    path: ../planted-plugin\n',
        ),
        manifestsOf: (String path) => null,
      );

      expect(found.single.package, 'planted_plugin');
    });

    test('an ordinary hosted tree is left alone', () {
      // Without this the check would pass its own repository for reporting everything, and the four
      // probes above would be satisfied by a function that always finds something.
      expect(
        _reach(<String, String>{
          '': _manifest('ansiwise_api', <String, String>{
            'yaml': '^3.1.3',
            'meta': '^1.19.0',
            'crypto': '^3.0.7',
          }),
        }),
        isEmpty,
      );
    });

    test('a package with nothing under its name is hosted, not a finding', () {
      // `foo:` alone is pub.dev at any version, and reading it as anything else would turn a
      // perfectly ordinary manifest red.
      expect(_reach(<String, String>{'': 'name: ansiwise_api\ndependencies:\n  yaml:\n'}), isEmpty);
    });

    test('a section this check cannot read is refused, not called clean', () {
      // The failure mode that hides every other one. `yaml:^3.1.3` with no space after the colon is
      // one word, so the whole section parses as a scalar — and a check that shrugged there would
      // report a manifest full of plugins as having no dependencies at all. It found exactly this
      // in its own counter-probes, which is how it comes to be guarded.
      expect(
        () => _reach(<String, String>{
          '': 'name: ansiwise_api\ndependencies:\n  yaml:^3.1.3\n  planted_plugin:^0.1.0\n',
        }),
        throwsA(
          isA<FormatException>().having(
            (FormatException refused) => refused.message,
            'message',
            contains('"dependencies" is not a mapping'),
          ),
        ),
      );
    });

    test('a section that is simply absent is not a refusal', () {
      // A package with no dev dependencies writes no `dev_dependencies:`, and that is an answer
      // rather than something unreadable.
      expect(_reach(<String, String>{'': 'name: ansiwise_api\n'}), isEmpty);
    });

    test('a package inside this repository is not a finding', () {
      // The gate's own audits are such a package: they walk files, so they need dart:io, which the
      // shipped library may not have outside infrastructure/. A sibling in the same checkout cannot
      // make a unit non-optional for anybody and reaches nothing that depends on the framework, so
      // forbidding that edge
      // would protect nothing.
      expect(
        _reach(<String, String>{
          '': _manifest('ansiwise_api', <String, String>{'yaml': '^3.1.3'}, dev: _gatePackage),
          'checks': _manifest('ansiwise_checks', <String, String>{'yaml': '^3.1.3'}),
        }),
        isEmpty,
      );
    });

    test('but it is WALKED, so what it reaches is still reported', () {
      // The failure this closes: a plugin one hop further out, behind a package that is allowed.
      // Without walking, moving the edge into the gate package would make it invisible.
      final List<UnhostedEdge> found = _reach(<String, String>{
        '': _manifest('ansiwise_api', <String, String>{}, dev: _gatePackage),
        'checks': _manifest('ansiwise_checks', <String, String>{
          'planted_plugin': '\n    path: ../../planted-plugins/planted-plugin',
        }),
      });

      expect(found.single.package, 'planted_plugin');
      expect(found.single.chain, <String>['ansiwise_api', 'ansiwise_checks', 'planted_plugin']);
    });

    test('a path is resolved against the package that declared it, not against the root', () {
      // `path: ..` written one directory down means the repository root. Resolved against the root
      // instead it would mean the parent of the repository, and the walk would follow the wrong
      // tree — so this asserts WHERE it arrived, by the chain it reports.
      final List<UnhostedEdge> found = _reach(<String, String>{
        '': _manifest('ansiwise_api', <String, String>{}, dev: _gatePackage),
        'checks': _manifest('ansiwise_checks', <String, String>{'ansiwise_api': '\n    path: ..'}),
      });

      expect(found.single.chain, <String>['ansiwise_api', 'ansiwise_checks', 'ansiwise_api']);
    });

    test('two path packages depending on each other terminate', () {
      // A cycle between units is a mistake somebody will make, and a check that hung on it would be
      // a check nobody could run. Neither of the two leads back to the framework, so there is
      // nothing to report — what is asserted here is that the walk ENDS at all.
      expect(
        _reach(<String, String>{
          '': _manifest('ansiwise_api', <String, String>{'one': '\n    path: ../one'}),
          '../one': _manifest('one', <String, String>{'two': '\n    path: ../two'}),
          '../two': _manifest('two', <String, String>{'one': '\n    path: ../one'}),
        }),
        isEmpty,
      );
    });
  });
}

/// Runs the check over manifests given by the DIRECTORY each package sits at, relative to the
/// repository root, which is the empty string.
List<UnhostedEdge> _reach(Map<String, String> pubspecs) => unhostedReachOf(
  root: 'ansiwise_api',
  manifests: (pubspec: pubspecs['']!, overrides: null),
  manifestsOf: (String directory) {
    final String? found = pubspecs[directory];
    return found == null ? null : (pubspec: found, overrides: null);
  },
);

/// One manifest, with each dependency written as it would be in a real file.
String _manifest(
  String name,
  Map<String, String> dependencies, {
  Map<String, String> dev = const <String, String>{},
}) =>
    'name: $name\n'
    'publish_to: none\n'
    'dependencies:\n'
    '${dependencies.entries.map(_dependencyLine).join()}'
    '${dev.isEmpty ? '' : 'dev_dependencies:\n${dev.entries.map(_dependencyLine).join()}'}';

/// The gate's own package, as this repository declares it: a dev dependency on a sibling directory.
const Map<String, String> _gatePackage = <String, String>{'ansiwise_checks': '\n    path: checks'};

/// One dependency as it stands under `dependencies:`.
///
/// A value starting with a newline is a block under the name — `path:` or `git:`. Anything else is
/// a version constraint on the same line, and it needs the space YAML requires after the colon:
/// `yaml:^3.1.3` with no space is one word, which turns the whole section into a scalar and makes
/// this check find nothing in a manifest it was supposed to be reading.
String _dependencyLine(MapEntry<String, String> each) => each.value.startsWith('\n')
    ? '  ${each.key}:${each.value}\n'
    : '  ${each.key}: ${each.value}\n';

/// What is on disk at [directory], or null where there is no manifest there.
Manifests? _manifestsIn(String directory) {
  final File pubspec = File(p.join(directory, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return null;
  }
  final File overrides = File(p.join(directory, 'pubspec_overrides.yaml'));
  return (
    pubspec: pubspec.readAsStringSync(),
    overrides: overrides.existsSync() ? overrides.readAsStringSync() : null,
  );
}
