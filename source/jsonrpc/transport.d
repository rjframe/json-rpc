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

        override void bind(Address addr) {
        }

        override const nothrow @nogc @property @trusted bool blocking() {
            return _blocking;
        }

        override @property @trusted void blocking(bool byes) {
            _blocking = byes;
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
    bool receive(long id, out RESP response);
}

/** Interface that provides server transport functions. */
interface RPCServerTransport {
    /** Tell a server to listen for incoming connections. */
    void listen();
}

/** TCP transport for RPC clients. */
class TCPClientTransport(REQ, RESP) : RPCClientTransport!(REQ, RESP) {
    private:

    Socket _socket;
    RESP[long] _responses;
    char[] _data; // = new char[](SocketBufSize);

    /** Private constructor allows unittesting; we don't want sockets passed in
        explicitly.
    */
    this(Socket socket) {
        _socket = socket;
        _socket.blocking = false;
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
        assert(0, "send not implemented.");
    }

    /** Check for and return a response from an asynchronous remote call.

        Params:
            id =       The ID of the request for which to check for a response.
            response = An object in which to return the response if available.

        Returns: true if the response is ready; otherwise, false.
    */
    bool receive(long id, out RESP response) {
        if (id in _responses) {
            response = _responses[id];
            _responses.remove(id);
            return true;
        }
        return false;
    }
}

@test("recvFromSocket returns the bytestream as a JSON object.")
unittest {
    import jsonrpc.jsonrpc;
    //buf = `{"id":3,"result":[1,2,3]}`;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)
            (new FakeSocket);

    transport.recvFromSocket();
    assert(3 in transport._responses,
            "Response not saved in the transport.");
    assert(transport._responses[3]._id == 3,
            "Response didn't store the ID.");
    assert(transport._responses[3]._result == JSONValue(`[1,2,3]`),
            "Response didn't store the data.");
}

@test("TCPClientTransport.receive returns the specified response if possible.")
unittest {
    import jsonrpc.jsonrpc : RPCRequest, RPCResponse;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)
            (new FakeSocket);

    auto resp = RPCResponse(3, "{}".parseJSON);
    RPCResponse returnedResponse;

    assert(transport.receive(3, returnedResponse) == false,
            "`receive` returned a response it doesn't have.");
    assert(returnedResponse.id == 0);

    transport._responses[3] = resp;
    assert(transport.receive(3, returnedResponse) == true,
            "`receive` failed to return a received response.");
    assert(returnedResponse.id == 3);

    assert(transport.receive(3, returnedResponse) == false,
            "`receive` did not remove a previously-returned response.");
    assert(returnedResponse.id == 0);
}

/** TCP transport for RPC servers. */
class TCPServerTransport(REQ, RESP) : RPCServerTransport!(REQ, RESP) {
    private:

    Socket _socket;

    this(Socket socket, string host, ushort port) {
        _socket.bind(getAddress(host, port)[0]);
    }

    public:

    /** Instantiate a TCPServerTransport object.

        Params:
            host =  The host interface on which to listen.
            port =  The port on which to listen.
    */
    this(string host, ushort port) {
        this(new TcpSocket(), host, port);
    }

    /** Begin listening for client requests. */
    void listen() {
        _socket.listen(5);
    }
}
