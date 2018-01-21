/** Network transport layers for JSON-RPC data.

    You attach a transport to your RPCClient and RPCServers, but you do not need
    to use its API directly.

    Example:
    ---
    interface IMyFuncs { void f(); }
    class MyFuncs : IMyFuncs { void f() { return; }

    // TCPTransport is the default - you don't have to do this explicitly...
    auto server = new RPCServer!(MyFuncs, TCPTransport!MyFuncs)
            ("127.0.0.1", 54321);
    auto client = new RPCClient!(IMyFuncs, TCPTransport!IMyFuncs)
            ("127.0.0.1", 54321);
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

/** Manage TCP transport details for RPCClient objects.

    Compile_Time_Parameters:
        API = The class or interface providing the RPC API.
*/
struct TCPTransport(API) {
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
    */
    size_t send(const char[] data) {
        ptrdiff_t bytesSent = 0;
        while (bytesSent < data.length) {
            auto sent = _socket.send(data[bytesSent..$]);
            if (sent == Socket.ERROR || sent == 0) break;
            bytesSent += sent;
        }
        return bytesSent;
    }

    /** Receive a single JSON object from the socket stream. */
    char[] receiveJSONObject() {
        char[SocketBufSize] buf;
        char[] data;
        ptrdiff_t receivedBytes = 0;

        receivedBytes = _socket.receive(buf);
        // TODO: Throw on no input data?
        if (receivedBytes <= 0) { return data; }

        data = buf[0..receivedBytes].dup;
        if (data[0] != '{') raise!(InvalidDataReceivedException)
            ("Expected to receive a '{' to begin a new JSON object.");

        // Count the braces we receive. If we don't have a full object, receive
        // until we do.
        int braceCount = 0;
        size_t totalLoc = 0;
        while(true) {
            size_t loc = 0;
            do {
                if (data[totalLoc] == '{') ++braceCount;
                else if (data[totalLoc] == '}') --braceCount;
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

    // TODO: It makes sense to use separate transport objects for clients and
    // servers; this would let me take the host and port in the constructor, etc.
    // and just be a cleaner division of tasks, even though most functionality
    // is the same.
    // at compile-time;
    /** Listen for client requests.

        `listen` will call the specified handler function in a new thread to
        handle each client it accepts.

        Compile_Time_Parameters:
            handler = The handler function to call when a client connects.

        Params:
            api =                  An instantiated class with the methods to
                                   execute.
            host =                 The hostname of the server on which to listen.
            port =                 The port on which to listen.
            maxQueuedConnections = The maximum number of connections to backlog
                                   before refusing connections.
    */
    void listen(alias handler)(
            API api, string host, ushort port, int maxQueuedConnections = 10) {
        import std.parallelism : task;

        with (_socket) {
            setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
            bind(getAddress(host, port)[0]);
            listen(maxQueuedConnections);
            if (! isAlive) {
                raise!(ConnectionException)("Listening socket not active.");
            }
        }

        while (true) {
            auto conn = _socket.accept;
            task!handler(TCPTransport(conn), api).executeInNewThread;
        }
    }

    private:

    Socket _socket;

    /** This constructor is for unit testing. */
    package this(Socket socket) {
        _socket = socket;
        _socket.blocking = true;
    }
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
