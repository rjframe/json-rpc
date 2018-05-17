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
import std.traits : isAggregateType;

import jsonrpc.transport;
import jsonrpc.exception;

version(Have_tested) import tested : test = name;
else private struct test { string name; }

/** An RPC request constructed by the client to send to the RPC server.

    The Request contains the ID of the request, the method to call, and any
    parameters to pass to the method. You should not need to manually create a
    Request object; the RPCClient will do this for you.
*/
struct Request {
    import std.traits;
    import std.typecons : Flag, Yes, No;

    /** Construct a Request with the specified remote method name and
        arguments.

        The ID must be a string, a number, or null; null is not recommended for
        use as an ID.

        Template_Parameters:
            T = The type of the request ID.

        Params:
            id =        The ID of the request.
            method =    The name of the remote method to call.
            params =    A JSONValue containing the method arguments as a JSON
                        Object or array.
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

    /** Construct a Request with the specified remote method name and
        arguments.

        The value of the ID must be a string, a number, or null; null is not
        recommended for use as an ID.

        Params:
            id =        A JSONValue containing a scalar ID of the request.
            method =    The name of the remote method to call.
            params =    A JSONValue containing the method arguments as a JSON
                        Object or array.
    */
    this(JSONValue id, string method, JSONValue params) in {
        assert(method.length > 0);
        assert(id.type != JSON_TYPE.OBJECT);
        assert(id.type != JSON_TYPE.ARRAY);
    } body {
        _data["id"] = id;
        _data["method"] = method;
        _data["jsonrpc"] = "2.0";
        this.params = params;
    }

    /** Construct a notification with the specified remote method name and
        arguments.

        A notification will receive no response from the server.

        Params:
            method =    The name of the remote method to call.
            params =    A JSON string containing the method arguments as a JSON
                        Object or array.
    */
    this(string method, JSONValue params = JSONValue()) in {
        assert(method.length > 0);
    } body {
        this._isNotification = true;
        this._data["jsonrpc"] = "2.0";
        this._data["method"] = method;
        this.params = params;
    }

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

    @test("Request string id can be created and read.")
    unittest {
        import std.exception : assertThrown;

        auto req = Request("my_id", "func", JSONValue(["params"]));
        assert(req.id!string == "my_id");
        assertThrown!IncorrectType(req.id!int);
    }

    @test("Request null id can be created and read.")
    unittest {
        auto req = Request(null, "func", JSONValue(["params"]));
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

    package:

    /** Parse a JSON string into a Request object.

        Params:
            str =   The JSON string to parse.

        Notes:
            The ID, if present, must be integral; this is non-conformant to
            the JSON-RPC specification.

        Throws:
            InvalidDataReceived if the ID or method fields are missing.

            JSONException if the ID or method fields are an incorrect type. The
            ID must be integral and the method must be a string.
    */
    static Request fromJSONString(const char[] str) {
        auto json = str.parseJSON;
        enforce!(InvalidDataReceived, str)
                (json.type != JSON_TYPE.NULL
                     && "method" in json
                     && "jsonrpc" in json && json["jsonrpc"].str == "2.0",
                "Request is missing 'jsonrpc', 'id', and/or 'method' fields.");

        if ("params" !in json) json["params"] = JSONValue();
        if ("id" in json) {
            return Request(
                    json["id"],
                    json["method"].str,
                    json["params"]);
        } else {
            return Request(json["method"].str, json["params"]);
        }
    }

    @test("[DOCTEST]: Request.fromJSONString")
    ///
    unittest {
        auto req = Request.fromJSONString(
                `{"jsonrpc":"2.0","id":14,"method":"func","params":[0,1]}`);

        assert(req.id == 14);
        assert(req.method == "func");
        assert(req.params.array == [JSONValue(0), JSONValue(1)]);
    }

    @test("Request.fromJSONString converts JSON to Request")
    unittest {
        auto req = Request.fromJSONString(
                `{"jsonrpc": "2.0", "id": 0, "method": "func", "params": [0, 1]}`);
        assert(req.id == 0, "Incorrect ID.");
        assert(req.method == "func", "Incorrect method.");
        assert(req.params.array == [JSONValue(0), JSONValue(1)],
                "Incorrect params.");
    }

    @test("Request.fromJSONString creates notifications")
    unittest {
        auto req = Request.fromJSONString(
                `{"jsonrpc": "2.0", "method": "func", "params": [0, 1]}`);

        assert(req.method == "func", "Incorrect method.");
        assert(req.params.array == [JSONValue(0), JSONValue(1)],
                "Incorrect params.");
    }

    /** Construct a Request with the specified remote method name and
        arguments.

        Template_Parameters:
            T = The type of the request ID.

        Params:
            id =        The ID number of this request.
            method =    The name of the remote method to call.
            params =    A JSON string containing the method arguments as a JSON
                        Object or array.

        Throws:
            std.json.JSONException if the json string cannot be parsed.
    */
    this(T)(T id, string method, string params) in {
        assert(method.length > 0);
    } body {
        this(id, method, params.parseJSON);
    }

    /** Convert the Request to a JSON string to pass to the server.

        Params:
            prettyPrint = Yes to pretty-print the JSON output; No for efficient
                          output.
    */
    string toJSONString(Flag!"prettyPrint" prettyPrint = No.prettyPrint) {
        return _data.toJSON(prettyPrint);
    }

    private:

    /** Retrieve the method to execute on the RPC server. */
    @property string method() { return _data["method"].str; }

    /** Retrieve the parameters that will be passed to the method. */
    @property JSONValue params() { return _data["params"]; }

    /** Set the parameters to the remote method that will be called.

        Params:
            val =   A JSON Object or array. Other value types will be wrapped
                    in an array (e.g., 3 becomes [3]).
    */
    @property void params(JSONValue val)
    {
        if (val.type != JSON_TYPE.OBJECT
                && val.type != JSON_TYPE.ARRAY
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
struct Response {
    /** Get the id of the Response.

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

    @test("Response string id can be created and read.")
    unittest {
        import std.exception : assertThrown;

        auto resp = Response("my_id", JSONValue(["result"]));
        assert(resp.id!string == "my_id");
        assertThrown!IncorrectType(resp.id!int);
    }

    @test("Response null id can be created and read.")
    unittest {
        auto resp = Response(null, JSONValue(["result"]));
        assert(resp.id!(typeof(null)) == null);
    }

    @property JSON_TYPE idType() { return _data["id"].type; }

    // TODO: These are mutually exclusive; I shouldn't have properties for both
    // as valid accessors.
    @property JSONValue result() { return _data["result"]; }
    @property JSONValue error() { return _data["error"]; }

    @property bool hasError() {
        return "error" in _data && !(_data["error"].isNull);
    }

    /** Convert the Response to a JSON string to send to the client.

        Params:
            prettyPrint = Yes to pretty-print the JSON output; No for efficient
                          output.
    */
    string toJSONString(Flag!"prettyPrint" prettyPrint = No.prettyPrint) {
        return _data.toJSON(prettyPrint);
    }

    package:

    /** Construct a response to send to the client.

        The id must be the same as the Request to which the server is
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
            id =      The ID of this response. This matches the relevant request.
            error =   The code of the standard error to send.
            errData = Any additional data to add to the error response.
    */
    this(T)(T id, StandardErrorCode error, JSONValue errData = JSONValue()) {
        _data["jsonrpc"] = "2.0";
        _data["id"] = id;
        _data["error"] = getStandardError(error);
        if (errData.type != JSON_TYPE.NULL) _data["error"]["data"] = errData;
    }

    /** Construct an Response from a JSON string.

        Params:
            str = The string to convert to an Response object.

        Throws:
            std.json.JSONException if the string cannot be parsed as JSON.
    */
    static package Response fromJSONString(const char[] str) in {
        assert(str.length > 0, "Parsed JSON cannot be null.");
    } body {
        auto json = str.parseJSON;
        if ("id" in json
                && ("result" in json).xor("error" in json)
                && "jsonrpc" in json && json["jsonrpc"].str == "2.0") {

            return Response(json);
        } else {
            return Response(json["id"].integer, StandardErrorCode.InvalidRequest);
        }
    }

    @test("Response.fromJSONString returns an error on invalid request.")
    unittest {
        auto resp = Response.fromJSONString(
                `{"jsonrpc": "2.0", "id": 0, "params": [0, 1]}`);
        assert(resp.id == 0, "Incorrect ID.");
        assert(resp.error["code"] == JSONValue(StandardErrorCode.InvalidRequest),
                "Incorrect error.");
    }

    @test("Response.fromJSONString converts JSON to Response")
    unittest {
        auto res = Response.fromJSONString(
                `{"jsonrpc": "2.0", "id": 0, "method": "func", "result": 0}`);
        assert(res.id == 0, "Incorrect ID.");
        assert(res.result.integer == 0, "Incorrect result.");
    }

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
        if (is(API == interface) && isTransport!Transport) {

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
    Response call(string func, JSONValue params = JSONValue()) in {
        assert(func.length > 0);
    } body {
        auto req = Request(_nextId++, func, params);
        _transport.send(req.toJSONString());

        auto respObj = _transport.receiveJSONObjectOrArray();
        return Response.fromJSONString(respObj);
    }

    /** Send a Request object to the server.

        Generally the only reason to use this overload is to send a request with
        a non-integral ID.

        Params:
            request = The Request to send.

        Example:
        ---
        interface MyAPI { bool my_func(int[] values); }

        auto client = RPCClient!MyAPI("127.0.0.1", 54321);
        auto req = Request("my_id", "my_func", [1, 2, 3]);
        auto response = client.call(req);
        ---
    */
    Response call(Request request) {
        _transport.send(request.toJSONString());

        auto respObj = _transport.receiveJSONObjectOrArray();
        return Response.fromJSONString(respObj);
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
        _transport.send(Request(func, params).toJSONString());
    }

    /** Execute a batch of function calls.

        Params:
            requests = A list of BatchRequests, each constructed via the
                       `batchReq` function.

        Returns:
            An array of Response objects, in the same order as the respective
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
    Response[long] batch(BatchRequest[] requests ...) {
        if (requests.length == 0) {
            raise!(InvalidArgument)("requests cannot be an empty array.");
        }

        Response[long] responses;
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
                reqs ~= Request(request.method, request.params)._data;
            } else {
                allAreNotifications = No.allAreNotifications;
                reqs ~= Request(
                        _nextId++, request.method, request.params)._data;
            }
        }
        auto batchReq = JSONValue(reqs);
        _transport.send(batchReq.toJSON());
        return allAreNotifications;
    }

    Response[long] receiveBatchResponse() {
        Response[long] responses;
        auto resps = _transport.receiveJSONObjectOrArray().parseJSON;

        if (resps.type == JSON_TYPE.ARRAY) {
            foreach (resp; resps.array) {
                auto r = Response(resp);
                responses[r.id] = r;
            }
        } else {
            // Single non-array (error?) response due to a malformed or empty
            // batch.
            auto resp = Response(resps);
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
        if (is(API == class) && isListener!(Listener!API)) {

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
        if (is(API == class) && isTransport!Transport) {
    while (transport.isAlive()) {
        char[] received = receiveRequest(transport);
        if (received.length == 0) continue;

        if (received[0] == '[') {
            executeBatch(transport, api, received);
        } else {
            auto req = Request.fromJSONString(received);
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
Response executeMethod(API)(Request request, API api)
        if (is(API == class)) {

    import std.traits : isFunction;
    // TODO: Filter out @disable -d functions
    // 2.079.0 introduces __traits(isDisabled)
    foreach(method; __traits(derivedMembers, API)) {
        mixin(
            "enum isMethodAPublicFunction =\n" ~
            "   isFunction!(api." ~ method ~ ") &&\n" ~
            "   __traits(getProtection, api." ~ method ~ ") == `public`;\n"
        );

        static if (isMethodAPublicFunction) {
            if (method == request.method) {
                static if (isAggregateType!
                            (typeof(execRPCMethod!(API, method)(request, api)))) {
                    auto retval =
                            execRPCMethod!(API, method)(request, api).serialize;
                } else {
                    auto retval = JSONValue(
                            execRPCMethod!(API, method)(request, api));
                }

                if (request.isNotification) {
                    // TODO: I'd rather return nothing; this is just thrown away.
                    Response r;
                    return r;
                } else if (request.idType == JSON_TYPE.INTEGER) {
                    return Response(request.id, retval);
                } else if (request.idType == JSON_TYPE.FLOAT) {
                    return Response(request.id!double, retval);
                } else if (request.idType == JSON_TYPE.STRING) {
                    return Response(request.id!string, retval);
                } else if (request.idType == JSON_TYPE.NULL) {
                    return Response(null, retval);
                }
                return Response(
                        request._data["id"],
                        StandardErrorCode.InvalidRequest,
                        JSONValue("Invalid request ID type."));
            }
        }
    }
    return Response(
            request.id,
            StandardErrorCode.MethodNotFound,
            request._data);
}

@("We can pass POD objects as RPC parameters.")
unittest {
    struct MyData {
        int a;
        string b;
        float c;
    }

    MyData mydata = {
        a: 1,
        b: "2",
        c: 3.0,
    };

    interface API {
        MyData func(MyData params);
    }

    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    auto client = new RPCClient!API(transport);

    // TODO: I want automatic serialization: auto ret = client.func(mydata);
    auto ret = client.call("func", mydata.serialize);
}

@test("serialize converts simple structs to JSONValues")
unittest {
    struct MyData {
        int a;
        string b;
        float c;
        int[] d;
        string[string] e;
    }

    string[string] _e; _e["asdf"] = ";lkj";

    MyData mydata = {
        a: 1,
        b: "2",
        c: 3.0,
        d: [1, 2, 3],
        e: _e
    };

    auto json = serialize(mydata);
    JSONValue expected = JSONValue(
            `{"a":1,"b":"2","c":3.0,"d":[1,2,3],"e":{"asdf":";lkj"}}`.parseJSON);
    assert(json == expected, json.toJSON);
}

@test("serialize converts nested structs to JSONValues")
unittest {
    struct MoreData {
        int e;
        string f;
    }

    struct MyData {
        int a;
        string b;
        float c;
        MoreData d;
    }

    MyData mydata = {
        a: 1,
        b: "2",
        c: 3.0,
        d: MoreData(123, "g")
    };

    auto json = serialize(mydata);
    auto expected = JSONValue(`{"a":1,"b":"2","c":3.0,"d":{"e":123,"f":"g"}}`.parseJSON);
    assert(json == expected, json.toJSON);
}

/** Serialize a struct to a JSON Object.

    Template_Parameters:
        T = The type of object to serialize.

    Params:
        obj = The object to serialize to JSON.
*/
JSONValue serialize(T)(T obj) if (isAggregateType!T) {
    import std.traits : Fields, FieldNameTuple;
    JSONValue json;
    alias fields = Fields!T;
    alias fieldNames = FieldNameTuple!T;

    static foreach (int i; 0..fields.length) {
        static if (isAggregateType!(fields[i])) {
            mixin(`json["` ~ fieldNames[i] ~ `"] = serialize(obj.` ~ fieldNames[i] ~ `);`);
        } else{
            mixin(`json["` ~ fieldNames[i] ~ `"] = obj.` ~ fieldNames[i] ~ `;`);
        }
    }

    return json;
}

@test("deserialize converts a JSONValue to a struct")
unittest {
    struct MyData {
        int a;
        string b;
        float c;
        int[] d;
        string[string] e;
    }

    string[string] _e; _e["asdf"] = ";lkj";

    MyData expected = {
        a: 1,
        b: "2",
        c: 3.0,
        d: [1, 2, 3],
        e: _e
    };

    JSONValue input = JSONValue(
            `{"a":1,"b":"2","c":3.0,"d":[1,2,3],"e":{"asdf":";lkj"}}`.parseJSON);
    assert(input.deserialize!MyData == expected);
}

@test("deserialize converts a JSONValue to a nested struct")
unittest {
    struct MoreData {
        int e;
        string f;
    }

    struct MyData {
        int a;
        string b;
        float c;
        MoreData d;
    }

    MyData expected = {
        a: 1,
        b: "2",
        c: 3.0,
        d: MoreData(123, "g")
    };

    auto input = JSONValue(`{"a":1,"b":"2","c":3.0,"d":{"e":123,"f":"g"}}`.parseJSON);
    assert(input.deserialize!MyData == expected);
}

/** Deserialize a JSON Object to the specified aggregate D type.

    Template_Parameters:
        T = The type of data object.

    Params:
        json = The JSON object to deserialize.
*/
T deserialize(T)(JSONValue json) if (isAggregateType!T) {
    import std.traits : Fields, FieldNameTuple;

    alias types = Fields!T;
    alias names = FieldNameTuple!T;
    T newObject;

    static foreach (i; 0..types.length) {
        static if (isAggregateType!(types[i])) {
            mixin(`newObject.` ~ names[i]
                ~ ` = deserialize!(typeof(newObject.` ~ names[i] ~ `))(json["`
                    ~ names[i] ~ `"]);`);
        } else {
            mixin(`newObject.` ~ names[i] ~
                ` = unwrapValue!(` ~ types[i].stringof ~ `)(json["`
                    ~ names[i] ~ `"]);`);
        }
    }
    return newObject;
}

private:

char[] receiveRequest(Transport)(Transport transport) {
    try {
        return transport.receiveJSONObjectOrArray();
    } catch (InvalidDataReceived ex) {
        transport.send(
                Response(
                    null,
                    StandardErrorCode.InvalidRequest,
                    JSONValue(ex.msg)
                ).toJSONString()
        );
    } catch (Exception) {
        transport.send(
                Response(
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
                Response(
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
                Response(
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
        Request req;
        try {
            // TODO: Horribly inefficient. Need a new constructor.
            req = Request.fromJSONString(request.toJSON());
        } catch (InvalidDataReceived ex) {
            if ("id" in request) {
                responses ~= Response(
                        request["id"],
                        StandardErrorCode.InvalidRequest,
                        JSONValue(ex.msg))._data;
            } // TODO: else... spec is silent. Example uses null ID.
            continue;
        } catch (JSONException ex) {
            if ("id" in request) {
                responses ~= Response(
                        request["id"],
                        StandardErrorCode.ParseError,
                        JSONValue(ex.msg))._data;
            } // TODO: else... spec is silent. Example uses null ID.
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

    Returns:
        The return value of the RPC method.
*/
auto execRPCMethod(API, string method)(Request request, API api) {
    import std.traits : ReturnType;
    mixin(
        "enum returnType = typeid(ReturnType!(API." ~ method ~ "));\n" ~
        GenCaller!(API, method)
    );

    static if(returnType is typeid(void)) {
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
    import std.traits;

    mixin(
        "alias paramNames = AliasSeq!(ParameterIdentifierTuple!(API."
                ~ method ~ "));\n"
      ~ "alias paramTypes = AliasSeq!(Parameters!(API." ~ method ~ "));\n"
      ~ "\nenum returnType = typeid(ReturnType!(API." ~ method ~ "));\n"
     );

    // TODO: Validate against API - if a named param is passed that isn't on the
    // method we need to return an error response. See execRPCMethod.
    string func =
        "\nauto ref callRPCFunc(string method, ARGS)(API api, ARGS args) {\n";

    static foreach(i; 0..paramTypes.length) {
        static if (isAggregateType!(paramTypes[i]))
            func ~=
          "    import " ~ moduleName!(paramTypes[i]) ~ " : "
                    ~ paramTypes[i].stringof ~ ";\n";
    }

    func ~=
          "    JSONValue vals = args;\n"
        ~ "    if (args.type != JSON_TYPE.OBJECT) {\n"
        ~ "        vals = JSONValue(`{}`.parseJSON);\n";

    static foreach (i; 0..paramNames.length) {
        func ~=
          "        vals[`" ~ paramNames[i] ~ "`] = args[" ~ i.text ~ "];\n";
    }
        func ~=
          "    }\n"; // args.type == JSON_TYPE.ARRAY


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
            static if (isAggregateType!(paramTypes[i])) {
                func ~=
                    "vals[`" ~ paramNames[i] ~ "`].deserialize!(" ~ paramTypes[i].stringof ~ "), ";
            } else {
                func ~=
                    "vals[`" ~ paramNames[i] ~ "`].unwrapValue!" ~ paramTypes[i].stringof ~ ", ";
            }
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
        The "error" dictionary to attach to the Response.

    Example:
    ---
    auto resp = Response(0, getStandardError(StandardErrorCode.InvalidRequest);
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

/** Unwrap a D value from a JSONValue. */
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
    } else static if (isArray!T) {
        T elems;
        foreach (elem; value.array) {
            elems ~= unwrapValue!(ForeachType!T)(elem);
        }
        return elems;
    } else { // JSON Object; return an AA.
        T obj;
        foreach (key, val; value.object) {
            obj[key] = unwrapValue!(KeyType!T)(val);
        }
        return obj;
    }
    assert(0, "Missing JSON value type.");
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
            (Request(
                0,
                "void3params",
                JSONValue(`{"a": 3, "b": false, "c": 2.3}`.parseJSON)),
            api);

    auto r2 = execRPCMethod!(MyAPI, "voidArray")
            (Request(1, "voidArray", JSONValue([1, 2])), api);

    auto r3 = execRPCMethod!(MyAPI, "voidFunc")
            (Request(2, "voidFunc"), api);

    assert(api.void3params_called == true
            && api.voidArray_called == true
            && api.voidFunc_called == true);
}

@test("execRPCMethod executes non-void RPC functions")
unittest {
    auto api = new MyAPI();

    auto r1 = execRPCMethod!(MyAPI, "retBool")
            (Request(0, "retBool"), api);
    assert(r1 == true);

    auto r2 = execRPCMethod!(MyAPI, "retUlong")
            (Request(1, "retUlong", JSONValue(["some string"])), api);
    assert(r2 == 19);
}

@test("executeMethod returns integral values")
unittest {
    auto api = new MyAPI();

    auto r1 = executeMethod(
            Request(0, "retUlong", JSONValue(["some string"])), api);
    assert(r1.id == 0);
    assert(r1.result.unwrapValue!ulong == 19);

    auto r2 = executeMethod(Request(1, "retInt", JSONValue([5])), api);
    assert(r2.id == 1);
    assert(r2.result.integer == 6);
}

@test("executeMethod returns floating-point values")
unittest {
    auto api = new MyAPI();

    auto resp = executeMethod(Request(0, "retFloat"), api);
    assert(resp.result.floating > 1.22 && resp.result.floating < 1.24);
}

@test("executeMethod returns boolean values")
unittest {
    auto api = new MyAPI();

    auto r1 = executeMethod(Request(0, "retTrue"), api);
    assert(r1.id == 0);
    assert(r1.result == JSONValue(true));

    auto r2 = executeMethod(Request(1, "retFalse"), api);
    assert(r2.id == 1);
    assert(r2.result == JSONValue(false));
}

@test("executeMethod returns string values")
unittest {
    auto api = new MyAPI();

    auto r1 = executeMethod(Request(0, "retString"), api);
    assert(r1.result.unwrapValue!string == "testing");
}

@test("executeMethod handles non-integral IDs")
unittest {
    auto api = new MyAPI();

    auto r1 = executeMethod(Request("my_id", "retString"), api);
    assert(r1.id!string == "my_id");

    auto r2 = executeMethod(Request(null, "retString"), api);
    assert(r2.id!(typeof(null)) == null);
}

@test("executeMethod can execute functions and pass data not in the ASCII character range")
unittest {
    auto api = new MyAPI();

    auto ret = executeMethod(
            Request("áðý", "øbæårößΓαζ", JSONValue(["éçφωτz"])), api);
    assert(ret.result == JSONValue("éçφωτzâいはろшь ж๏เ"));
}

@test("executeMethod returns error when the method doesn't exist")
unittest {
    auto api = new MyAPI();
    auto r1 = executeMethod(Request(0, "noFunctionHere"), api);

    assert(r1.id!long == 0);
    assert(r1.error["code"].integer == StandardErrorCode.MethodNotFound,
            "Wrong error.");

    assert(r1.error["data"]["method"].str == "noFunctionHere",
            "Did not include method.");
}

@test("executeMethod returns error on invalid request ID")
unittest {
    auto api = new MyAPI();

    auto req = Request(0, "retTrue");
    req._data["id"] = JSONValue([1, 2]);
    auto resp = executeMethod(req, api);

    assert(resp._data["id"] == JSONValue([1, 2]));
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

    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":0,"result":null}`;
    auto resp = client.call("func", `{ "val": 3 }`.parseJSON);
    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":1,"result":null}`;
    auto resp2 = client.call("func", JSONValue([3]));
}

@test("[DOCTEST] RPCClient example: call(Request) allows non-integral IDs")
unittest {
    interface MyAPI { bool my_func(int[] values); }
    auto sock = new FakeSocket();
    auto transport = TCPTransport(sock);
    auto client = new RPCClient!MyAPI(transport);

    sock.receiveReturnValue = `{"jsonrpc":"2.0","id":"my_id","result":true}`;
    auto req = Request("my_id", "my_func", JSONValue([1, 2, 3]));
    auto response = client.call(req);

    assert(unwrapValue!bool(response.result) == true);
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
            Request("func", `{"val":3}`.parseJSON)._data.toJSON);

    client.notify("func", JSONValue([3]));
    assert(sock.lastDataSent == Request("func", `[3]`.parseJSON)._data.toJSON);
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
            batchReq("func1", JSONValue([50])),
            batchReq("func1", JSONValue([-1]), Yes.notify),
            batchReq("func2", JSONValue(["hello"])),
            batchReq("func3", JSONValue()),
            batchReq("func1", JSONValue([123]), Yes.notify)
    );

    assert(responses.length == 3);
    assert(responses[0].result == JSONValue(null), "Incorrect [0] result");
    assert(responses[1].result == JSONValue(123), "Incorrect [1] result");
    assert(responses[2].result == JSONValue(0), "Incorrect [2] result");
}
