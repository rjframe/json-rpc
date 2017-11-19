/** Network transport objects.

    Deriving the RPCClientTransport and RPCServerTransport interfaces allow
    implementing alternative transport methods (HTTP, SSL sockets, etc.).

*/
module jsonrpc.transport;

import std.json;
import std.socket;
import std.traits : hasMember;

import jsonrpc.exception;

version(Have_tested) import tested : test = name;
else private struct test { string name; }

enum SocketBufSize = 4096;

version(unittest) {
    class FakeSocket : Socket {
        private bool _blocking;
        private char[] _receiveReturnValue =
                cast(char[])`{"id":3,"result":[1,2,3]}`;

        @property receiveReturnValue(string s) {
            _receiveReturnValue = cast(char[])s;
        }

        @property char[] receiveReturnValue() { return _receiveReturnValue; }

        override void bind(Address addr) {
        }

        override const nothrow @nogc @property @trusted bool blocking() {
            return _blocking;
        }

        override @property @trusted void blocking(bool byes) {
            _blocking = byes;
        }

        override @trusted void listen(int backlog) {}

        alias receive = Socket.receive;
        override @trusted ptrdiff_t receive(void[] buf) {
            if (buf.length == 0) return 0;
            auto ret = fillBuffer(cast(char*)buf.ptr, buf.length);
            _receiveReturnValue = _receiveReturnValue[ret..$];
            return ret;
        }

        @test("FakeSocket.receive")
        unittest {
            auto s = new FakeSocket();
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

/** Interface that provides client transport functions. */
interface RPCClientTransport(REQ, RESP)
        if (hasMember!(REQ, "_id") && hasMember!(REQ, "toJSONString")) {

    /** Send a request from a client to a server asynchronously.

        Params:
            request =   The object to send to the server.

        Returns:
            The ID of the request sent.
    */
    void send(REQ request);

    /** Check for and return a response to a request from a server.

        Params:
            id =        The ID of the request to retrieve.
            response =  The object requested if available; otherwise, T.init.

        Returns:
            true if the requested object is available; false otherwise.
    */
    bool receiveAsync(long id, out RESP response);

    RESP receive(long id);
}

/** Interface that provides server transport functions. */
interface RPCServerTransport(REQ, RESP)
        if (hasMember!(REQ, "_id") && hasMember!(RESP, "fromJSONString")) {

    /** Tell a server to listen for incoming connections. */
    void listen();
    bool receiveAsync(long id, out REQ request);
    RESP receive(long id);
    void send(RESP response);
    /** Close all connections and clean up any managed resources. */
    void close();
}

/** TCP transport for RPC clients. */
class TCPClientTransport(REQ, RESP) : RPCClientTransport!(REQ, RESP) {
    private:

    Socket _socket;
    RESP[long] _responses;
    char[] _data; // = new char[](SocketBufSize);

    package:

    /** Initialize a transport with the specified socket.

        This socket will be set to a blocking socket.
        This is for unittesting; we don't want sockets passed in explicitly.
    */
    this(Socket socket) {
        _socket = socket;
        _socket.blocking = true;
    }

    public:

    /** Instantiate a TCPClientTransport with the specified host and port.

        Params:
            host =  The host to connect to.
            port =  The port on the host to connect to.
    */
    this(string host, ushort port) {
        this(new TcpSocket(getAddress(host, port)[0]));
    }

    /** Send an object to the connected server. */
    void send(REQ request) {
        auto data = request.toJSONString;
        auto len = _socket.send(data);
        if (len != data.length)
                raise!(FailedToSendDataException, len, request)
                ("Failed to send the entire request.");
    }

    /** Check for and return a response from an asynchronous remote call.

        Params:
            id =       The ID of the request for which to check for a response.
            response = An object in which to return the response if available.

        Returns: true if the response is ready; otherwise, false.
    */
    bool receiveAsync(long id, out RESP response) {
    /+ TODO: Reimplement receiveAsync.
        scope(failure) return false;
        addToResponses(receiveObjectFromStream); // TODO: On another thread/ use Tasks?

        if (id in _responses) {
            response = _responses[id];
            _responses.remove(id);
            return true;
        }
    +/
        return false;
    }

    RESP receive(long id) {
        while (! (id in _responses)) {
            addToResponses(receiveObjectFromStream); // TODO: On another thread/ use Tasks?
        }
        auto response = _responses[id];
        _responses.remove(id);
        return response;
    }

    private char[] receiveObjectFromStream() {
        char[SocketBufSize] buf;
        ptrdiff_t returnedBytes;
        do {
            returnedBytes = _socket.receive(buf);
            if (returnedBytes == 0) return _data;
            else if (returnedBytes > 0) _data ~= buf;
        } while(returnedBytes > 0 && !Socket.ERROR);

        // We know that we're receiving a JSON object, so we just need to count
        // '{' and '}' characters.
        int cnt = 0;
        if (_data[0] != '{') raise!(InvalidDataReceivedException)
            ("Expected to receive a '{' to begin a new JSON object.");

        char[] obj; // TODO: make this an appender.
        do {
            if (_data[0] == '{') ++cnt;
            else if (_data[0] == '}') --cnt;
            obj ~= _data[0];
            // TODO: If we have an incomplete object, we won't want to do this
            // since we need to leave it there until we receive the rest of the
            // object.
            _data = _data[1..$];
        } while (cnt > 0);
        return obj;
    }

    private void addToResponses(const char[] obj) {
    // TODO: Should handle the case where multiple objects have been received.
        auto resp = RESP.fromJSONString(obj);
        _responses[resp._id] = resp;
        assert(resp.id in _responses, "Object not added.");
    }
}

@test("addToResponses converts the data stream to a JSON object.")
unittest {
    import jsonrpc.jsonrpc;
    auto sock = new FakeSocket;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)(sock);
    transport.addToResponses(`{"id":3,"result":[1,2,3]}`);

    assert(3 in transport._responses,
            "Response not saved in the transport.");
    assert(transport._responses[3]._id == 3,
            "Response didn't store the ID.");
    assert(transport._responses[3]._result == JSONValue([1,2,3]),
            "Response didn't store the data.");
}

@test("receiveObjectFromStream pulls a complete JSON string from the stream.")
unittest {
    import jsonrpc.jsonrpc;
    auto sock = new FakeSocket;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)(sock);
    sock.receiveReturnValue = `{"id":3,"result":[1,2,3]}`;

    auto ret = transport.receiveObjectFromStream();
    assert(ret == `{"id":3,"result":[1,2,3]}`, "Did not return object.");
}

@test("TCPClientTransport.receiveAsync returns false if response not present.")
unittest {
    import std.exception : assertThrown;
    import jsonrpc.jsonrpc : RPCRequest, RPCResponse;

    auto sock = new FakeSocket;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)(sock);

    sock.receiveReturnValue = "";
    RPCResponse returnedResponse;

    assert(transport.receiveAsync(3, returnedResponse) == false,
            "`receive` returned a response it doesn't have.");
    assert(returnedResponse.id == 0);
}

@test("TCPClientTransport.receiveAsync returns the specified response if possible.")
unittest {
    import std.exception : assertThrown;
    import jsonrpc.jsonrpc : RPCRequest, RPCResponse;

    auto sock = new FakeSocket;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)(sock);

    sock.receiveReturnValue = `{"id":3,"result":[1,2,3]}`;
    RPCResponse returnedResponse;

    auto resp = RPCResponse(3, `{"id":3,"result":[1,2,3]}`.parseJSON);
    transport._responses[3] = resp;
    assert(transport.receiveAsync(3, returnedResponse) == true,
            "`receive` failed to return a received response.");
    assert(returnedResponse.id == 3);

    assert(transport.receiveAsync(3, returnedResponse) == false,
            "`receive` did not remove a previously-returned response.");
    assert(returnedResponse.id == 0);
}

@test("TCPClientTransport.receivereturns the specified response.")
unittest {
    import jsonrpc.jsonrpc : RPCRequest, RPCResponse;

    auto sock = new FakeSocket;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)(sock);
    auto resp = RPCResponse(3, `{"id":3,"result":[1,2,3]}`.parseJSON);
    transport._responses[3] = resp;

    assert(transport.receive(3) == resp);
}

/** TCP transport for RPC servers. */
class TCPServerTransport(REQ, RESP) : RPCServerTransport!(REQ, RESP) {
    package:

    Socket _socket;

    this(Socket socket, string host, ushort port) {
        _socket = socket;
        _socket.blocking = false;
        _socket.bind(getAddress(host, port)[0]);
    }

    public:

    /** Instantiate a TCPServerTransport object.

        Params:
            host =  The host interface on which to listen.
            port =  The port on which to listen.
    */
    this(string host, ushort port) {
        this(new TcpSocket, host, port);
    }

    /** Begin listening for client requests. */
    void listen() {
        _socket.listen(10);
    }

    bool receiveAsync(long id, out REQ request) {
        assert(0, "receiveAsync not implemented.");
    }

    RESP receive(long id) {
        assert(0, "receive not implemented.");
    }

    void send(RESP response) {
        assert(0, "send not implemented.");
    }

    /** End all connections and shut down the socket. */
    void close() { _socket.close; }
}
