import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../domain/files.dart';
import '../domain/run_retention.dart';
import '../model/failures.dart';
import '../model/names.dart';
import '../model/run_event.dart';
import 'condition_binding.dart';
import 'elevation_source.dart';

/// What the installation's own configuration says, read from one file beside the programs.
///
/// **Handing the binary this file is enough.** Everything a run needs that is not a program, an
/// answer or a command-line decision stands here, so an operator points at one path and is done.
/// The same file is what the REST surface reads, because a service that had to be told separately
/// is a second place to keep in step.
///
/// The file is data and nothing else — names and values, no conditions, no expressions, no
/// templating. The moment a configuration file can compute, the thing being debugged stops being the
/// program and starts being the configuration language.
///
/// ```yaml
/// # ansiwise.yaml
/// log_level: info
/// gate:
///   dry: false
/// runs:
///   keep: 500
/// plugins:
///   - example-plugin
/// conditions:
///   subject_enabled:
///     predicate: key_is_true
///     file: settings/one
///     key: SUBJECT_ENABLED
/// elevation:
///   password_file: /home/operator/.elevation
/// ```
@immutable
final class Configuration {
  /// Creates the configuration from what the file says.
  const Configuration({
    required this.plugins,
    this.logLevel = LogLevel.info,
    this.requireDryRun = true,
    this.allowUnwind = true,
    this.retention = const RunRetention(),
    this.conditions = const <String, ConditionBinding>{},
    this.elevation,
  });

  /// The name the file is looked for under, beside the programs.
  static const String defaultFileName = 'ansiwise.yaml';

  /// The plugins this installation turns on, in the order the file lists them.
  final List<String> plugins;

  /// The quietest level this installation writes.
  ///
  /// `info` unless the file says otherwise, which is the level an operator reads. A run somebody is
  /// debugging asks for `debug` and gets what it needs by having asked; nothing is dropped from the
  /// record because a step decided months ago that it was not worth saying.
  final LogLevel logLevel;

  /// Whether a real run still needs a clean dry run of the same input behind it.
  ///
  /// True unless `gate: dry: false` says otherwise, so an installation that never thought about it
  /// has the gate. Turning it off does not make a run claim more: it is recorded as having waived
  /// the proof, and the closing line still counts its rows apart from the measured ones.
  ///
  /// **The installation this platform was built for runs with the gate on.** Somebody else running
  /// it may decide differently; the run that is supposed to demonstrate the chain works waives
  /// nothing.
  final bool requireDryRun;

  /// How many run records this machine keeps.
  ///
  /// [RunRetention.defaultKeep] unless `runs: keep:` says otherwise, so an installation that never
  /// thought about it is still bounded. Without a bound the number a machine holds is the number of
  /// invocations it has ever had, which a program on a timer turns into a disk that fills.
  ///
  /// **Stated once here and obeyed by every program.** A program file cannot name it, and no step
  /// knows there is a bound: the engine applies it where a record is opened.
  final RunRetention retention;

  /// Whether the engine should roll back steps when a failure happens.
  ///
  /// True unless `no_unwind: true` is given, in which case the framework stops on failure
  /// leaving the machine exactly as it was, preserving evidence for debugging.
  final bool allowUnwind;

  /// The conditions this installation names, from the name a program row writes to what it is.
  ///
  /// **This is the surface a generic condition is pointed at, and there is no other.** A plugin
  /// brings the condition — "the key is true in that file" — and knows nothing about which file or
  /// which key, because a package that named ours would be useless to anybody else with the same
  /// tool. A program row cannot say it either: `when:` is a list of bare names, and a structure
  /// there would be the start of a configuration language. So it is said here, once per
  /// installation, as named slots each holding exactly one value.
  final Map<String, ConditionBinding> conditions;

  /// Where the password that raises a command to root comes from, or null where none is named.
  ///
  /// **No default, here or anywhere below.** A route baked into the framework is right on the
  /// machine it was written for and silently wrong on every other, and wrong here does not
  /// announce itself: the elevation fails, the command underneath it fails, and the record shows
  /// the command's own failure. An installation whose steps never need root names nothing and is
  /// completely configured.
  final ElevationSource? elevation;

  /// Reads [path] through [files].
  ///
  /// Throws [PluginRejected] when the file is not a mapping, when `plugins:` is absent or is not a
  /// list, when an entry is not a plain string, or when `log_level:` is not one of the four. Every
  /// one of those is named rather than coerced: a configuration that is quietly interpreted is a
  /// configuration nobody can predict.
  static Future<Configuration> load({required Files files, required String path}) async {
    final String text = await files.read(path);

    final Object? document;
    try {
      document = loadYaml(text);
    } on YamlException catch (broken) {
      throw PluginRejected('$path is not YAML: ${broken.message}');
    }

    if (document is! YamlMap) {
      throw PluginRejected('$path has to be a mapping with a "plugins:" list');
    }

    final Object? named = document['plugins'];
    if (named == null) {
      throw PluginRejected(
        '$path names no plugins\n'
        'add a "plugins:" list, or no step exists and every program is refused',
      );
    }
    if (named is! YamlList) {
      throw PluginRejected('$path: "plugins" has to be a list of names');
    }

    final List<String> names = <String>[];
    for (final Object? entry in named) {
      if (entry is! String) {
        throw PluginRejected('$path: "$entry" is not a plugin name');
      }
      names.add(entry);
    }

    return Configuration(
      plugins: names,
      logLevel: _logLevel(document, path),
      requireDryRun: _requireDryRun(document, path),
      allowUnwind: _allowUnwind(document, path),
      retention: _retention(document, path),
      conditions: _conditions(document, path),
      elevation: _elevation(document, path),
    );
  }

  /// Where [document] says the elevation password comes from, or null where it names none.
  ///
  /// A block that is there and says nothing usable is refused rather than read past: somebody who
  /// wrote `elevation:` meant to configure elevation, and a key silently ignored leaves them
  /// believing they did.
  ///
  /// **Exactly one route, never two.** Naming both a file and the caller is two answers to one
  /// question, and whichever this picked would be the one somebody did not mean.
  static ElevationSource? _elevation(YamlMap document, String path) {
    final Object? elevation = document['elevation'];
    if (elevation == null) {
      return null;
    }
    if (elevation is! YamlMap) {
      throw PluginRejected(
        '$path: "elevation" has to be a mapping, with either "password_file:" or '
        '"password_from_caller: true" under it',
      );
    }
    final Object? file = elevation['password_file'];
    final Object? fromCaller = elevation['password_from_caller'];

    if (fromCaller != null && fromCaller is! bool) {
      throw PluginRejected(
        '$path: "elevation" says "password_from_caller: $fromCaller", and it is true or false',
      );
    }
    if (fromCaller == true && file != null) {
      throw PluginRejected(
        '$path: "elevation" names both "password_file:" and "password_from_caller: true", and a '
        'run takes the password from one place\n'
        'keep the route this installation uses and remove the other',
      );
    }
    if (fromCaller == true) {
      return const ElevationFromCaller();
    }
    if (file is String && file.isNotEmpty) {
      return ElevationFromFile(file);
    }
    throw PluginRejected(
      '$path: "elevation" says neither "password_file:" nor "password_from_caller: true", so '
      'nothing says where the password that raises a command to root comes from\n'
      'name the file holding it, or say the caller hands it over, or leave the whole block off '
      'where nothing needs root',
    );
  }

  /// The conditions [document] names, or none where it names none.
  ///
  /// Every key under a condition other than `predicate:` is a value handed to it. Which of them it
  /// accepts and what kind each holds is not decided here: this reads the file, and the binding
  /// against the registry says whether the values add up, because only the registry knows what the
  /// generic condition declared.
  static Map<String, ConditionBinding> _conditions(YamlMap document, String path) {
    final Object? written = document['conditions'];
    if (written == null) {
      return const <String, ConditionBinding>{};
    }
    if (written is! YamlMap) {
      throw PluginRejected(
        '$path: "conditions" has to be a mapping from the name a program row writes to what that '
        'name is',
      );
    }

    final Map<String, ConditionBinding> conditions = <String, ConditionBinding>{};
    for (final MapEntry<Object?, Object?> entry in written.entries) {
      final Object? name = entry.key;
      if (name is! String || !PredicateName.isValid(name)) {
        throw PluginRejected(
          '$path: "$name" is not a condition name — lower case, digits and underscores, starting '
          'with a letter, because that is what a program row may write behind "when:"',
        );
      }
      final Object? body = entry.value;
      if (body is! YamlMap) {
        throw PluginRejected(
          '$path: the condition "$name" has to be a mapping, naming the condition it is under '
          '"predicate:" and giving it its values',
        );
      }
      final Object? generic = body['predicate'];
      if (generic == null) {
        throw PluginRejected(
          '$path: the condition "$name" says no "predicate:", so nothing says which condition it is',
        );
      }
      if (generic is! String) {
        throw PluginRejected(
          '$path: the condition "$name" has "predicate: $generic", and that is the name of a '
          'registered condition',
        );
      }

      final Map<String, Object> values = <String, Object>{};
      for (final MapEntry<Object?, Object?> given in body.entries) {
        if (given.key == 'predicate') {
          continue;
        }
        final Object? key = given.key;
        if (key is! String) {
          throw PluginRejected(
            '$path: the condition "$name" has a value named "$key", which is '
            'not a name',
          );
        }
        values[key] = _value(given.value, condition: name, key: key, path: path);
      }
      conditions[name] = ConditionBinding(predicate: generic, values: values);
    }
    return conditions;
  }

  /// [written] as the framework holds a value, or a refusal naming where it stands.
  ///
  /// Scalars and lists of scalars, and nothing else. A nesting deeper than that is refused rather
  /// than flattened: a value nobody can see the shape of in the file is a value nobody can predict.
  static Object _value(
    Object? written, {
    required String condition,
    required String key,
    required String path,
  }) {
    if (written is YamlList) {
      final List<String> texts = <String>[];
      for (final Object? each in written) {
        if (each is! String && each is! int && each is! bool) {
          throw PluginRejected(
            '$path: the condition "$condition" gives "$key" a list holding "$each", and a list '
            'holds text',
          );
        }
        texts.add('$each');
      }
      return texts;
    }
    if (written is String || written is int || written is bool) {
      return written!;
    }
    throw PluginRejected(
      '$path: the condition "$condition" gives "$key" the value "$written", and a value is text, a '
      'whole number, true or false, or a list of text',
    );
  }

  /// The level [document] names, or `info` when it names none.
  ///
  /// A value that is not one of the four is refused with all four in the refusal, so somebody who
  /// wrote `warning` learns the word rather than that something was wrong.
  static LogLevel _logLevel(YamlMap document, String path) {
    final Object? written = document['log_level'];
    if (written == null) {
      return LogLevel.info;
    }
    for (final LogLevel level in LogLevel.values) {
      if (level.name == written) {
        return level;
      }
    }
    throw PluginRejected(
      '$path: "log_level" is "$written", and it is one of '
      '${LogLevel.values.map((LogLevel each) => each.name).join(', ')}',
    );
  }

  /// Whether `gate: dry:` leaves the gate standing, which is what a file saying nothing means.
  ///
  /// Only `false` turns it off, and it has to be written. A key that is absent, and a `gate:` block
  /// that names something else, both leave the gate where it is — so the one way to end up without
  /// it is to have typed the word.
  static bool _requireDryRun(YamlMap document, String path) {
    final Object? gate = document['gate'];
    if (gate == null) {
      return true;
    }
    if (gate is! YamlMap) {
      throw PluginRejected('$path: "gate" has to be a mapping, with "dry:" under it');
    }
    final Object? dry = gate['dry'];
    if (dry == null) {
      return true;
    }
    if (dry is! bool) {
      throw PluginRejected(
        '$path: "gate.dry" is "$dry", and it is true or false\n'
        'false means a real run no longer needs a clean dry run of the same input behind it',
      );
    }
    return dry;
  }

  /// How many run records `runs: keep:` says this machine keeps, or the default where it says
  /// nothing.
  ///
  /// A whole number of at least one, and nothing else. Zero is refused rather than read as "keep
  /// none": a machine that removed the record of the run that is happening could not be asked what
  /// that run did.
  static RunRetention _retention(YamlMap document, String path) {
    final Object? runs = document['runs'];
    if (runs == null) {
      return const RunRetention();
    }
    if (runs is! YamlMap) {
      throw PluginRejected('$path: "runs" has to be a mapping, with "keep:" under it');
    }
    final Object? keep = runs['keep'];
    if (keep == null) {
      return const RunRetention();
    }
    if (keep is! int || keep < 1) {
      throw PluginRejected(
        '$path: "runs.keep" is "$keep", and it is a whole number of at least one\n'
        'it is how many run records this machine keeps: the oldest beyond it are removed as each '
        'run starts, apart from a run that has not finished and a run another record resumes',
      );
    }
    return RunRetention(keep);
  }

  /// Whether `no_unwind:` disables the rollback of steps after a failure.
  static bool _allowUnwind(YamlMap document, String path) {
    final Object? val = document['no_unwind'];
    if (val == null) {
      return true;
    }
    if (val is! bool) {
      throw PluginRejected(
        '$path: "no_unwind" is "$val", and it must be true or false\n'
        'true means the engine will leave the machine exactly as it was when a failure happened',
      );
    }
    return !val;
  }
}
