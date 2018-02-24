/** Network transport management implementation for JSON-RPC data.

    You attach a transport to your RPCClient and a listener to your RPCServers,
    but you do not need to use the APIs directly.

    Example:
    ---
    interface IMyFuncs { void f(); }
    class MyFuncs : IMyFuncs { void f() { return; }

    // TCP sockets are the default - you don't have to name them explicitly...
    auto server = new RPCServer!(MyFuncs, TCPListener!MyFuncs)
            ("127.0.0.1", 54321);
    auto client = new RPCClient!(IMyFuncs, TCPTransport)
            ("127.0.0.1", 54321);

    client.f();
    ---

    Authors:
        Ryan Frame

    Copyright:
        Copyright 2018 Ryan Frame

    License:
        MIT
*/
module jsonrpc.transport;

import std.socket;
import jsonrpc.exception;

version(Have_tested) import tested : test = name;
else private struct test { string name; }

private enum SocketBufSize = 4096;

/** Manage TCP transport connection details and tasks. */
struct TCPTransport {
    package:

    /** Instantiate a TCPTransport object.

        Params:
            host = The hostname to connect to.
            port = The port number of the host to connect to.
    */
    this(string host, ushort port) in {
        assert(host.length > 0);
    } body {
        this(new TcpSocket(getAddress(host, port)[0]));
    }

    /** Send the provided data and return the number of bytes sent.

        If the return value is not equal to the length of the input in bytes,
        there was a transmission error.

        Params:
            data = The string data to send.
    */
    // TODO: Take data as ubyte[]?
    size_t send(const char[] data) {
        ptrdiff_t bytesSent = 0;
        while (bytesSent < data.length) {
            auto sent = _socket.send(data[bytesSent..$]);
            if (sent == Socket.ERROR || sent == 0) break;
            bytesSent += sent;
        }
        return bytesSent;
    }

    /** Receive a single JSON object or array from the socket stream. */
    char[] receiveJSONObjectOrArray() {
        // TODO: This assumes only ASCII characters.
        char[SocketBufSize] buf;
        char[] data;
        ptrdiff_t receivedBytes = 0;

        receivedBytes = _socket.receive(buf);
        if (receivedBytes <= 0) return data;

        data = buf[0..receivedBytes].dup;

        char startBrace;
        char endBrace;
        if (data[0] == '{') {
            startBrace = '{';
            endBrace = '}';
        } else if (data[0] == '[') {
            startBrace = '[';
            endBrace = ']';
        } else {
            raise!(InvalidDataReceivedException)
                    ("Expected to receive a JSON object or array.");
        }

        // Count the braces we receive. If we don't have a full object/array,
        // receive until we do.
        int braceCount = 0;
        size_t totalLoc = 0;
        while(true) {
            size_t loc = 0;
            do {
                if (data[totalLoc] == startBrace) ++braceCount;
                else if (data[totalLoc] == endBrace) --braceCount;
                ++loc;
                ++totalLoc;
            } while (loc < receivedBytes);

            // If we receive an incomplete object, get more data and repeat as
            // needed.
            if (braceCount > 0) {
                receivedBytes = _socket.receive(buf);
                if (receivedBytes > 0) {
                    data ~= buf[0..receivedBytes].dup;
                }
            } else return data;
        }
    }

    /** Close the transport's underlying socket. */
    void close() {
        _socket.shutdown(SocketShutdown.BOTH);
        _socket.close();
    }

    /** Query the transport to see if it's still active. */
    nothrow
    bool isAlive() {
        scope(failure) return false;
        return _socket.isAlive();
    }

    private:

    Socket _socket;

    /** This constructor is for unit testing. */
    package this(Socket socket) {
        _socket = socket;
        _socket.blocking = true;
    }
}

/** Listen for incoming connections and pass clients to a handler function.

    Template_Parameters:
        API = The class containing the methods for the server to execute.
*/
struct TCPListener(API) {
    package:

    /** Instantiate a TCPListener object.

        Params:
            host = The hostname to connect to.
            port = The port number of the host to connect to.
    */
    this(string host, ushort port) in {
        assert(host.length > 0);
    } body {
        _socket = new TcpSocket();
        _socket.blocking = true;
        _socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        _socket.bind(getAddress(host, port)[0]);
    }

    /** Listen for client requests.

        `listen` will call the specified handler function in a new thread to
        handle each client it accepts.

        Template_Parameters:
            handler = The handler function to call when a client connects.

        Params:
            api =                  An instantiated class with the methods to
                                   execute.
            maxQueuedConnections = The maximum number of connections to backlog
                                   before refusing connections.
    */
    void listen(alias handler)(API api, int maxQueuedConnections = 10) {
        _socket.listen(maxQueuedConnections);
        if (! _socket.isAlive) {
            raise!(ConnectionException)("Listening socket not active.");
        }

        while (true) {
            import std.parallelism : task;
            auto conn = _socket.accept();
            task!handler(TCPTransport(conn), api).executeInNewThread();
        }
    }

    private:

    Socket _socket;
}


@test("Can receive a JSON object")
unittest {
    interface I {}
    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    enum val = cast(char[])`{"id":23,"method":"func","params":[1,2,3]}`;

    sock._receiveReturnValue = val;
    auto ret = transport.receiveJSONObjectOrArray();
    assert(ret == val);
}

@test("Can receive a JSON array")
unittest {
    interface I {}
    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    enum val = cast(char[])`[{"id":23,"method":"func","params":[1,2,3]},
            {"id":24,"method":"func","params":[1,2,3]},
            {"id":25,"method":"func","params":[1,2,3]},
            {"method":"func","params":[1,2,3]},
            {"id":26,"method":"func","params":[1,2,3]}]`;

    sock._receiveReturnValue = val;
    auto ret = transport.receiveJSONObjectOrArray();
    assert(ret == val);
}

@test("receiveJSONObjectOrArray if not given an array or object")
unittest {
    import std.exception : assertThrown;
    interface I {}
    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    enum val = cast(char[])`"id":23,"method":"func","params":[1,2,3]}`;

    sock._receiveReturnValue = val;
    assertThrown!InvalidDataReceivedException(
            transport.receiveJSONObjectOrArray());
}

version(unittest) {
    class FakeSocket : Socket {
        private bool _blocking;
        private bool _isAlive;

        private char[] _receiveReturnValue =
                cast(char[])`{"id":3,"result":[1,2,3]}`;

        @property receiveReturnValue(string s) {
            _receiveReturnValue = cast(char[])s;
        }

        @property char[] receiveReturnValue() { return _receiveReturnValue; }

        override void bind(Address addr) { _isAlive = true; }

        override const nothrow @nogc @property @trusted bool blocking() {
            return _blocking;
        }

        override @property @trusted void blocking(bool byes) {
            _blocking = byes;
        }

        override @trusted void setOption(SocketOptionLevel level,
                SocketOption option, void[] value) {}

        override const @property @trusted bool isAlive() { return _isAlive; }

        override @trusted void listen(int backlog) { _isAlive = true; }

        alias receive = Socket.receive;
        override @trusted ptrdiff_t receive(void[] buf) {
            if (buf.length == 0) return 0;
            auto ret = fillBuffer(cast(char*)buf.ptr, buf.length);
            _receiveReturnValue = _receiveReturnValue[ret..$];
            return ret;
        }

        @test("FakeSocket.receive")
        unittest {
            auto s = new FakeSocket;
            char[] buf = new char[](SocketBufSize);
            s.receiveReturnValue = `{"id":3,"result":[1,2,3]}`;

            auto len = s.receive(buf);
            assert(buf[0..len] == `{"id":3,"result":[1,2,3]}`,
                    "Incorrect data received: " ~ buf);
        }

        alias send = Socket.send;
        override @trusted ptrdiff_t send(const(void)[] buf) {
            return buf.length;
        }

        private @trusted ptrdiff_t fillBuffer(char* ptr, size_t length) {
            char[] p = ptr[0..length];
            ptrdiff_t cnt;
            for (cnt = 0; cnt < receiveReturnValue.length; ++cnt) {
                ptr[cnt] = receiveReturnValue[cnt];
            }
            return cnt;
        }
    }
}
