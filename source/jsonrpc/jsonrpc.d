/** JSON-RPC 2.0 protocol library.

    The JSON-RPC 2.0 specification may be found at
    $(LINK http&#58;//www.jsonrpc.org/specification)

    Example:
    --------------------------------------------
    enum hostname = "127.0.0.1";
    enum ushort port = 54321;

    interface API {
        long add(int a, int b);
    }

    class ServeFunctions {
        long add(int a, int b) { return a + b; }
    }

    void main(string[] args)
    {
        import core.thread : Thread;
        import core.time : dur;

        auto t = new Thread({
            auto rpc = new RPCServer!ServeFunctions(hostname, port);
            rpc.listen();
        });
        t.isDaemon = true;
        t.start();
        Thread.sleep(dur!"seconds"(2));

        auto client = new RPCClient!API(hostname, port);
        assert(client.add(2, 2) == 4);
        assert(client.add(5, 6) == 11);
    }
    --------------------------------------------

    Authors:
        Ryan Frame

    Copyright:
        Copyright 2018 Ryan Frame

    License:
        MIT
 */
module jsonrpc.jsonrpc;

import std.json;
import std.socket;

import jsonrpc.transport;
import jsonrpc.exception;

version(Have_tested) import tested : test = name;
else private struct test { string name; }

/** An RPC request constructed by the client to send to the RPC server.

    The RPCRequest contains the ID of the request, the method to call, and any
    parameters to pass to the method. You should not need to manually create an
    RPCRequest object; the RPCClient will do this for you.
*/
struct RPCRequest {
    import std.traits;
    import std.typecons : Flag, Yes, No;

    /** Construct an RPCRequest with the specified remote method name and
        arguments.

        The ID must be a string, a number, or null; null is not recommended for
        use as an ID.

        Template_Parameters:
            T = The type of the request ID.

        Params:
            id =        The ID of the request.
            method =    The name of the remote method to call.
            params =    A JSON string containing the method arguments as a JSON
                        Object or array.

        Throws:
            InvalidArgument if the json string is not a JSON Object or
            array.
    */
    this(T = long)(T id, string method, JSONValue params = JSONValue())
            if (isNumeric!T || isSomeString!T || is(T : typeof(null)))
    in {
        assert(method.length > 0);
    } body {
        this._data["jsonrpc"] = "2.0";
        this._data["id"] = id;
        this._data["method"] = method;
        this.params = params;
    }

    /** Construct a notification with the specified remote method name and
        arguments.

        A notification will receive no response from the server.

        Params:
            method =    The name of the remote method to call.
            params =    A JSON string containing the method arguments as a JSON
                        Object or array.

        Throws:
            InvalidArgument if the json string is not a JSON Object or
            array.
    */
    this(string method, JSONValue params = JSONValue()) in {
        assert(method.length > 0);
    } body {
        this._isNotification = true;
        this._data["jsonrpc"] = "2.0";
        this._data["method"] = method;
        this.params = params;
    }

    /** Get the JSON-RPC protocol version. */
    @property string protocolVersion() { return _data["jsonrpc"].str; }

    /** Get the ID of this request.

        If the ID is not of type long, it needs to be specified; if uncertain of
        the underlying type, use idType to query for it.

        There is no ID for notifications.

        Template_Parameters:
            T = The type of the ID; the default type is `long`, but JSON-RPC
                allows IDs to also be string or typeof(null).

        See_Also:
            idType

        Throws:
            IncorrectType if the underlying type of the ID is not the requested
            type.

            IncorrectType if this request is a notification.
    */
    @property auto id(T = long)() {
        if (this.isNotification) {
            raise!(IncorrectType)("There is no ID in a notification.");
        }
        scope(failure) {
            raise!(IncorrectType)("The ID is not of the specified type.");
        }
        return unwrapValue!T(_data["id"]);
    }

    @test("RPCRequest string id can be created and read.")
    unittest {
        import std.exception : assertThrown;

        auto req = RPCRequest("my_id", "func", JSONValue(["params"]));
        assert(req.id!string == "my_id");
        assertThrown!IncorrectType(req.id!int);
    }

    @test("RPCRequest null id can be created and read.")
    unittest {
        auto req = RPCRequest(null, "func", JSONValue(["params"]));
        assert(req.id!(typeof(null)) is null);
    }

    /** Get the type of the underlying ID. There is no type for notifications.

        See_Also:
            id

        Throws:
            IncorrectType if this request is a notification.
    */
    @property JSON_TYPE idType() {
        if (this.isNotification) {
            raise!(IncorrectType)("There is no ID in a notification.");
        }
        return _data["id"].type;
    }

    /** Return true if this request is a notification; otherwise, return false.
    */
    @property bool isNotification() { return _isNotification; }

    /** Retrieve the method to execute on the RPC server. */
    @property string method() { return _data["method"].str; }

    /** Retrieve the parameters that will be passed to the method. */
    @property JSONValue params() { return _data["params"]; }

    package:

    /** Parse a JSON string into an RPCRequest object.

        Params:
            str =   The JSON string to parse.

        Throws:
            InvalidDataReceived if the ID or method fields are missing.

            JSONException if the ID or method fields are an incorrect type. The
            ID must be integral (non-conformant to the JSON-RPC spec) and the
            method must be a string.
    */
    static RPCRequest fromJSONString(const char[] str) {
        auto json = str.parseJSON;
        if (json.type != JSON_TYPE.NULL
                && "method" in json
                && "jsonrpc" in json && json["jsonrpc"].str == "2.0") {
            if ("params" !in json) json["params"] = JSONValue();

            if ("id" in json) {
                return RPCRequest(
                        json["id"].integer,
                        json["method"].str,
                        json["params"]);
            } else {
                return RPCRequest(json["method"].str, json["params"]);
            }
        } else {
            raise!(InvalidDataReceived, str)
                ("Request is missing 'jsonrpc', 'id', and/or 'method' fields.");
            assert(0);
        }
    }

    @test("[DOCTEST]: RPCRequest.fromJSONString")
    ///
    unittest {
        auto req = RPCRequest.fromJSONString(
                `{"jsonrpc":"2.0","id":14,"method":"func","params":[0,1]}`);

        assert(req.id == 14);
        assert(req.method == "func");
        assert(req.params.array == [JSONValue(0), JSONValue(1)]);
    }

    @test("RPCRequest.fromJSONString converts JSON to RPCRequest")
    unittest {
        auto req = RPCRequest.fromJSONString(
                `{"jsonrpc": "2.0", "id": 0, "method": "func", "params": [0, 1]}`);
        assert(req.id == 0, "Incorrect ID.");
        assert(req.method == "func", "Incorrect method.");
        assert(req.params.array == [JSONValue(0), JSONValue(1)],
                "Incorrect params.");
    }

    @test("RPCRequest.fromJSONString creates notifications")
    unittest {
        auto req = RPCRequest.fromJSONString(
                `{"jsonrpc": "2.0", "method": "func", "params": [0, 1]}`);

        assert(req.method == "func", "Incorrect method.");
        assert(req.params.array == [JSONValue(0), JSONValue(1)],
                "Incorrect params.");
    }

    @test("RPCRequest.fromJSONString throws exception on invalid input")
    unittest {
        import std.exception : assertThrown;

        assertThrown!InvalidDataReceived(
                RPCRequest.fromJSONString(
                    `{"id": 0, "method": "func", "params": [0, 1]}`));

        assertThrown!InvalidDataReceived(
                RPCRequest.fromJSONString(
                    `{"jsonrpc": "2.0", "id": 0, "params": [0, 1]}`));

        assertThrown!JSONException(
                RPCRequest.fromJSONString(
                    `{"jsonrpc": "2.0", "id": "0", "method": "func", "params": [0, 1]}`));
    }

    /** Construct an RPCRequest with the specified remote method name and
        arguments.

        Template_Parameters:
            T = The type of the request ID.

        Params:
            id =        The ID number of this request.
            method =    The name of the remote method to call.
            params =    A JSON string containing the method arguments as a JSON
                        Object or array.

        Throws:
            InvalidArgument if the json string is not a JSON Object or
            array.

            std.json.JSONException if the json string cannot be parsed.
    */
    this(T)(T id, string method, string params) in {
        assert(method.length > 0);
    } body {
        this(id, method, params.parseJSON);
    }

    /** Convert the RPCRequest to a JSON string to pass to the server.

        Params:
            prettyPrint = Yes to pretty-print the JSON output; No for efficient
                          output.
    */
    string toJSONString(Flag!"prettyPrint" prettyPrint = No.prettyPrint) {
        return _data.toJSON(prettyPrint);
    }

    private:

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

    JSONValue _data;
    bool _isNotification = false;
}

/** The RPC server's response sent to clients.

    Example:
    ---
    auto response = rpc.call("func", [1, 2, 3]);

    if (response.hasError()) writeln(response.error);
    else writeln(response.result);
    ---
*/
struct RPCResponse {
    /** Get the id of the RPCResponse.

        If the id is not of type long, it needs to be specified; if uncertain of
        the underlying type, use idType to query for it.

        Throws:
            IncorrectType if the underlying type of the ID is not the requested
            type.

        See_Also:
            idType
    */
    @property T id(T = long)() {
        scope(failure) {
            raise!(IncorrectType)("The ID is not of the specified type.");
        }
        return unwrapValue!T(_data["id"]);
    }

    @test("RPCResponse non-integral id can be created and read.")
    unittest {
        import std.exception : assertThrown;

        auto resp = RPCResponse("my_id", JSONValue(["result"]));
        assert(resp.id!string == "my_id");
        assertThrown!IncorrectType(resp.id!int);

        auto resp2 = RPCResponse(null, JSONValue(["result"]));
        assert(resp.id!(typeof(null)) == null);
    }

    @property JSON_TYPE idType() { return _data["id"].type; }

    /** The JSON-RPC protocol version. */
    @property string protocolVersion() { return _data["jsonrpc"].str; }

    // TODO: These are mutually exclusive; I shouldn't have properties for both
    // as valid accessors.
    @property JSONValue result() { return _data["result"]; }
    @property JSONValue error() { return _data["error"]; }

    @property bool hasError() {
        return "error" in _data && !(_data["error"].isNull);
    }

    /** Convert the RPCResponse to a JSON string to send to the client.

        Params:
            prettyPrint = Yes to pretty-print the JSON output; No for efficient
                          output.
    */
    string toJSONString(Flag!"prettyPrint" prettyPrint = No.prettyPrint) {
        return _data.toJSON(prettyPrint);
    }

    package:

    /** Construct a response to send to the client.

        The id must be the same as the RPCRequest to which the server is
        responding, and can be numeric, string, or null.

        Template_Parameters:
            T = The type of the response ID.

        Params:
            id =        The ID of this response. This matches the relevant
                        request.
            result =    The return value(s) of the method executed.
    */
    this(T)(T id, JSONValue result) {
        _data["jsonrpc"] = "2.0";
        _data["id"] = id;
        _data["result"] = result;
    }

    /** Construct a predefined error response to send to the client.

        Template_Parameters:
            T = The type of the response ID.

        Params:
            id =    The ID of this response. This matches the relevant request.
            error = The code of the standard error to send.
            data =  Any additional data to add to the error response.
    */
    this(T)(T id, StandardErrorCode error, JSONValue errData = JSONValue()) {
        _data["jsonrpc"] = "2.0";
        _data["id"] = id;
        _data["error"] = getStandardError(error);
        if (errData.type != JSON_TYPE.NULL) _data["error"]["data"] = errData;
    }

    /** Construct an RPCResponse from a JSON string.

        Params:
            str =   The string to convert to an RPCResponse object.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.

            InvalidDataReceived if the 'id' or 'result' field is missing.
    */
    static package RPCResponse fromJSONString(const char[] str) {
        auto json = str.parseJSON;
        if (json.type != JSON_TYPE.NULL
                && "id" in json
                && ("result" in json).xor("error" in json)
                && "jsonrpc" in json && json["jsonrpc"].str == "2.0") {
            return RPCResponse(json);
        } else {
            return RPCResponse(json["id"].integer, StandardErrorCode.InvalidRequest);
        }
    }

    @test("RPCResponse.fromJSONString returns an error on invalid request.")
    unittest {
        auto resp = RPCResponse.fromJSONString(
                `{"jsonrpc": "2.0", "id": 0, "params": [0, 1]}`);
        assert(resp.id == 0, "Incorrect ID.");
        assert(resp.error["code"] == JSONValue(StandardErrorCode.InvalidRequest),
                "Incorrect error.");
    }

    @test("RPCResponse.fromJSONString converts JSON to RPCResponse")
    unittest {
        auto res = RPCResponse.fromJSONString(
                `{"jsonrpc": "2.0", "id": 0, "method": "func", "result": 0}`);
        assert(res.id == 0, "Incorrect ID.");
        assert(res.result.integer == 0, "Incorrect result.");
    }

    // Note/TODO: Only one of result, error will be present in the response.
    JSONValue _data;

    private:

    /** Construct an RPC response by taking a JSONValue response.

        Params:
            data =  The JSONValue data that comprises the response. It must be a
                    valid JSON-RPC 2.0 response.
    */
    this(JSONValue data) in {
        assert("jsonrpc" in data && ("result" in data).xor("error" in data),
                "Malformed response: missing required field(s).");
    } body {
        _data = data;
    }
}

/** Standard error codes.

    Codes between -32768 and -32099 (inclusive) are reserved for pre-defined
    errors; application-specific codes may be defined outside that range.
*/
enum StandardErrorCode : int {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603
    // -32000 to -32099 are reserved for implementation-defined server
    // errors.
}

/** Implementation of a JSON-RPC client.

    Template_Parameters:
        API =       An interface containing the function definitions to call on
                    the remote server. <BR>
        Transport = The network transport to use; by default, we use a
                    TCPTransport.

    Example:
    ---
    // This is the list of functions on the RPC server.
    interface MyRemoteFunctions {
        long func(string param) { return 56789; }
    }

    // Connect over TCP to a server on localhost.
    auto rpc = new RPCClient!MyRemoteFunctions("127.0.0.1", 54321);
    long retval = rpc.func("some string");
    assert(retval == 56789);
    ---
*/
class RPCClient(API, Transport = TCPTransport)
        if (is(API == interface) && is(Transport == struct)) {

    /** Instantiate an RPCClient bound to the specified host.

        Params:
            host =  The hostname or address of the RPC server.
            port =  The port at which to connect to the server.
    */
    this(string host, ushort port) in {
        assert(host.length > 0);
    } body {
        this(Transport(host, port));
    }

    /** Make a blocking remote call with natural syntax.

        Any method (not part of the RPC client itself) that is present in
        the remote API can be called as if it was a member of the RPC client,
        and that function call will be forwarded to the remote server.

        Template_Parameters:
            apiFunc = The name of the fake method to dispatch. <BR>
            ARGS... = A list of parameter types.

        Params:
            args = The arguments of the remote function to call.

        Returns:
            The return value of the function call.

        Throws:
            InvalidArgument if the argument types do not match the
            remote interface.
            RPCErrorResponse if the server returns an error response. Inspect
            the exception payload for details.

        Example:
        ---
        interface RemoteFuncs {
            void func1();
            int func2(bool b, string s);
        }

        auto rpc = new RPCClient!RemoteFuncs("127.0.0.1", 54321);
        rpc.func1();
        int retval = rpc.func2(false, "hello");
        ---

        Notes:
            If you want the full response from the server, use the `call`
            function instead.
    */
    auto ref opDispatch(string apiFunc, ARGS...)(ARGS args) {
        import std.traits;
        static if (! hasMember!(API, apiFunc)) {
            raise!(InvalidArgument, args)
                    ("Argument does not match the remote function interface.");
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
        auto response = call(apiFunc, jsonArgs);
        if (response.hasError()) {
            raise!(RPCErrorResponse, response)
                    ("Server error: " ~ response.error["message"].str);
        }

        static if (is(returnType: void)) {
            return;
        } else return unwrapValue!(returnType)(response.result);
    }

    /** Make a function call on the RPC server.

        Params:
            func =   The name of the remote function to call.
            params = A valid JSON array or Object containing the function
                     parameters.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.

        Returns:
            The server's response.

        Example:
        ---
        interface MyAPI { void func(int val); }
        auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

        import std.json : JSONValue, parseJSON;
        auto resp = client.call("func", `{ "val": 3 }`.parseJSON);
        auto resp2 = client.call("func", JSONValue(3));
        ---
    */
    RPCResponse call(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        auto req = RPCRequest(_nextId++, func, params);

        _transport.send(req.toJSONString());

        auto respObj = _transport.receiveJSONObjectOrArray();
        return RPCResponse.fromJSONString(respObj);
    }

    /** Send a notification to the server.

        A notification is a function call with no reply requested. Note that
        this is different than calling a function that returns void - in the
        latter case a response is still received with a null result; if a
        notification calls a function that returns a value, that return value is
        not sent to the client.

        Params:
            func =   The name of the remote function to call.
            params = A valid JSON array or Object containing the function
                     parameters.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.

        Example:
        ---
        interface MyAPI { void func(int val); }
        auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

        import std.json : JSONValue, parseJSON;
        client.notify("func", `{ "val": 3 }`.parseJSON);
        client.notify("func", JSONValue(3));
        ---
    */
    void notify(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        _transport.send(RPCRequest(func, params).toJSONString());
    }

    /** Execute a batch of function calls.

        Params:
            requests = A list of BatchRequests, each constructed via the
                       `batchReq` function.

        Returns:
            An array of RPCResponse objects, in the same order as the respective
            request.

        Notes:
            Notifications do not get responses; if three requests are made, and
            one is a notification, only two responses will be returned.

        Example:
        ---
        import std.typecons : Yes;

        interface API {
            void func1(int a);
            long func2(string s);
            long func3();
        }
        auto client = RPCClient!API("localhost", 54321);

        auto responses = client.batch(
                batchReq("func1", JSONValue(50)),
                batchReq("func1", JSONValue(-1), Yes.notify),
                batchReq("func2", JSONValue("hello")),
                batchReq("func3", JSONValue(), Yes.notify),
                batchReq("func1", JSONValue(123))
        );
        ---
    */
    RPCResponse[long] batch(BatchRequest[] requests ...) {
        if (requests.length == 0) {
            raise!(InvalidArgument)("requests cannot be an empty array.");
        }

        RPCResponse[long] responses;
        auto allAreNotifications = sendBatchRequest(requests);
        if (! allAreNotifications) responses = receiveBatchResponse();
        return responses;
    }

    private:

    import std.typecons : Flag, Yes, No;

    long _nextId;
    Transport _transport;

    /** Instantiate an RPCClient with the specified network transport.

        This is designed to allow mock objects for testing.
    */
    this(Transport transport) {
        _transport = transport;
    }

    Flag!"allAreNotifications" sendBatchRequest(BatchRequest[] requests) {
        JSONValue[] reqs;
        Flag!"allAreNotifications" allAreNotifications = Yes.allAreNotifications;

        foreach (request; requests) {
            if (request.isNotification) {
                reqs ~= RPCRequest(request.method, request.params)._data;
            } else {
                allAreNotifications = No.allAreNotifications;
                reqs ~= RPCRequest(
                        _nextId++, request.method, request.params)._data;
            }
        }
        auto batchReq = JSONValue(reqs);
        _transport.send(batchReq.toJSON());
        return allAreNotifications;
    }

    RPCResponse[long] receiveBatchResponse() {
        RPCResponse[long] responses;
        auto resps = _transport.receiveJSONObjectOrArray().parseJSON;

        if (resps.type == JSON_TYPE.ARRAY) {
            foreach (resp; resps.array) {
                auto r = RPCResponse(resp);
                responses[r.id] = r;
            }
        } else {
            // Single non-array (error?) response due to a malformed or empty
            // batch.
            auto resp = RPCResponse(resps);
            responses[resp.id] = resp;
        }
        return responses;
    }
}

import std.typecons : Flag, No;
/** Create a BatchRequest to pass to an RPCClient's `batch` function.

    Params:
        method = The name of the remote method to call.
        params = A JSONValue scalar or object/array containing the method
                 parameters.
        notify = Yes.notify if the request is a notification; No.notify
                 otherwise.

    Returns:
        A BatchRequest to be passed to an RPCClient's batch function.

    Example:
    ---
    import std.typecons : Yes;

    interface API {
        void func1(int a);
        long func2(string s);
        long func3();
    }
    auto client = RPCClient!API("localhost", 54321);

    auto responses = client.batch(
            batchReq("func1", JSONValue(50)),
            batchReq("func1", JSONValue(-1), Yes.notify),
            batchReq("func2", JSONValue("hello")),
            batchReq("func3", JSONValue(), Yes.notify),
            batchReq("func1", JSONValue(123))
    );
    ---
*/
auto batchReq(
        string method, JSONValue params, Flag!"notify" notify = No.notify) {
    return BatchRequest(method, params, notify);
}

/** Implementation of a JSON-RPC server.

    This implementation only supports communication via TCP sockets.

    Template_Parameters:
        API =      A class or struct containing the functions available for the
                   client to call. <BR>
        Listener = The object to use to manage client connections. By default, a
                   TCPTransport.

    Example:
    ---
    class MyFunctions {
        long func(string param) { return 56789; }
    }

    // Bind to a local port and serve func on a platter.
    auto serve = new RPCServer!MyFunctions("127.0.0.1", 54321);
    serve.listen();
    ---
*/
class RPCServer(API, Listener = TCPListener!API)
        if (is(API == class) && is(Listener == struct)) {

    import std.socket;

    /** Construct an RPCServer!API object to communicate via TCP sockets.

        The API class must be constructable via a default constructor; if you
        need to use an alternate constructor, create it first and pass it to the
        RPCServer via another constructor.

        Params:
            host =  The host interface on which to listen.
            port =  The port on which to listen.
    */
    this(string host, ushort port) {
        this(new API(), Listener(host, port));
    }

    /** Construct an RPCServer!API object to communicate via TCP sockets.

        Params:
            api =   The instantiated class or struct providing the RPC API.
            host =  The host interface on which to listen.
            port =  The port on which to listen.
    */
    this(API api, string host, ushort port) {
        this(api, Listener(host, port));
    }

    /** Listen for and respond to connections.

        Params:
            maxQueuedConnections = The maximum number of clients to hold in
                                   the backlog before rejecting connections.
    */
    void listen(int maxQueuedConnections = 10) {
        _listener.listen!(handleClient!API)(_api, maxQueuedConnections);
    }

    private:

    API _api;
    Listener _listener;

    /** Construct an RPCServer!API object.

        By default, serve over a TCP connection; alternate network transports can
        be specified.

        Params:
            api =       The instantiated class or struct providing the RPC API.
            transport = The network transport to use.
    */
    this(API api, Listener listener) {
        _api = api;
        _listener = listener;
    }
}

/** Handles all of an individual client's requests.

    The `listen` method of the RPCServer calls this in a new thread to handle
    client requests. This is not intended to be called by user code.

    Template_Parameters:
        API =       The class containing the RPC functions.
        Transport = The type of the network transport to use; by default, this
                    is a TCPTransport.

    Params:
        transport = The network transport used for data transmission.
        api       = An instantiated class containing the functions to execute.
*/
void handleClient(API, Transport = TCPTransport)(Transport transport, API api)
        if (is(Transport == struct)) {
    while (transport.isAlive()) {
        char[] received = receiveRequest(transport);
        if (received.length == 0) continue;

        if (received[0] == '[') {
            executeBatch(transport, api, received);
        } else {
            auto req = RPCRequest.fromJSONString(received);
            if (req.isNotification) {
                executeMethod(req, api);
            } else {
                transport.send(executeMethod(req, api).toJSONString);
            }
        }
    }
}

/** Execute an RPC method and return the server's response.

    Only public members of the API object are callable as a remote function.

    Template_Parameters:
        API = The class containing the function to call.

    Params:
        request =   The request from the client.
        api =       An instance of the class or struct containing the function
                    to call.
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

                if (request.isNotification) {
                    // TODO: I'd rather return nothing; this is just thrown away.
                    RPCResponse r;
                    return r;
                } else if (request.idType == JSON_TYPE.INTEGER) {
                    return RPCResponse(request.id, JSONValue(retval));
                } else if (request.idType == JSON_TYPE.FLOAT) {
                    return RPCResponse(request.id!double, JSONValue(retval));
                } else if (request.idType == JSON_TYPE.STRING) {
                    return RPCResponse(request.id!string, JSONValue(retval));
                } else if (request.idType == JSON_TYPE.NULL) {
                    return RPCResponse(null, JSONValue(retval));
                }
                return RPCResponse(
                        request._data["id"],
                        StandardErrorCode.InvalidRequest,
                        JSONValue("Invalid request ID type."));
            }
        }
    }
    return RPCResponse(
            request.id,
            StandardErrorCode.MethodNotFound,
            request._data);
}

private:

char[] receiveRequest(Transport)(Transport transport) {
    try {
        return transport.receiveJSONObjectOrArray();
    } catch (InvalidDataReceived ex) {
        transport.send(
                RPCResponse(
                    null,
                    StandardErrorCode.InvalidRequest,
                    JSONValue(ex.msg)
                ).toJSONString()
        );
    } catch (Exception) {
        transport.send(
                RPCResponse(
                    null,
                    StandardErrorCode.InternalError,
                    JSONValue(
                        "Unknown exception occurred while receiving data.")
                ).toJSONString()
        );
    }
    return [];
}

JSONValue parseBatch(Transport)(Transport transport, const char[] request) {
    scope(failure) {
        // TODO: The spec says to send a single response, but how do I
        // handle the ID? Need to check other implementations.
        transport.send(
                RPCResponse(
                    null,
                    StandardErrorCode.ParseError,
                    JSONValue("Batch request is malformed.")
                ).toJSONString()
        );
        return JSONValue();
    }

    auto batch = request.parseJSON();
    if (batch.array.length == 0) {
        // SPEC: Send a single response if the array is empty.
        // TODO: How do I handle the ID?
        transport.send(
                RPCResponse(
                    null,
                    StandardErrorCode.InvalidRequest,
                    JSONValue("Received batch with no requests.")
                ).toJSONString()
        );
        return JSONValue();
    }
    return batch;
}

void executeBatch(API, Transport)
        (Transport transport, API api, const char[] received) {

    JSONValue batch = parseBatch(transport, received);
    if (batch.type == JSON_TYPE.NULL) return;

    JSONValue[] responses;
    // TODO: Could parallelize these. Probably use constructor flag(?)
    foreach (request; batch.array) {
        RPCRequest req;
        try {
            // TODO: Horribly inefficient. Need a new constructor.
            req = RPCRequest.fromJSONString(request.toJSON());
        } catch (InvalidDataReceived ex) {
            if ("id" in request) {
                responses ~= RPCResponse(
                        request["id"],
                        StandardErrorCode.InvalidRequest,
                        JSONValue(ex.msg))._data;
            } // TODO: else... spec is silent.
            continue;
        } catch (JSONException ex) {
            if ("id" in request) {
                responses ~= RPCResponse(
                        request["id"],
                        StandardErrorCode.ParseError,
                        JSONValue(ex.msg))._data;
            } // TODO: else... spec is silent.
            continue;
        }
        if (req.isNotification) {
            executeMethod(req, api);
        } else {
            responses ~= executeMethod(req, api)._data;
        }
    }
    if (responses.length > 0) {
        auto data = JSONValue(responses);
        transport.send(data.toJSON());
    } // else: they were all notifications.
}

/** Execute an RPC method and return its result.

    Template_Parameters:
        API    = The class providing the executable functions.
        method = The name of the method to call.

    Params:
        request = The request sent from the client.
        api     = The instantiated class with the method to execute.
*/
auto execRPCMethod(API, string method)(RPCRequest request, API api) {
    import std.traits : ReturnType;
    mixin(
        "enum returnType = typeid(ReturnType!(API." ~ method ~ "));\n" ~
        GenCaller!(API, method)
    );

    static if((returnType is typeid(void))) {
        callRPCFunc!(method, JSONValue)(api, request.params);
        return null;
    } else {
        return callRPCFunc!(method, JSONValue)(api, request.params);
    }
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
static string GenCaller(API, string method)() pure {
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

    static if (returnType is typeid(void)) {
        func ~= "    ";
    } else static if (returnType is typeid(bool)) {
        func ~= ("    return cast(bool)");
    } else {
        func ~= ("    return ");
    }

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

/** Container for request data submitted in a batch.

    This allows me to send requests and notifications in a single object without
    doing crazy stuff.
*/
struct BatchRequest {
    this(string method, JSONValue params, bool isNotification = false) {
        this.method = method;
        this.params = params;
        this.isNotification = isNotification;
    }

    string method;
    JSONValue params;
    bool isNotification;
}

/** Return error data for JSON-RPC and RPCServer standard error codes.

    Params:
        code = A StandardErrorCode set to the error number.

    Returns:
        The "error" dictionary to attach to the RPCResponse.

    Example:
    ---
    auto resp = RPCResponse(0, getStandardError(StandardErrorCode.InvalidRequest);
    ---
*/
private JSONValue getStandardError(StandardErrorCode code) {
    auto err = JSONValue();
    err["code"] = code;
    final switch (code) {
        case StandardErrorCode.ParseError:
            err["message"] = "An error occurred while parsing the JSON text.";
            break;
        case StandardErrorCode.InvalidRequest:
            err["message"] = "The JSON sent is not a valid Request object.";
            break;
        case StandardErrorCode.MethodNotFound:
            err["message"] = "The called method is not available.";
            break;
        case StandardErrorCode.InvalidParams:
            err["message"] = "The method was called with invalid parameters.";
            break;
        case StandardErrorCode.InternalError:
            err["message"] = "Internal server error.";
            break;
    }

    return err;
}

/** Unwrap a scalar value from a JSONValue object. */
auto unwrapValue(T)(JSONValue value) {
    import std.traits;
    static if (isFloatingPoint!T) {
        return cast(T)value.floating;
    } else static if (isSomeString!T) {
        return cast(T)value.str;
    } else static if (isSigned!T) {
        return cast(T)value.integer;
    } else static if (isUnsigned!T) {
        // TODO: There has to be a better way to do all of this.
        // Positive signed values will take this branch, rather than the
        // isSigned! branch.
        try {
            return cast(T)value.uinteger;
        } catch (JSONException e) {
            return cast(T)value.integer;
        }
    } else static if (isBoolean!T) {
        if (value.type == JSON_TYPE.TRUE) return true;
        if (value.type == JSON_TYPE.FALSE) return false;
        raise!(InvalidArgument, value)("Expected a boolean value.");
    } else static if (is(T == typeof(null))) {
        return null;
    } else {
        raise!(InvalidArgument, value)("Non-scalar value cannot be unwrapped.");
    }
    assert(0);
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

bool xor(T)(T left, T right) {
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
        float retFloat() { return 1.23; }

        void voidFunc() { voidFunc_called = true; }
        void void3params(int a, bool b, float c) { void3params_called = true; }
        void voidArray(int a, int b) { voidArray_called = true; }
        void voidWithString(string s) { voidWithString_called = true; }

        string retString() { return "testing"; }

        string øbæårößΓαζ(string input) { return input ~ "âいはろшь ж๏เ"; }
    }
}

@test("execRPCMethod executes void RPC functions")
unittest {
    auto api = new MyAPI();

    auto r1 = execRPCMethod!(MyAPI, "void3params")
            (RPCRequest(0, "void3params",
                JSONValue(`{"a": 3, "b": false, "c": 2.3}`.parseJSON)),
                api);
    auto r2 = execRPCMethod!(MyAPI, "voidArray")
            (RPCRequest(1, "voidArray", JSONValue([1, 2])), api);
    auto r3 = execRPCMethod!(MyAPI, "voidFunc")
            (RPCRequest(2, "voidFunc"), api);

    assert(api.void3params_called == true
            && api.voidArray_called == true
            && api.voidFunc_called == true);
}

@test("execRPCMethod executes non-void RPC functions")
unittest {
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
    auto api = new MyAPI();

    auto r1 = executeMethod(RPCRequest(0, "retUlong",
            JSONValue("some string")), api);
    assert(r1.id == 0);
    assert(r1.result.unwrapValue!ulong == 19);

    auto r2 = executeMethod(RPCRequest(1, "retInt", JSONValue(5)), api);
    assert(r2.id == 1);
    assert(r2.result.integer == 6);
}

@test("executeMethod returns floating-point values")
unittest {
    auto api = new MyAPI();

    auto resp = executeMethod(RPCRequest(0, "retFloat"), api);
    assert(resp.result.floating > 1.22 && resp.result.floating < 1.24);
}

@test("executeMethod returns boolean values")
unittest {
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
    auto api = new MyAPI();

    auto r1 = executeMethod(RPCRequest(0, "retString"), api);
    assert(r1.result.unwrapValue!string == "testing");
}

@test("executeMethod handles non-integral IDs")
unittest {
    auto api = new MyAPI();

    auto r1 = executeMethod(RPCRequest("my_id", "retString"), api);
    assert(r1.id!string == "my_id");

    auto r2 = executeMethod(RPCRequest(null, "retString"), api);
    assert(r2.id!(typeof(null)) == null);
}

@test("executeMethod can execute functions and pass data not in the ASCII character range")
unittest {
    auto api = new MyAPI();

    auto ret = executeMethod(
            RPCRequest("áðý", "øbæårößΓαζ", JSONValue("éçφωτz")), api);
    assert(ret.result == JSONValue("éçφωτzâいはろшь ж๏เ"));
}

@test("executeMethod returns error when the method doesn't exist")
unittest {
    auto api = new MyAPI();
    auto r1 = executeMethod(RPCRequest(0, "noFunctionHere"), api);

    assert(r1.id!long == 0);
    assert(r1.error["code"].integer == StandardErrorCode.MethodNotFound, "Wrong error.");
    assert(r1.error["data"]["method"].str == "noFunctionHere",
            "Did not include method.");
}

@test("executeMethod returns error on invalid request ID")
unittest {
    auto api = new MyAPI();

    auto req = RPCRequest(0, "retTrue");
    req._data["id"] = JSONValue([1,2]);
    auto resp = executeMethod(req, api);

    import std.stdio;
    writeln(resp);

    // The ID is not accessible outside this package, but does need to be
    // correct.
    assert(resp._data["id"] == JSONValue([1,2]));
    assert(resp.error["code"].integer == StandardErrorCode.InvalidRequest,
            "Incorrect error.");
}

@test("[DOCTEST] RPCClient example: opDispatch")
unittest {
    interface RemoteFuncs {
        void func1();
        int func2(bool b, string s);
    }

    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    auto rpc = new RPCClient!RemoteFuncs(transport);

    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":0,"result":null}`;
    rpc.func1();
    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":1,"result":3}`;
    assert(rpc.func2(false, "hello") == 3);
}

@test("[DOCTEST] RPCClient example: call")
unittest {
    interface MyAPI { void func(int val); }
    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    auto client = new RPCClient!MyAPI(transport);

    import std.json : JSONValue;
    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":0,"result":null}`;
    auto resp = client.call("func", `{ "val": 3 }`.parseJSON);
    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":1,"result":null}`;
    auto resp2 = client.call("func", JSONValue(3));
}

@test("[DOCTEST] RPCClient example: notify")
unittest {
    interface MyAPI { void func(int val); }
    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    auto client = new RPCClient!MyAPI(transport);

    import std.json : JSONValue, parseJSON, toJSON;

    client.notify("func", `{"val": 3}`.parseJSON);
    assert(sock.lastDataSent ==
            RPCRequest("func", `{"val":3}`.parseJSON)._data.toJSON);

    client.notify("func", JSONValue(3));
    assert(sock.lastDataSent ==
            RPCRequest("func", `[3]`.parseJSON)._data.toJSON);
}

@test("[DOCTEST] Execute batches of requests.")
unittest {
    interface API {
        void func1(int a);
        long func2(string s);
        long func3();
    }
    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    auto client = new RPCClient!API(transport);

    sock.receiveReturnValue =
        `[{"id":0,"jsonrpc":"2.0","result":null},
          {"id":1,"jsonrpc":"2.0","result":123},
          {"id":2,"jsonrpc":"2.0","result":0}]`;

    import std.typecons : Yes;
    auto responses = client.batch(
            batchReq("func1", JSONValue(50)),
            batchReq("func1", JSONValue(-1), Yes.notify),
            batchReq("func2", JSONValue("hello")),
            batchReq("func3", JSONValue()),
            batchReq("func1", JSONValue(123), Yes.notify)
    );

    assert(responses[0].result == JSONValue(null), "Incorrect [0] result");
    assert(responses[1].result == JSONValue(123), "Incorrect [1] result");
    assert(responses[2].result == JSONValue(0), "Incorrect [2] result");
}
