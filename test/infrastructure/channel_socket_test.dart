import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

/// The channel dressed as a socket, and the one property everything above it rests on.
///
/// **THE DEFECT THIS EXISTS FOR IS SILENT.** A `ChannelServerSocket` that hands out its one
/// connection from a stream ending the moment it has yielded it closes the server in the same turn
/// it is opened: `HttpServer.listenOn` ends its own stream of requests when the server socket it
/// was given ends, and a request already on its way arrives at a server that has shut.
/// `ansiwise serve` over a session then answers NOTHING, exits zero, and says nothing about why —
/// the door the operator app and every first installation of every machine depend on.
///
/// **WHY A TEST MISSES IT.** A test that feeds the connection from a `StreamController` whose data
/// is already queued lets the request win the race against the close often enough to look correct.
/// A real session — a process reading its own standard input — loses that race every time. So what
/// is asserted here is not "a request is answered" but the property underneath it: **the stream of
/// connections does not end by itself.**
void main() {
  group('the server socket', () {
    test('does not end on its own once it has offered the connection', () async {
      final StreamController<List<int>> incoming = StreamController<List<int>>();
      final StreamController<List<int>> outgoing = StreamController<List<int>>();
      // Drained, because a controller nobody reads never completes its close — the test would hang
      // on its own tidying rather than on the thing it measures.
      outgoing.stream.listen((List<int> _) {});
      final ChannelServerSocket server = ChannelServerSocket(
        ChannelSocket(incoming: incoming.stream, outgoing: outgoing.sink),
      );

      final List<Socket> offered = <Socket>[];
      bool ended = false;
      server.listen((Socket connection) {
        offered.add(connection);
        // Read, the way an HttpServer reads it — an unread connection leaves the channel's own
        // stream without a listener, and this test would then hang on its own tidying.
        connection.listen((Uint8List _) {});
      }, onDone: () => ended = true);

      // Long enough for a stream that ends after one value to have ended: a shape that completes
      // in the same turn is gone before anything waiting on it gets a look.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(offered, hasLength(1), reason: 'the one connection was never offered');
      expect(
        ended,
        isFalse,
        reason:
            'the connections ended by themselves — an HttpServer given this closes its request '
            'stream, and every request after that arrives at a server that has shut',
      );

      await incoming.close();
      await outgoing.close();
    });

    test('ends when the channel ends, so no process is left behind', () async {
      // The other half, and it is not optional: a server that outlived its one channel would be a
      // process still running on every machine anybody ever spoke to.
      final StreamController<List<int>> incoming = StreamController<List<int>>();
      final StreamController<List<int>> outgoing = StreamController<List<int>>();
      // Drained, because a controller nobody reads never completes its close — the test would hang
      // on its own tidying rather than on the thing it measures.
      outgoing.stream.listen((List<int> _) {});
      final ChannelServerSocket server = ChannelServerSocket(
        ChannelSocket(incoming: incoming.stream, outgoing: outgoing.sink),
      );

      final Completer<void> ended = Completer<void>();
      server.listen(
        // The connection has to be read for its end to be noticed, which is what an HttpServer does.
        (Socket connection) => connection.listen((Uint8List _) {}),
        onDone: ended.complete,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ended.isCompleted, isFalse);

      await incoming.close();

      await expectLater(
        ended.future.timeout(const Duration(seconds: 2)),
        completes,
        reason: 'the channel closed and the server went on offering a connection nobody is on',
      );
      await outgoing.close();
    });

    test('ends when it is closed, and closing twice is not an error', () async {
      final StreamController<List<int>> incoming = StreamController<List<int>>();
      final StreamController<List<int>> outgoing = StreamController<List<int>>();
      // Drained, because a controller nobody reads never completes its close — the test would hang
      // on its own tidying rather than on the thing it measures.
      outgoing.stream.listen((List<int> _) {});
      final ChannelServerSocket server = ChannelServerSocket(
        ChannelSocket(incoming: incoming.stream, outgoing: outgoing.sink),
      );

      final Completer<void> ended = Completer<void>();
      server.listen(
        (Socket connection) => connection.listen((Uint8List _) {}),
        onDone: ended.complete,
      );
      await server.close();
      await server.close();

      await expectLater(ended.future.timeout(const Duration(seconds: 2)), completes);
      await incoming.close();
      await outgoing.close();
    });
  });
}
