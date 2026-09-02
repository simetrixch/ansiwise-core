/// The path arithmetic the gate does for itself.
///
/// `package:path` would answer all of this, and nothing under tool/ may import it. The gate is what
/// resolves the tree — `dart pub get` is its first step — so its own program has to start on a fresh
/// clone where no package has been resolved, and a `package:` import would make it unable to start
/// until it had already run. So tool/ imports nothing but `dart:`, and the two things it needs from
/// a path library are here.
library;

import 'dart:io';

/// The last segment of [path], whichever separator this operating system wrote it with.
String baseName(String path) {
  final int cut = path.lastIndexOf(_separator);
  return cut < 0 ? path : path.substring(cut + 1);
}

/// The package a program under `tool/` is part of.
///
/// Taken from where the program's own file sits rather than from the working directory, so `dart run
/// tool/ci.dart` answers the same from anywhere in the tree. [script] is `Platform.script`; it is a
/// parameter rather than read here so that what this resolves to can be asserted.
Directory packageOfToolScript(Uri script) => File.fromUri(script).parent.parent.absolute;

/// The repository [start] sits in: the nearest directory at or above it holding `.git`.
///
/// WHAT THIS IS FOR. The gate checks a REPOSITORY, and a repository is not a package. Where a
/// repository holds a single package the two are the same directory and the difference cannot be
/// seen; the moment a second package stands beside it, a gate that walks the package walks the
/// first alone and prints `every check green` with every file of the second never analysed, never
/// formatted-checked and never run. A gate that cannot see half a repository and says every check
/// is green is not a gap in coverage, it is a wrong answer in the shape of a right one.
///
/// Throws [StateError] when there is no `.git` above [start], because then there is no repository to
/// check and every answer this gate could give would be about something else.
Directory repositoryOf(Directory start) {
  Directory directory = start.absolute;
  while (true) {
    if (Directory('${directory.path}/.git').existsSync() ||
        File('${directory.path}/.git').existsSync()) {
      return directory;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'no .git at or above ${start.path}, so there is no repository here to check and a run '
        'would report about a tree nobody named',
      );
    }
    directory = parent;
  }
}

final RegExp _separator = RegExp(r'[/\\]');
