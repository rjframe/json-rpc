/** JSON-RPC 2.0 protocol library.

    The JSON-RPC 2.0 specification may be found at
    $(LINK http&#58;//www.jsonrpc.org/specification)
*/
module jsonrpc.jsonrpc;

import std.json;
import jsonrpc.exception;

version(Have_tested) import tested : test = name;
else private struct test { string name; }

/** An RPC request constructed by the client to send to the RPC server. */
struct RPCRequest {
    import jsonrpc.transport;

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
            InvalidParameterException if the json string is not a JSON Object or
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
            InvalidParameterException if the json string is not a JSON Object or
            array.
    */
    this(long id, string method, JSONValue params = JSONValue()) in {
        assert(method.length > 0);
    } body {
        this.method = method;
        this.params = params;
    }

    string toJSON() {
        assert(0, "toJSON not implemented.");
    }

    public:

    /** The JSON-RPC protocol version. */
    @property string protocolVersion() { return "2.0"; }

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
            InvalidParameterException if val is not a JSON Object or array.
    */
    @property void params(JSONValue val)
    {
        // We consider null to be equivalent to an empty object.
        if (val.type != JSON_TYPE.OBJECT && val.type != JSON_TYPE.ARRAY
                && val.type != JSON_TYPE.NULL) {
            raise!(InvalidParameterException, val)
                    ("Invalid JSON-RPC method parameter type.");
        }
        _params = val;
    }

    /** Set the parameters to the remote method as a JSON string.

        The string must be a JSON Object or array.

        Params:
            json =   A JSON string.

        Throws:
            InvalidParameterException if the json string is not a JSON Object or
            array.

            std.json.JSONException if the json string cannot be parsed.
    */
    @property void params(string json) in {
        assert(json.length > 0);
    } body {
        params(json.parseJSON);
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
    private:

    // Note: Only one of _result, _error will be present.
    long _id;
    JSONValue _result;

    package:

    Error _error;

    /** Construct a response to send to the client. */
    this(long id, JSONValue result) {
        _id = id;
        _result = result;
    }

    /** Construct an error response to send to the client. */
    this(long id, Error error) {
        _id = id;
        _error = error;
    }

    /** Construct a predefined error response to send to the client. */
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

        @property int errorCode() { return _errorCode; }
        @property string message() { return _message; }
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
}

/** Implementation of a JSON-RPC client.

    This implementation only supports communication via TCP sockets.

Params:
    API =   An interface containing the function definitions to call on the
            remote server.
*/
class RPCClient(API) if (is(API == interface)) {
    private:

    int _nextId;
    // List of received but unused responses when making async calls.
    RPCClientTransport _transport;

    public:

    /** Instantiate an RPCClient with the specified RPCClientTransport. */
    this(RPCClientTransport transport) {
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
        _transport = new TCPRPCClientTransport(host, port);
    }

    /** Make a non-blocking remote call with natural syntax.

        Any function (not present on the RPC client itself) that is present in
        the remote API can be called as if it was a member of the RPC client,
        and that function call will be forwarded to the remote server.

        Params:
            args = The arguments of the remote function to call.

        Throws:
            InvalidArgumentException if the argument types do not match the
            remote interface.
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
            ~ apiFunc ~ "));\n"
        );

        auto jsonArgs = JSONValue();
        static foreach (i; iota(0, args.length)){
            assert(is(typeof(args[i]) == paramTypes[i]));

            mixin("jsonArgs[\"" ~ paramNames[i] ~ "\"] = JSONValue(args[" ~
                    i.text ~ "]);");
        }
        return callAsync(apiFunc, jsonArgs);
    }

    /+ TODO: ParameterIdentifierTuple - Get!2 recursive expansion for call to
       `a` when this is in the RPCCLient. Outside the class template this isn't
       a problem.

    @test("Doctest: Remote function call syntax builds properly.")
    // Note: opDispatch is not called, so we're not testing that function.
    // Without doStuff, we would need a listening server for the test to pass;
    // I don't want to document all of that here.
    ///
    unittest {
        interface MyAPI {
            bool x(int y);
            void a(bool b, int c, string d);
            int i();
        }

        void doStuff() {
            auto client = new RPCClient!MyAPI("127.0.0.1", 54321);
            client.a(true, 2, "somestring");
            client.x(3);
            auto resp = client.i;
        }
    }
    +/

    /** Make a blocking remote function call.

        Params:
            func =   The name of the remote function to call.
            params = A valid JSON array or Object containing the function
                     parameters.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.

        Returns: The server's response.
    */
    RPCResponse call(string func, string params) in {
        assert(func.length > 0);
    } body {
        return call(func, params.parseJSON);
    }

    @test("Doctest: client call example passing params via JSON string.")
    // TODO: Will fail without listening server.
    ///
    unittest {
        interface MyAPI { void func(int val); }
        auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

        auto resp = client.call("func", `{ "val": 3 }`);
    }

    /// ditto
    RPCResponse call(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        auto id = callAsync(func, params);
        RPCResponse resp;
        while(! response(id, resp)) {}
        return resp;
    }

    // TODO: Will fail without listening server.
    @test("Doctest: client call example passing params via JSONValue.")
    ///
    unittest {
        interface MyAPI { void func(int val1, int val2, int val3); }
        auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

        auto resp = client.call("func", JSONValue([1 ,2, 3]));
    }

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
    */
    int callAsync(string func, string params) in {
        assert(func.length > 0);
    } body {
        return callAsync(func, params.parseJSON);
    }

    // TODO: Will fail without listening server.
    @test("Doctest: client callAsync example passing params via JSON string.")
    ///
    unittest {
        interface MyAPI { void func(int val); }
        auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

        auto id = client.callAsync("func", `{ "val": 3 }`);
        RPCResponse resp;
        while (! client.response(id, resp)) { /* wait for it... */ }
        // Do something with resp here.
    }

    /// ditto
    int callAsync(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        auto req = new RPCRequest(_nextId, func, params);
        _transport.send(req);
        ++_nextId;
        return req.id;
    }


    // TODO: Will fail without listening server.
    @test("Doctest: client callAsync example passing params via JSONValue.")
    ///
    unittest {
        interface MyAPI { void func(int val1, int val2, int val3); }
        auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

        auto id = client.callAsync("func", JSONValue([1 ,2, 3]));
        RPCResponse resp;
        while (! client.response(id, resp)) { /* wait for it... */ }
        // Do something with resp here.
    }

    /** Check for a response from an asynchronous remote call.

        Params:
            id =       The ID of the request for which to check for a response.
            response = A RPCResponse object in which to return the response if
                       available.

        Returns: true if the response is ready; otherwise, false.
    */
    bool response(long id, out RPCResponse response) {
        return _transport.receive(id, response);
    }
}

/+ TODO: We're running out of memory now trying to build this.
@test("[not complete] RPCClient.opDispatch forwards calls to the server.")
// TODO: I need to mock (reqs a new constructor) a server so we can actually
// test opDispatch here.
unittest {
    interface MyAPI {
        bool x(int y);
        void a(bool b, int c, string d);
        int i();
    }

    auto client = new RPCClient!MyAPI("127.0.0.1", 54321);
    client.a(true, 2, "somestring");
    client.x(3);
    auto resp = client.i;
}
+/

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
    RCPServerTransport _transport;

    public:

    /** Construct an RPCServer!API object.

        api =       The instantiated class or struct providing the RPC API.
        transport = The network transport to use.
    */
    this(API api, RPCServerTransport transport) {
        _api = api;
        _transport = transport;
    }

    /** Construct an RPCServer!API object to communicate via TCP sockets.

        api =   The instantiated class or struct providing the RPC API.
        host =  The host interface on which to listen.
        port =  The port on which to listen.
    */
    this(API api, string host, ushort port) {
        this(api, new TCPServerTransport(host, port));
    }

    /** Listen for connections.

        Params:
    */
    void listen() { _transport.listen; }
}

/+
@test("Doctest: Start an RPCServer.")
///
unittest {
    class MyAPI {
        bool f() { return true; }
    }

    auto server = new RPCServer!MyAPI(new MyAPI);
    server.listen("127.0.0.1", 54321);
}
+/
