/** JSON-RPC 2.0 protocol library.

    The JSON-RPC 2.0 specification may be found at
    $(LINK http&#58;//www.jsonrpc.org/specification)
*/
module jsonrpc.jsonrpc;

import std.json;
public import std.typecons : Yes, No;

import jsonrpc.transport;
import jsonrpc.exception;

version(Have_tested) import tested : test = name;
else private struct test { string name; }

version(unittest) {
    class FakeTransport : RPCClientTransport!(RPCRequest, RPCResponse) {
        RPCResponse[long] fakedResponses;
        override void send(RPCRequest req) {}

        override bool receiveAsync(long id, out RPCResponse response) {
            return false;
        }

        override RPCResponse receive(long id) {
            if (id in fakedResponses) return fakedResponses[id];
            assert(0, "Fake blocking function doesn't have requested object.");
        }

        // TODO: Won't compile without overriding. Why?
        override void close() {}
    }
}

alias ClientTransport = RPCClientTransport!(RPCRequest, RPCResponse);
alias ServerTransport = RPCServerTransport!(RPCRequest, RPCResponse);

/** An RPC request constructed by the client to send to the RPC server. */
struct RPCRequest {
    import std.typecons : Flag;

    private:

    long _id;
    JSONValue _params;
    string _method;

    package:

    /** Construct an RPCRequest with the specified remote method name and
        arguments.

        Params:
            id =        The ID number of this request.
            method =    The name of the remote method to call.
            params =    A JSON string containing the method arguments as a JSON
                        Object or array.

        Throws:
            InvalidArgumentException if the json string is not a JSON Object or
            array.

            std.json.JSONException if the json string cannot be parsed.
    */
    this(long id, string method, string params) in {
        assert(method.length > 0);
    } body {
        this(id, method, params.parseJSON);
    }

    /** Construct an RPCRequest with the specified remote method name and
        arguments.

        Params:
            id =        The ID number of this request.
            method =    The name of the remote method to call.
            params =    A JSON string containing the method arguments as a JSON
                        Object or array.

        Throws:
            InvalidArgumentException if the json string is not a JSON Object or
            array.
    */
    this(long id, string method, JSONValue params = JSONValue()) in {
        assert(method.length > 0);
    } body {
        this._id = id;
        this.method = method;
        this.params = params;
    }

    /** Convert the RPCRequest to a JSON string to pass to the server.

        Params:
            prettyPrint =   Yes/no flag to control presentation of the JSON.
    */
    string toJSONString(Flag!"prettyPrint" prettyPrint = No.prettyPrint) {
        import std.format : format;
        string ret =
`{
    "jsonrpc": "%s",
    "method": "%s",
    "id": %s`.format(protocolVersion, method, _id);

        if (params.type != JSON_TYPE.NULL) {
            ret ~= ",\n    \"params\": %s".format(_params.toJSON);
        }
        ret ~= "\n}";

        if (! prettyPrint) ret = ret.removeWhitespace;
        return ret;
    }

    @test("RPCRequest.toJSONString converts an object with array params.")
    unittest {
        auto req = RPCRequest(1, "method", "[1, 2, 3]".parseJSON);
        assert(req.toJSONString ==
            `{"jsonrpc":"2.0","method":"method","id":1,"params":[1,2,3]}`);
    }

    @test("RPCRequest.toJSONString converts an object with Object params.")
    unittest {
        auto req = RPCRequest(1, "method", `{"a": "b"}`.parseJSON);
        assert(req.toJSONString ==
            `{"jsonrpc":"2.0","method":"method","id":1,"params":{"a":"b"}}`);
    }

    @test("RPCRequest.toJSONString converts an object with no params.")
    unittest {
        auto req = RPCRequest(1, "method");
        assert(req.toJSONString ==
            `{"jsonrpc":"2.0","method":"method","id":1}`);
    }

    @test("RPCRequest.toJSONString pretty-prints without modifying params objects.")
    unittest {
        auto req = RPCRequest(1, "method", `{"a space": "b space"}`.parseJSON);

        assert(req.toJSONString(Yes.prettyPrint) ==
`{
    "jsonrpc": "2.0",
    "method": "method",
    "id": 1,
    "params": {"a space":"b space"}
}`);
    }

    public:

    /** The JSON-RPC protocol version. */
    @property string protocolVersion() { return "2.0"; }

    /** The ID of this request. */
    @property long id() { return _id; }

    /** Retrieve the method to execute on the RPC server. */
    @property string method() { return _method; }

    /** Specify the method to execute on the RPC server. */
    @property void method(string val) {
        _method = val;
    }

    /** Retrieve the parameters that will be passed to the method. */
    @property JSONValue params() { return _params; }

    /** Set the parameters to the remote method that will be called.

        The JSONValue must be an Object or Array.

        Params:
            val =   A JSON Object or array.

        Throws:
            InvalidArgumentException if val is not a JSON Object or array.
    */
    @property void params(JSONValue val)
    {
        // We consider null to be equivalent to an empty object.
        if (val.type != JSON_TYPE.OBJECT && val.type != JSON_TYPE.ARRAY
                && val.type != JSON_TYPE.NULL) {
            raise!(InvalidArgumentException, val)
                    ("Invalid JSON-RPC method parameter type.");
        }
        _params = val;
    }

    /** Set the parameters to the remote method as a JSON string.

        The string must be a JSON Object or array.

        Params:
            json =   A JSON string.

        Throws:
            InvalidArgumentException if the json string is not a JSON Object or
            array.

            std.json.JSONException if the json string cannot be parsed.
    */
    @property void params(string json) in {
        assert(json.length > 0);
    } body {
        params(json.parseJSON);
    }

    static package RPCRequest fromJSONString(const char[] str) {
        assert(0, "fromJSONString not implemented.");
        /*
        auto json = str.parseJSON;
        if (json.type != JSON_TYPE.NULL && "id" in json && "params" in json) {
            return RPCResponse(json["id"].integer, json["params"]);
        } else {
            raise!(InvalidDataReceivedException, str)
                ("Response is missing 'id' and/or 'params' fields.");
            assert(0);
        }
        */
    }
}

@test("Test RPCRequest constructor.")
unittest {
    auto req1 = new RPCRequest(1, "some_method", `{ "arg1": "value1" }`);
    auto req2 = new RPCRequest(2, "some_method", `["abc", "def"]`);
    auto json = JSONValue([1, 2, 3]);
    auto req3 = new RPCRequest(3, "some_method", json);
    auto req4 = new RPCRequest(4, "some_method");
}

/** The RPC server's response sent to clients. */
struct RPCResponse {
    package:

    long _id;
    // Note: Only one of _result, _error will be present.
    JSONValue _result;
    Error _error;

    /** Construct a response to send to the client.

        Params:
            id =        The ID of this response. This matches the relevant
                        request.
            result =    The return value(s) of the method executed.
    */
    this(long id, JSONValue result) {
        _id = id;
        _result = result;
    }

    /** Construct an error response to send to the client.

        Params:
            id =    The ID of this response. This matches the relevant request.
            error = The error information to send.
    */
    this(long id, Error error) {
        _id = id;
        _error = error;
    }

    /** Construct a predefined error response to send to the client.

        An standard Error object matching the error code is constructed.

        Params:
            id =    The ID of this response. This matches the relevant request.
            error = The error information to send.
    */
    this(long id, ErrorCode error) {
        _id = id;
        _error = Error(error);
    }

    @property long id() { return _id; }

    public:

    /** The JSON-RPC protocol version. */
    @property string protocolVersion() { return "2.0"; }

    /** Standard error codes.

        Codes between -32768 and -32000 (inclusive) are reserved;
        application-specific codes may be defined outside that range.
    */
    enum ErrorCode : int {
        ParseError = -32700,
        InvalidRequest = -32600,
        MethodNotFound = -32601,
        InvalidParams = -32602,
        InternalError = -32603
        // -32000 to -32099 are reserved for implementation-defined server
        // errors.
    }

    /** An Error object returned by the server as a response to a bad request.
    */
    struct Error {
        private:

        int _errorCode;
        string _message;
        JSONValue _data;

        public:

        /** Retrieve the error code. */
        @property int errorCode() { return _errorCode; }

        /** Retrieve the error message. */
        @property string message() { return _message; }

        /** Retrieve the data related to the error. */
        @property JSONValue data() { return _data; }

        /** Construct an Error object to send to the RPC client.

            Params:
                errCode =   The error code to return to the client.
                msg     =   The error message that describes the error. For
                            standard error codes, leaving msg empty will use a
                            standard error message; for application error codes,
                            the message will be empty.
                errData =   Additional data related to the error to send to the
                            client.

        */
        this(int errCode, string msg = "", JSONValue errData = JSONValue()) {
            _errorCode = errCode;
            _data = errData;

            if (msg.length > 0) {
                _message = msg;
            } else {
                switch (errCode) {
                    case ErrorCode.ParseError:
                        _message = "An error occurred while parsing the JSON text.";
                        break;
                    case ErrorCode.InvalidRequest:
                        _message = "The JSON sent is not a valid Request object.";
                        break;
                    case ErrorCode.MethodNotFound:
                        _message = "The called method is not available.";
                        break;
                    case ErrorCode.InvalidParams:
                        _message = "The method was called with invalid parameters.";
                        break;
                    case ErrorCode.InternalError:
                        _message = "Internal server error.";
                        break;
                    default:
                        raise!(InvalidArgumentException, msg)
                                ("The message cannot be empty for application error codes.");
                }
            }
        }
    }

    /** Construct an RPCResponse from a JSON string.

        Params:
            str =   The string to convert to an RPCResponse object.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.

            InvalidDataReceivedException if the 'id' or 'result' field is missing.
    */
    static package RPCResponse fromJSONString(const char[] str) {
        auto json = str.parseJSON;
        // TODO: Parse error responses too.
        if (json.type != JSON_TYPE.NULL && "id" in json && "result" in json) {
            return RPCResponse(json["id"].integer, json["result"]);
        } else {
            raise!(InvalidDataReceivedException, str)
                ("Response is missing 'id' and/or 'result' fields.");
            assert(0);
        }
    }
}

/** Implementation of a JSON-RPC client.

    This implementation only supports communication via TCP sockets.

Params:
    API =   An interface containing the function definitions to call on the
            remote server.
*/
class RPCClient(API) if (is(API == interface)) {
    import jsonrpc.transport : RPCClientTransport, TCPClientTransport;

    private:

    long _nextId;
    ClientTransport _transport;

    public:

    /** Instantiate an RPCClient with the specified RPCClientTransport. */
    this(ClientTransport transport) {
        _transport = transport;
    }

    /** Instantiate an RPCClient bound to the specified host via a TCP connection.

        Params:
            host =  The hostname or address of the RPC server.
            port =  The port at which to connect to the server.
    */
    this(string host, ushort port) in {
        assert(host.length > 0);
    } body {
        _transport = new TCPClientTransport!(RPCRequest, RPCResponse)(host, port);
    }

    /** Make a blocking remote call with natural syntax.

        Any method (not part of the RPC client itself) that is present in
        the remote API can be called as if it was a member of the RPC client,
        and that function call will be forwarded to the remote server.

        Params:
            args = The arguments of the remote function to call.

        Returns:
            The return value of the function call.

        Throws:
            InvalidArgumentException if the argument types do not match the
            remote interface.

        Example:
            interface RemoteFuncs {
                void func1();
                int func2(bool b, string s);
            }

            auto rpc = new RPCClient!MyAPI("127.0.0.1", 54321);
            rpc.func1();
            int retval = rpc.func2(false, "hello");

        Notes:
            If you want the full response from the server, use the `call`
            function instead.
    */
    auto ref opDispatch(string apiFunc, ARGS...)(ARGS args) {
        import std.traits;
        static if (! hasMember!(API, apiFunc)) {
            raise!(InvalidArgumentException!(args)
                    ("Argument does not match the remote function interface."));
        }

        import std.conv : text;
        import std.meta : AliasSeq;
        import std.range : iota;

        mixin(
            "alias paramTypes = AliasSeq!(Parameters!(API."
            ~ apiFunc ~ "));\n" ~
            "alias paramNames = AliasSeq!(ParameterIdentifierTuple!(API."
            ~ apiFunc ~ "));\n" ~
            "alias returnType = ReturnType!(API." ~ apiFunc ~ ");\n"
        );

        auto jsonArgs = JSONValue();
        static foreach (i; iota(0, args.length)){
            assert(is(typeof(args[i]) == paramTypes[i]));

            mixin("jsonArgs[\"" ~ paramNames[i] ~ "\"] = JSONValue(args[" ~
                    i.text ~ "]);");
        }

        // TODO: Need to reconstruct arrays and AAs too.
        auto returnVal = call(apiFunc, jsonArgs)._result;
        static if (is(returnType: void)) {
            return;
        } else static if (isSigned!returnType) {
            return cast(returnType)returnVal.integer;
        } else static if (isUnsigned!returnType) {
            return cast(returnType)returnVal.uinteger;
        } else static if (isFloating!returnType) {
            return cast(returnType)returnVal.floating;
        } else static if (isSomeString!returnType) {
            return cast(returnType)returnVal.str;
        }
    }

    /** Make a function call on the RPC server.

        Params:
            func =   The name of the remote function to call.
            params = A valid JSON array or Object containing the function
                     parameters.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.

        Returns: The server's response.

        Example:
            interface MyAPI { void func(int val); }
            auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

            import std.json : JSONValue;
            auto resp = client.call("func", `{ "val": 3 }`.parseJSON);
            auto resp2 = client.call("func", JSONValue(3));
    */
    RPCResponse call(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        _transport.send(RPCRequest(_nextId, func, params));
        auto resp = _transport.receive(_nextId);
        ++_nextId;
        return resp;
    }

    /+
    /** Make a non-blocking remote function call.

        Use the returned request ID to obtain the server's response.

        Params:
            func =  The name of the remote function to call.
            params = A valid JSON array or Object containing the function
                     parameters.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.

        Returns: The ID of the request. This ID will be necessary to later
                 retrieve the server response.

        Example:
            interface MyAPI { void func(int val); }
            auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

            auto id = client.callAsync("func", `{ "val": 3 }`);
            RPCResponse resp;
            while (! client.response(id, resp)) { /+ wait for it... +/ }
            // Do something with resp here.
    */
    long callAsync(string func, string params) in {
        assert(func.length > 0);
    } body {
        return callAsync(func, params.parseJSON);
    }

    /// ditto
    long callAsync(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        auto req = RPCRequest(_nextId, func, params);
        _transport.send(req);
        ++_nextId;
        return req._id;
    }
    +/

    /+
    /** Check for a response from an asynchronous remote call.

        Params:
            id =       The ID of the request for which to check for a response.
            response = A RPCResponse object in which to return the response if
                       available.

        Returns: true if the response is ready; otherwise, false.
    */
    bool response(long id, out RPCResponse response) {
        return _transport.receiveAsync(id, response);
    }
    +/
}

/** Implementation of a JSON-RPC client.

    This implementation only supports communication via TCP sockets.

    Params:
        API =   A class or struct containing the functions available for the
                client to call.
*/
class RPCServer(API) {
    import std.socket;

    private:

    API _api;
    ServerTransport _transport;

    public:

    /** Construct an RPCServer!API object.

        api =       The instantiated class or struct providing the RPC API.
        transport = The network transport to use.
    */
    this(API api, ServerTransport transport) {
        _api = api;
        _transport = transport;
    }

    /** Construct an RPCServer!API object to communicate via TCP sockets.

        api =   The instantiated class or struct providing the RPC API.
        host =  The host interface on which to listen.
        port =  The port on which to listen.
    */
    this(API api, string host, ushort port) {
        this(api, new TCPServerTransport!(RPCRequest, RPCResponse)(host, port));
    }

    /** Listen for connections. */
    void listen(int maxQueuedConnections = 100) {
        _transport.listen(maxQueuedConnections);
    }

    RPCResponse executeMethod(RPCRequest) {
    }
}

    struct Client(REQ) {
        Socket socket;
        REQ[long] activeRequests;
    }

@test("[DOCTEST] Start an RPCServer.")
///
unittest {
    class MyAPI {
        bool f() { return true; }
    }

    auto server = new RPCServer!MyAPI(new MyAPI, "127.0.0.1", 54321);
    server.listen;
}

/** Remove all whitespace from a string. */
string removeWhitespace(const char[] input) {
    import std.array : appender;
    import std.uni : isWhite;

    auto str = appender!string;
    foreach (c; input) {
        if (! c.isWhite) str ~= c;
    }
    return str.data;
}

@test("removeWhitespace removes spaces, tabs, and newlines.")
unittest {
    auto one = "\ta\tb\t\tc\t";
    auto two = " . .  . ";
    auto three = "\na\n\n";
    auto four = "a \t \n  b";

    assert(one.removeWhitespace == "abc");
    assert(two.removeWhitespace == "...");
    assert(three.removeWhitespace == "a");
    assert(four.removeWhitespace == "ab");
}

/+
// TODO: Will hang without listening server.
@test("RPCClient example: client callAsync example passing params via JSON string.")
unittest {
    interface MyAPI { void func(int val); }
    auto sock = new FakeSocket;
    sock.receiveReturnValue = `{"id":3,"result":[1,2,3]}`;
    auto transport = new TCPClientTransport!(RPCRequest, RPCResponse)(sock);
    auto client = new RPCClient!MyAPI(transport);

    auto id = client.callAsync("func", `{ "val": 3 }`);
    RPCResponse resp;
    while (! client.response(id, resp)) { /* wait for it... */ }
    // Do something with resp here.
}
+/
/+
// TODO: Will hang without listening server.
@test("RPCClient example: client callAsync example passing params via JSONValue.")
unittest {
    interface MyAPI { void func(int val1, int val2, int val3); }
    auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

    auto id = client.callAsync("func", JSONValue([1 ,2, 3]));
    RPCResponse resp;
    while (! client.response(id, resp)) { /* wait for it... */ }
    // Do something with resp here.
}

@test("Test invalid data passed to RPCClient.params")
// TODO: Hangs without a listening server.
unittest {
    import std.exception : assertThrown;

    interface MyAPI { void func(int val); }
    auto client = new RPCClient!MyAPI("127.0.0.1", 54321);
    client.func(3); // Should be no problem.

    assertThrown!InvalidArgumentException(client.func(JSONValue(null)),
            "Null parameter should not have been accepted.");

    assertThrown!InvalidArgumentException(client.func(3),
            "Scalar paremeter should not have been accepted.");

    assertThrown!InvalidArgumentException(client.func("asdf"),
            "String parameter should not have been accepted.");

    assertThrown!InvalidArgumentException(client.callAsync("func", "asdf"),
            "String parameter should not have been accepted by callAsync.");
}
+/

@test("[DOCTEST] RPCClient example: opDispatch")
unittest {
    interface RemoteFuncs {
        void func1();
        int func2(bool b, string s);
    }

    class Funcs : RemoteFuncs {
        void func1() { return; }
        int func2(bool b, string s) { return 3; }
    }

    auto transport = new FakeTransport;
    transport.fakedResponses[0] = RPCResponse(0, JSONValue());
    transport.fakedResponses[1] = RPCResponse(1, JSONValue(3));
    auto rpc = new RPCClient!RemoteFuncs(transport);

    rpc.func1;
    assert(rpc.func2(false, "hello") == 3);
}

@test("[DOCTEST] RPCClient example: call")
unittest {
    interface MyAPI { void func(int val); }
    auto transport = new FakeTransport;
    transport.fakedResponses[0] = RPCResponse(0, JSONValue());
    transport.fakedResponses[1] = RPCResponse(1, JSONValue());
    auto client = new RPCClient!MyAPI(transport);

    import std.json : JSONValue;
    auto resp = client.call("func", `{ "val": 3 }`.parseJSON);
    auto resp2 = client.call("func", JSONValue(3));
}
