/** JSON-RPC 2.0 protocol library.

    The JSON-RPC 2.0 specification may be found at
    $(LINK http&#58;//www.jsonrpc.org/specification)
*/
module jsonrpc.jsonrpc;

import std.json;
import std.socket;

import jsonrpc.exception;

version(Have_tested) import tested : test = name;
else private struct test { string name; }

private enum SocketBufSize = 4096;

/** An RPC request constructed by the client to send to the RPC server.

    The RPCRequest contains the ID of the request, the method to call, and any
    parameters to pass to the method. You should not need to manually create an
    RPCRequest object; the RPCClient will do this for you.
*/
struct RPCRequest {
    import std.typecons : Flag, Yes, No;

    private JSONValue _data;

    package:

    @test("Test RPCRequest constructors.")
    unittest {
        auto req1 = new RPCRequest(1, "some_method", `{ "arg1": "value1" }`);
        auto req2 = new RPCRequest(2, "some_method", `["abc", "def"]`);
        auto req3 = new RPCRequest(2, "some_method", JSONValue(123));
        auto json = JSONValue([1, 2, 3]);
        auto req4 = new RPCRequest(3, "some_method", json);
        auto req5 = new RPCRequest(4, "some_method");
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
        this._data["jsonrpc"] = "2.0";
        this._data["id"] = id;
        this._data["method"] = method;
        this.params = params;
    }

    /** Convert the RPCRequest to a JSON string to pass to the server.

        Params:
            prettyPrint = Yes to pretty-print the JSON output; No for efficient
                          output.
    */
    string toJSONString(Flag!"prettyPrint" prettyPrint = No.prettyPrint) {
        return _data.toJSON(prettyPrint);
    }

    public:

    /** Get the JSON-RPC protocol version. */
    @property string protocolVersion() { return _data["jsonrpc"].str; }

    /** Get the ID of this request. */
    @property long id() { return _data["id"].integer; }

    /** Retrieve the method to execute on the RPC server. */
    @property string method() { return _data["method"].str; }

    /** Specify the method to execute on the RPC server. */
    @property void method(string val) { _data["method"] = val; }

    /** Retrieve the parameters that will be passed to the method. */
    @property JSONValue params() { return _data["params"]; }

    /** Set the parameters to the remote method that will be called.

        Params:
            val =   A JSON Object or array. Other value types will be wrapped
                    in an array (e.g., 3 becomes [3]).
    */
    @property void params(JSONValue val)
    {
        if (val.type != JSON_TYPE.OBJECT && val.type != JSON_TYPE.ARRAY
                && val.type != JSON_TYPE.NULL) {
            _data["params"] = JSONValue([val]);
        } else _data["params"] = val;
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

    /** Parse a JSON string into an RPCRequest object.

        Params:
            str =   The JSON string to parse.

        Throws:
            InvalidDataReceivedException if the ID or method fields are missing.

            JSONException if the ID or method fields are an incorrect type. The
            ID must be integral (non-conformant to the JSON-RPC spec) and the
            method must be a string.
    */
    static package RPCRequest fromJSONString(const char[] str) {
        auto json = str.parseJSON;
        if (json.type != JSON_TYPE.NULL
                && "id" in json && "method" in json
                && "jsonrpc" in json && json["jsonrpc"].str == "2.0") {
            if ("params" !in json) json["params"] = JSONValue();

            return RPCRequest(
                    json["id"].integer,
                    json["method"].str,
                    json["params"]);
        } else {
            raise!(InvalidDataReceivedException, str)
                ("Response is missing 'jsonrpc', 'id', and/or 'method' fields.");
            assert(0);
        }
    }

    @test("fromJSONString converts JSON to RPCRequest")
    unittest {
        auto req = RPCRequest.fromJSONString(
                `{"jsonrpc": "2.0", "id": 0, "method": "func", "params": [0, 1]}`);
        assert(req.id == 0, "Incorrect ID.");
        assert(req.method == "func", "Incorrect method.");
        assert(req.params.array == [JSONValue(0), JSONValue(1)],
                "Incorrect params.");
    }

    @test("fromJSONString throws exception on invalid input")
    unittest {
        import std.exception : assertThrown;
        assertThrown!InvalidDataReceivedException(
                RPCRequest.fromJSONString(
                    `{"jsonrpc": "2.0", "method": "func", "params": [0, 1]}`));

        assertThrown!InvalidDataReceivedException(
                RPCRequest.fromJSONString(
                    `{"id": 0, "method": "func", "params": [0, 1]}`));

        assertThrown!InvalidDataReceivedException(
                RPCRequest.fromJSONString(
                    `{"jsonrpc": "2.0", "id": 0, "params": [0, 1]}`));

        assertThrown!JSONException(
                RPCRequest.fromJSONString(
                    `{"jsonrpc": "2.0", "id": "0", "method": "func", "params": [0, 1]}`));
    }
}

/** The RPC server's response sent to clients. */
struct RPCResponse {

    /** Construct an RPC response by taking a JSONValue response.

        Params:
            data =  The JSONValue data that comprises the response. It must be a
                    valid JSON-RPC 2.0 response.
    */
    private this(JSONValue data) in {
        assert("jsonrpc" in data && "id" in data
                && ("result" in data).xor("error" in data),
                "Malformed response: missing required field(s).");
    } do {
        _data = data;
    }

    package:

    // Note: Only one of result, _error will be present.
    JSONValue _data;
    Error _error; // TODO: This will be removed and placed in _data.

    /** Construct a response to send to the client.

        Params:
            id =        The ID of this response. This matches the relevant
                        request.
            result =    The return value(s) of the method executed.
    */
    this(long id, JSONValue result) {
        _data["jsonrpc"] = "2.0";
        _data["id"] = id;
        _data["result"] = result;
    }

    this(long id) {
        _data["jsonrpc"] = "2.0";
        _data["id"] = id;
    }

    /** Attach an Error to an RPCResponse.

        Example:
            auto resp = RPCResponse(0).withError(myError);
    */
    static ref RPCResponse withError(ref RPCResponse, Error error) {
        assert(0);
    }

    /** Attach an Error to an RPCResponse.

        Example:
            auto resp = RPCResponse(0).withError(ErrorCode.InvalidRequest);
    */
    static ref RPCResponse withError(ref RPCResponse, ErrorCode error) {
        assert(0);
    }

    /** Construct a predefined error response to send to the client.

        An standard Error object matching the error code is constructed.

        Params:
            id =    The ID of this response. This matches the relevant request.
            error = The error information to send.
    */
    this(long id, ErrorCode error) {
        _data["jsonrpc"] = "2.0";
        _data["id"] = id;
        _error = Error(error);
    }

    @property long id() { return _data["id"].integer; }

    public:

    /** The JSON-RPC protocol version. */
    @property string protocolVersion() { return _data["jsonrpc"].str; }

    // TODO: I want to implicitly unwrap scalar values.
    @property JSONValue result() { return _data["result"]; }

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

        // TODO: Place _errorCode and _message into _data.
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
        if (json.type != JSON_TYPE.NULL
                && "id" in json
                && ("result" in json).xor("error" in json)
                && "jsonrpc" in json && json["jsonrpc"].str == "2.0") {
            return RPCResponse(json);
        } else {
            raise!(InvalidDataReceivedException, json, str)
                ("JSON Response is missing required fields.");
            assert(0);
        }
    }

    /** Convert the RPCResponse to a JSON string to send to the client. */
    string toJSONString() {
        import std.format : format;
        string ret =
`{
    "jsonrpc": "%s",
    "result": %s,
    "id": %s`.format(protocolVersion, result, id);
        ret ~= "\n}";

        return ret;
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

    long _nextId;
    Socket _socket;

    /** Instantiate an RPCClient with the specified Socket.

        The socket will be set to non-blocking. This is designed for testing.
    */
    this(Socket socket) {
        socket.blocking = true;
        _socket = socket;
    }

    public:

    /** Instantiate an RPCClient bound to the specified host via a TCP connection.

        Params:
            host =  The hostname or address of the RPC server.
            port =  The port at which to connect to the server.
    */
    this(string host, ushort port) in {
        assert(host.length > 0);
    } body {
        this(new TcpSocket(getAddress(host, port)[0]));
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

        mixin(
            "alias paramTypes = AliasSeq!(Parameters!(API."
                    ~ apiFunc ~ "));\n" ~
            "alias paramNames = AliasSeq!(ParameterIdentifierTuple!(API."
                    ~ apiFunc ~ "));\n" ~
            "alias returnType = ReturnType!(API." ~ apiFunc ~ ");\n"
        );

        auto jsonArgs = JSONValue();
        static foreach (i; 0..args.length) {
            assert(is(typeof(args[i]) == paramTypes[i]));

            mixin("jsonArgs[\"" ~ paramNames[i] ~ "\"] = JSONValue(args[" ~
                    i.text ~ "]);\n");
        }

        // TODO: Need to reconstruct arrays and AAs too.
        auto returnVal = call(apiFunc, jsonArgs).result;
        static if (is(returnType: void)) {
            return;
        } else return unwrapValue!(returnType)(returnVal);
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
    // TODO: Include an optional timeout.
    RPCResponse call(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        import core.thread : Thread;
        import core.time : dur;

        auto req = RPCRequest(_nextId++, func, params);
        auto data = req.toJSONString();

        ptrdiff_t bytesSent = 0;
        while (bytesSent < data.length) {
            auto sent = _socket.send(data[bytesSent..$]);
            if (sent == Socket.ERROR || sent == 0) break;
            bytesSent += sent;
        }

        auto respObj = receiveJSONObject(_socket);
        return RPCResponse.fromJSONString(respObj);
    }
}

/** Implementation of a JSON-RPC server.

    This implementation only supports communication via TCP sockets.

    Params:
        API =   A class or struct containing the functions available for the
                client to call.
*/
class RPCServer(API) {
    import std.socket;

    private:

    API _api;
    Socket _listener;

    /** Construct an RPCServer!API object.

        api =       The instantiated class or struct providing the RPC API.
        transport = The network transport to use.
    */
    this(API api, Socket socket, string host, ushort port) {
        _api = api;
        _listener = socket;
        _listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        _listener.blocking = true;
        _listener.bind(getAddress(host, port)[0]);
        // TODO: This should be an exception.
        assert(_listener.isAlive, "Listening socket not active.");
    }

    public:

    /** Construct an RPCServer!API object to communicate via TCP sockets.

        The API must be constructable via a default constructor; if you need to
        use an alternate constructor, create it first and pass it to the
        RPCServer via a `this` overload.

        host =  The host interface on which to listen.
        port =  The port on which to listen.
    */
    this(string host, ushort port) {
        this(new API(), new TcpSocket, host, port);
    }

    /** Construct an RPCServer!API object to communicate via TCP sockets.

        api =   The instantiated class or struct providing the RPC API.
        host =  The host interface on which to listen.
        port =  The port on which to listen.
    */
    this(API api, string host, ushort port) {
        this(api, new TcpSocket, host, port);
    }

    /** Listen for and respond to connections. */
    void listen(int maxQueuedConnections = 10) {
        import std.parallelism : task;

        _listener.listen(maxQueuedConnections);
        while (true) {
            auto conn = _listener.accept;
            task!handleClient(conn, _api).executeInNewThread;
        }
    }
}

/** Handles all of an individual client's requests.

    The `listen` method of the RPCServer calls this in a new thread to handle
    client requests. This is not intended to be called by user code.
*/
void handleClient(API)(Socket client, API api) {
    // TODO: On error, close the socket.
    while (true) {
        auto req = RPCRequest.fromJSONString(receiveJSONObject(client));
        executeMethod(req, api).sendResponse(client);
    }
    //client.shutdown(SocketShutdown.BOTH);
    //client.close;
}

/** Execute an RPC method and return the server's response.

    Only public members of the API object are callable as a remote function.

    Params:
        request =   The request from the client.
        api =       The class or struct containing the function to call.
*/
RPCResponse executeMethod(API)(RPCRequest request, API api) {
    import std.traits : isFunction;
    foreach(method; __traits(derivedMembers, API)) {
        mixin(
            "enum isMethodAPublicFunction =\n" ~
            "   isFunction!(api." ~ method ~ ") &&\n" ~
            "   __traits(getProtection, api." ~ method ~ ") == `public`;\n"
        );
        static if (isMethodAPublicFunction) {
            if (method == request.method) {
                auto retval = execRPCMethod!(API, method)(request, api);
                return RPCResponse(request.id, JSONValue(retval));
            }
        }
    }
    assert(0, "executeMethod should never reach the end of the function.");
}

/** Execute an RPC method and return its result.

    For now, void methods return `true`.
*/
private auto execRPCMethod(API, string method)(RPCRequest request, API api) {
    import std.traits : ReturnType;
    mixin(
        "enum returnType = typeid(ReturnType!(API." ~ method ~ "));\n" ~
        GenCaller!(API, method)
    );

    static if((returnType is typeid(void))) {
        callRPCFunc!(method, JSONValue)(api, request.params);
        // TODO: What should I do here?
        return true;
    } else {
        return callRPCFunc!(method, JSONValue)(api, request.params);
    }
    // TODO: I'm hitting this when the called method doesn't exist. I either need
    // to validate before we get here, or throw an exception with an accurate
    // message.
    assert(0, "Should have returned by now.");
}

/** Generate the function `callRPCFunc` that will call the API function
    specified by the client and return its return value, if present.

    Parameters are provided as a JSONValue array or Object; Objects will be
    converted to arrays.

    Example:
    ---
    mixin(GenCaller!(API, method));
    auto retval = callRPCFunc!(method, JSONValue)(api, request.params);
    ---
*/
private static string GenCaller(API, string method)() pure {
    import std.conv : text;
    import std.meta : AliasSeq;
    import std.traits : Parameters, ParameterIdentifierTuple, ReturnType;

    mixin(
        "alias paramNames = AliasSeq!(ParameterIdentifierTuple!(API."
                ~ method ~ "));\n"
      ~ "alias paramTypes = AliasSeq!(Parameters!(API." ~ method ~ "));\n"
      ~ "\nenum returnType = typeid(ReturnType!(API." ~ method ~ "));\n"
     );

    // TODO: Validate against API - if a named param is passed that isn't on the
    // method we need to return an error response. See execRPCMethod.
    // TODO: The assertion probably needs to be an exception.
    string func =
            "\nauto ref callRPCFunc(string method, ARGS)(API api, ARGS args) {\n"
        ~ "    JSONValue vals = args;\n"
        ~ "    if (args.type == JSON_TYPE.NULL) { \n"
        ~ "        vals = JSONValue(`[]`.parseJSON);\n"
        ~ "    } else if (args.type == JSON_TYPE.OBJECT) {\n"
        ~ "        vals = JSONValue(`[]`.parseJSON);\n";

    // Size the array to fit our data.
    static foreach(i; 0..paramTypes.length) {
        func ~=
          "        vals.array ~= JSONValue();\n";
    }

    func ~=
          "        foreach (string key, val; args) {\n";

    static foreach(i; 0..paramTypes.length) {
        func ~=
          "            if (key == " ~ paramNames[i].stringof ~ ") "
        ~ "                vals[" ~ i.text ~ "] = val;\n";
    }

    func ~=
          "        }\n" // foreach (key, val)
        ~ "    }\n" // if (JSON_TYPE.OBJECT)

        ~ "    assert(vals.array.length == " ~ paramTypes.length.text ~ ");\n";

    static if (returnType !is typeid(void)) {
        static if (returnType is typeid(bool)) {
            func ~= ("    return cast(bool)");
        } else {
            func ~= ("    return ");
        }
    } else func ~= "    ";

    func ~= "api." ~ method ~ "(";

    static if (paramTypes.length > 0) {
        static foreach(i; 0..paramTypes.length) {
            func ~=
                "vals[" ~ i.text ~ "].unwrapValue!" ~ paramTypes[i].stringof ~ ", ";
        }
    }
    func ~= ");\n}\n";

    return func;
}

/** Unwrap a scalar value from a JSONValue object. */
private auto unwrapValue(T)(JSONValue value) pure {
    import std.traits;
    static if (isFloatingPoint!T) {
        return cast(T)value.floating;
    } else static if (isSomeString!T) {
        return cast(T)value.str;
    } else static if (isSigned!T) {
        return cast(T)value.integer;
    } else static if (isUnsigned!T) {
        // TODO: There has to be a better way to do all of this.
        // Positive signed values will take this branc, rather than the
        // isSigned! branch.
        try {
            return cast(T)value.uinteger;
        } catch (JSONException e) {
            return cast(T)value.integer;
        }
    } else static if (isBoolean!T) {
        if (value.type == JSON_TYPE.TRUE) return true;
        if (value.type == JSON_TYPE.FALSE) return false;
        // TODO: Make this an exception.
        assert(0, "Expected boolean, but type is " ~ value.type);
    }
    // TODO: make this an exception.
    assert(0, "Non-scalar value cannot be unwrapped.");
}

@test("unwrapValue retrieves scalar values from a JSONValue")
///
unittest {
    auto a = JSONValue("a");
    auto b = JSONValue(2);
    auto c = JSONValue(2u);
    auto d = JSONValue(2.3);
    auto e = JSONValue(true);

    assert(a.unwrapValue!string == "a");
    assert(b.unwrapValue!int == 2);
    assert(c.unwrapValue!uint == 2u);
    auto fl = d.unwrapValue!float;
    assert(fl > 2.2 && fl < 2.4);
    assert(e.unwrapValue!bool == true);
}

private bool xor(T)(T left, T right) {
    return left != right;
}

@test("xor is correct.")
unittest {
    assert(true.xor(false));
    assert(false.xor(true));
    assert(! true.xor(true));
    assert(! false.xor(false));
}

version(unittest) {
    class MyAPI {
        bool voidFunc_called = false;
        bool void3params_called = false;
        bool voidArray_called = false;
        bool voidWithString_called = false;

        private void dontCallThis() {
            throw new Exception("Private members should not be callable.");
        }

        bool retBool() { return true; }
        alias retTrue = retBool;
        bool retFalse() { return false; }

        ulong retUlong(string s) { return ("abc and " ~ s).length; }

        int retInt(int i) { return i+1; }

        void voidFunc() { voidFunc_called = true; }
        void void3params(int a, bool b, float c) { void3params_called = true; }
        void voidArray(int a, int b) { voidArray_called = true; }
        void voidWithString(string s) { voidWithString_called = true; }

        string retString() { return "testing"; }
    }
}

@test("execRPCMethod executes void RPC functions")
unittest {
    auto sock = new FakeSocket;
    auto api = new MyAPI();

    auto r1 = execRPCMethod!(MyAPI, "void3params")
            (RPCRequest(0, "void3params",
                JSONValue(`{"a": 3, "b": false, "c": 2.3}`.parseJSON)),
                api);
    auto r2 = execRPCMethod!(MyAPI, "voidArray")
            (RPCRequest(1, "voidArray", JSONValue([1, 2])), api);
    auto r3 = execRPCMethod!(MyAPI, "voidFunc")
            (RPCRequest(2, "voidFunc"), api);

    assert(r1 == true && r2 == true && r3 == true);
    assert(api.void3params_called == true
            && api.voidArray_called == true
            && api.voidFunc_called == true);
}

@test("execRPCMethod executes non-void RPC functions")
unittest {
    auto sock = new FakeSocket;
    auto api = new MyAPI();

    auto r1 = execRPCMethod!(MyAPI, "retBool")
            (RPCRequest(0, "retBool"), api);
    assert(r1 == true);

    auto r2 = execRPCMethod!(MyAPI, "retUlong")
            (RPCRequest(1, "retUlong", JSONValue("some string")), api);
    assert(r2 == 19);
}

@test("executeMethod returns integral values")
unittest {
    auto sock = new FakeSocket;
    auto api = new MyAPI();

    auto r1 = executeMethod(RPCRequest(0, "retUlong",
            JSONValue("some string")), api);
    assert(r1.id == 0);
    assert(r1.result.unwrapValue!ulong == 19);

    auto r2 = executeMethod(RPCRequest(1, "retInt", JSONValue(5)), api);
    assert(r2.id == 1);
    assert(r2.result.integer == 6);
}

@test("executeMethod returns boolean values")
unittest {
    auto sock = new FakeSocket;
    auto api = new MyAPI();

    auto r1 = executeMethod(RPCRequest(0, "retTrue"), api);
    assert(r1.id == 0);
    assert(r1.result == JSONValue(true));

    auto r2 = executeMethod(RPCRequest(1, "retFalse"), api);
    assert(r2.id == 1);
    assert(r2.result == JSONValue(false));
}

@test("executeMethod returns string values")
unittest {
    auto sock = new FakeSocket;
    auto api = new MyAPI();

    auto r1 = executeMethod(RPCRequest(0, "retString"), api);
    assert(r1.result.unwrapValue!string == "testing");
}

private:

void sendResponse(RPCResponse response, Socket socket) {
    socket.send(response.toJSONString);
}

char[] receiveJSONObject(Socket socket) {
    char[SocketBufSize] buf;
    char[] data;
    ptrdiff_t receivedBytes = 0;

    receivedBytes = socket.receive(buf);
    if (receivedBytes <= 0) { return data; } // TODO: Throw on no input data?

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

        // If we receive an incomplete object, get more data and repeat as needed.
        if (braceCount > 0) {
            receivedBytes = socket.receive(buf);
            if (receivedBytes > 0) {
                data ~= buf[0..receivedBytes].dup;
            }
        } else return data;
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

    auto sock = new FakeSocket;
    auto rpc = new RPCClient!RemoteFuncs(sock);

    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":0,"result":null}`;
    rpc.func1;
    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":1,"result":3}`;
    assert(rpc.func2(false, "hello") == 3);
}

@test("[DOCTEST] RPCClient example: call")
unittest {
    interface MyAPI { void func(int val); }
    auto sock = new FakeSocket;
    auto client = new RPCClient!MyAPI(sock);

    import std.json : JSONValue;
    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":0,"result":null}`;
    auto resp = client.call("func", `{ "val": 3 }`.parseJSON);
    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":1,"result":null}`;
    auto resp2 = client.call("func", JSONValue(3));
}
