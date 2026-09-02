/// The SSH channel, dressed as the socket `HttpServer` expects.
///
/// `HttpServer.listenOn` takes a `ServerSocket`, and a `ServerSocket` hands out `Socket`s. Neither
/// of those has to come from the network: everything the HTTP server uses is the byte stream on one
/// side and the sink on the other, and an SSH exec channel gives exactly those as its standard
/// input and output.
///
/// So this is how a REST endpoint is served with nothing listening anywhere. There is no port and no
/// socket file; the client starts the process inside a session it already opened, and the session is
/// the connection. When it closes, no process is left.
///
/// The two classes here are the whole of that trick, and both are thin on purpose — everything
/// interesting is the real `HttpServer` above them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A `Socket` whose bytes come from one stream and go to one sink.
///
/// Nothing here talks to a network, so the address and port answers are placeholders. They exist
/// because the interface has them; the HTTP server does not read them, and a caller that did would
/// be asking the wrong object.
final class ChannelSocket extends Stream<Uint8List> implements Socket {
  /// Wraps the channel's input and output as one connection.
  ChannelSocket({required Stream<List<int>> incoming, required this.outgoing}) {
    _incoming = incoming
        .map(Uint8List.fromList)
        .transform(
          StreamTransformer<Uint8List, Uint8List>.fromHandlers(
            handleDone: (EventSink<Uint8List> sink) {
              if (!_ended.isCompleted) {
                _ended.complete();
              }
              sink.close();
            },
          ),
        );
  }

  late final Stream<Uint8List> _incoming;
  final Completer<void> _ended = Completer<void>();

  /// Completes when the far side stopped sending, which is when the session is over.
  ///
  /// Watched by whoever offered this connection, because a server that outlived its one channel
  /// would be a process left behind on every machine anybody ever spoke to.
  Future<void> get channelEnded => _ended.future;

  /// Where the answer's bytes go — the channel's standard output.
  final StreamSink<List<int>> outgoing;

  @override
  Encoding encoding = utf8;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  void add(List<int> data) => outgoing.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => outgoing.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => outgoing.addStream(stream);

  @override
  Future<void> close() => outgoing.close();

  @override
  Future<void> get done => outgoing.done;

  @override
  Future<void> flush() async {
    // The channel's own sink decides when bytes leave; there is nothing held back here to push.
  }

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void destroy() {
    unawaited(outgoing.close());
  }

  @override
  bool setOption(SocketOption option, bool enabled) => false;

  @override
  Uint8List getRawOption(RawSocketOption option) => Uint8List(0);

  @override
  void setRawOption(RawSocketOption option) {}

  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;

  @override
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;

  @override
  int get port => 0;

  @override
  int get remotePort => 0;
}

/// A `ServerSocket` that hands out one connection: the channel.
///
/// One and not many, because a session is one connection. A client that wants a second opens a
/// second session, which SSH multiplexes over the same transport — so watching four machines at
/// once is four channels, not a listening port.
/// **IT HANDS THE CONNECTION OVER AND THEN STAYS OPEN, and the second half is the one everything
/// above it rests on.** `HttpServer.listenOn` ends its own stream of requests when the server
/// socket it was given ends, and a stream that yields one value ends the moment it has yielded it.
/// Such a server closes in the same turn it is handed the connection, and a request already on its
/// way arrives at a server that has shut: `serve` over a session then answers nothing at all, exits
/// zero, and says nothing about why.
///
/// A test does not catch that on its own, because a test feeds the connection from a
/// `StreamController` whose data is already queued, so the request wins the race against the close
/// often enough to look correct. A real session loses that race every time. What ends this stream
/// is [close] and nothing else.
final class ChannelServerSocket extends Stream<Socket> implements ServerSocket {
  /// Offers the given connection as the only one this server will ever accept.
  ChannelServerSocket(this._connection);

  final ChannelSocket _connection;

  /// Holds the one connection, and stays open until the channel ends or [close] is called.
  late final StreamController<Socket> _connections = StreamController<Socket>(
    onListen: () {
      _connections.add(_connection);
      // The one thing that ends this by itself. A session that closed is a connection nobody is on
      // any more, and a server still offering it would be a process left behind on that machine.
      unawaited(_connection.channelEnded.whenComplete(close));
    },
  );

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _connections.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;

  @override
  int get port => 0;

  /// Stops offering connections, which is what ends the server above.
  @override
  Future<ServerSocket> close() async {
    if (!_connections.isClosed) {
      await _connections.close();
    }
    return this;
  }
}
