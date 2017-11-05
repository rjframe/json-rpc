/** JSON-RPC 2.0 protocol library. */
module jsonrpc.jsonrpc;

import std.json;
import jsonrpc.exception;

/** An RPC request constructed by the client to send to the RPC server. */
struct RPCRequest {
    private:

    int _id;
    JSONValue _params;
    string _method;

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

    /** Set the parameters to the method that will be called.

        The JSONValue must be an Object or Array.

        Params:
            val =   A JSON Object or array.

        Throws:
            InvalidParameterException if val is not a JSON Object or array.
    */
    @property void params(JSONValue val)
    {
        if (val.type != JSON_TYPE.OBJECT && val.type != JSON_TYPE.ARRAY) {
            raise!(InvalidParameterException, val)
                    ("Invalid JSON-RPC method parameter type.");
        }
        _params = val;
    }

    /** Sends a JSON string as the parameters for the method.

        The string must be a JSON Object or array.

        Params:
            json =   A JSON string.

        Throws:
            InvalidParameterException if the json string is not a JSON Object or
            array.
    */
    @property void params(string json) {
        params(json.parseJSON);
    }
}

/** The RPC server's response sent to clients. */
struct RPCResponse {
    private:

    // Note: Only one of _result, _error will be present.
    JSONValue _result;
    int _id;

    package:

    Error _error;

    /** Construct a response to send to the client. */
    this(int id, JSONValue result) {
        _id = id;
        _result = result;
    }

    /** Construct an error response to send to the client. */
    this(int id, Error error) {
        _id = id;
        _error = error;
    }

    /** Construct a predefined error response to send to the client. */
    this(int id, ErrorCode error) {
        _id = id;
        _error = Error(error);
    }

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
    import std.socket;

    private int _nextId;
    private Socket _socket;

    public:

    /** Instantiate an RPCClient bound to the specified host.

        Params:
            host =  The hostname or address of the RPC server.
            port =  The port at which to connect to the server.
    */
    this(string host, ushort port) {
        assert(0, "constructor not implemented.");
    }

    /** Make a non-blocking remote call with natural syntax.

        Any function (not present on the RPC client itself) that is present in
        the remote API can be called as if it was a member of the RPC client,
        and that function call will be forwarded to the remote server.

        Params:
            args = The arguments of the remote function to call.
    */
    void opDispatch(string apiFunc, ARGS...)(ARGS args) {
        import std.traits;

        static if (hasMember!(API, apiFunc)) {
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
            callAsync(apiFunc, jsonArgs);
        } else raise!(InvalidArgumentException!(args)("Argument does not match interface."));
    }

    /** Make a blocking remote function call.

        Params:
            func =   The name of the remote function to call.
            params = A valid JSON array or Object containing the function
                     parameters.

        Returns: The server's response.
    */
    RPCResponse call(string func, string params) {
        auto id = callAsync(func, params);
        RPCResponse resp;
        while(! response(id, resp)) {}

        assert(0, "Call not implemented.");
    }

    /// ditto
    RPCResponse call(string func, JSONValue params) { assert(0); }

    /** Make a non-blocking remote function call.

        Use the returned request ID to obtain the server's response.

        Params:
            func =  The name of the remote function to call.
            params = A valid JSON array or Object containing the function
                     parameters.

        Returns: The ID of the request. This ID will be necessary to later
                 retrieve the server response.
    */
    int callAsync(string func, string params) {
        auto id = callAsync(func, params);
        RPCResponse resp;
        while(! response(id, resp)) {}

        assert(0, "callAsync not implemented.");
    }

    /// ditto
    int callAsync(string func, JSONValue params) {
        assert(0, "callAsync not implemented.");
    }

    /** Check for a response from an asynchronous remote call.

        Params:
            id =       The ID of the request for which to check for a response.
            response = A RPCResponse object in which to return the response if
                       available.

        Returns: true if the response is ready; otherwise, false.
    */
    bool response(int id, out RPCResponse response) {
        assert(0, "response not implemented.");
    }
}

///
unittest {
    interface MyAPI {
        bool x(int y);
        void a(bool b, int c, string d);
        int i();
    }

    auto client = new RPCClient!MyAPI("127.0.0.1", 54321);
    client.a(true, 2, "somestring");
    client.x(3);
    client.i;
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
    Socket _socket;

    public:

    /** Construct an RPCServer!API object.

        api =   The instantiated class or struct providing the RPC API.
    */
    this(API api) { _api = api; }

    /** Listen for connections.

        Params:
            host = The hostname or IP address on which to listen.
            port = The port on which to listen.
    */
    void listen(string host, ushort port) {
        // TODO: lookup hostnames. getAddress is supposed to - why can't I bind
        // localhost? (because it's special?)
        auto s = new TcpSocket();
        s.bind(getAddress(host, port)[0]);
        s.listen(1);
    }
}

///
unittest {
    class MyAPI {
        bool f() { return true; }
    }

    auto server = new RPCServer!MyAPI(new MyAPI);
    server.listen("127.0.0.1", 54321);
}
