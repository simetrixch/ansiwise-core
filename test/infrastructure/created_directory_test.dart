import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

/// WHOSE MODE A DIRECTORY'S IS.
///
/// Every step that writes a file reaches this: FileStep.apply makes the file's directory first, so
/// no step has to, and it asks for it at the FILE's mode. That is right for a directory the product
/// invents and wrong for one the machine already keeps — and the difference is not cosmetic. A
/// program rendering a scratch manifest to `/tmp/<name>.yaml` asked for `/tmp` at 0755. Without
/// elevation that is a refusal (`chmod returned 1, path = '/tmp'`) and a deployment stopped on it.
/// WITH elevation it succeeds, and `install -d -m 0755 /tmp` takes the sticky bit off the one
/// directory on a machine that most needs it: every account could then delete every other account's
/// files there, and nothing would report it.
///
/// So the mode belongs to what this call CREATES. What was already there is left exactly as it
/// stands.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('created-dir-'));
  tearDown(() => root.deleteSync(recursive: true));

  const RealFiles files = RealFiles();

  /// The permission bits of [path], as the machine states them.
  int bitsOf(String path) => Directory(path).statSync().mode & 0xFFF;

  test('a directory that is already there keeps the mode it has', () async {
    final String standing = '${root.path}/standing';
    Directory(standing).createSync();
    await Process.run('chmod', <String>['700', standing]);
    final int before = bitsOf(standing);

    await files.createDirectory(standing, mode: 0x1ed); // 0755, what a world-readable file asks for

    expect(bitsOf(standing), before, reason: 'it re-permissioned a directory it did not create');
  }, skip: Platform.isWindows ? 'permission bits are not a Windows concept' : null);

  test('a directory this call creates is given the mode it was asked for', () async {
    final String fresh = '${root.path}/made/here';
    await files.createDirectory(fresh, mode: 0x1c0); // 0700
    expect(Directory(fresh).existsSync(), isTrue);
    expect(bitsOf(fresh), 0x1c0);
  }, skip: Platform.isWindows ? 'permission bits are not a Windows concept' : null);

  test(
    'THE SHAPE THAT BROKE A DEPLOYMENT: a file written into a directory nobody here owns',
    () async {
      // The row is `path: /tmp/<name>.yaml`, and /tmp belongs to root with the sticky bit. Writing the
      // file is the caller's business; the directory is not, and asking for it must not refuse.
      final String scratch = Directory.systemTemp.path;
      await files.createDirectory(scratch, mode: 0x1ed);
      final String file = '$scratch/ansiwise-created-directory-probe.yaml';
      await files.write(file, 'kind: Probe\n', mode: 0x1a4);
      expect(File(file).readAsStringSync(), 'kind: Probe\n');
      File(file).deleteSync();
    },
  );

  test('a directory made under a path that did not exist at all comes into being whole', () async {
    final String deep = '${root.path}/a/b/c';
    await files.createDirectory(deep, mode: 0x1ed);
    expect(Directory(deep).existsSync(), isTrue);
  });
}
