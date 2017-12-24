# JSON-RPC Server and Client Library

[![Build Status](https://travis-ci.org/rjframe/json-rpc.svg?branch=master)](https://travis-ci.org/rjframe/json-rpc) [![codecov](https://codecov.io/gh/rjframe/json-rpc/branch/master/graph/badge.svg)](https://codecov.io/gh/rjframe/json-rpc)

This is a library to create JSON-RPC servers and clients quickly and use them
simply.

```d
interface MyAPI {
    bool x(int y);
    void a(bool b, int c, string d);
    int i();
}

// These are the callable functions.
// Inheritance isn't necessary (this could be a struct too); it just lets the
// compiler verify the API since we're in the same module.
class APIImpl : MyAPI {
    bool x(int y) { return (y > 5); }
    void a(bool b, int c, string d) { return; }
    int i() { return 100; };
}

// We'll run this in a new thread for this example.
void startServer(string host, string port) {
    import core.thread : Thread;
    import core.time : dur;
    auto server = new RPCServer!APIImpl(host, port);
    server.listen();
    Thread.sleep(dur!"seconds"(3)); // Give it time to start up before connecting.
}

void main() {
    import std.parallelism : task;
    task!startServer("127.0.0.1", 54321).executeInNewThread;

    // Now create a client.
    auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

    // These are blocking calls that return the function's response.
    client.a(true, 2, "somestring");
    assert(client.x(3) == false);
    assert(client.i() == 100);

    // `call` is blocking, but returns the RPCResponse from the server.
    auto resp2 = client.call(x, 3);

    // Non-blocking calls are possible too.
    auto id = client.callAsync(i);
    RPCResponse asyncResponse;
    while (! client.response(id, asyncResponse)) {}
    // Do something with asyncResponse here.
}
```

Current status:

* The client should be good; needs some cleanup.
* The server will execute async functions.

Documentation is currently in the docs/ folder and is not rebuilt with every
commit; I'll host them properly it once the project is ready.

## Non-conforming details

* (tmp) All IDs must be integral; JSON-RPC allows NULL and string IDs as well.
* (tmp) IDs are required in requests; Notifications are not yet supported.
* (tmp) Only TCP sockets are supported as a transport protocol.

## Redesign plan

* The server should not throw exceptions; it should provide a hook to log errors,
  and send an error response to the client.
* Pull the sockets in the client and server into a transport object; writing new
  transports will allow supporting alternative protocols (HTTP, etc.).

## Testing

The [tested](http://code.dlang.org/packages/tested) library is an optional
dependency for unit testing; to use it, add the following `dub.selections.json`
to your project root:

```json
{
    "fileVersion": 1,
    "versions": {
        "tested": "0.9.4"
    }
}
```
