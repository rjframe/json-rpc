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
// Inheritance isn't necessary.
class APIImpl : MyAPI {
    bool x(int y) { return (y > 5); }
    void a(bool b, int c, string d) { return; }
    int i() { return 100; };
}

// We'll run this in a new thread for this example.
void startServer(string host, string port) {
    auto server = new RPCServer!APIImpl(host, port);
    server.listen();
}

void main() {
    import core.thread : Thread;
    import core.time : dur;
    import std.parallelism : task;

    task!startServer("127.0.0.1", 54321).executeInNewThread;
    Thread.sleep(dur!"seconds"(3)); // Give it time to start up before connecting.

    // Now create a client.
    auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

    // These are calls that return the function's response.
    client.a(true, 2, "somestring");
    assert(client.x(3) == false);
    assert(client.i() == 100);

    // `call` returns the RPCResponse from the server.
    import std.stdio : writeln;
    auto resp2 = client.call("x", 3);
    writeln(resp2.result);

    // `notify` executes a function, but doesn't get a response from the server.
    client.notify("x", 3);
}
```

Current status:

* This is currently usable but not stable (so, usable-ish).

Documentation is currently in the docs/ folder and is not rebuilt often; I'll
host them properly it once the project is ready.

## Non-conforming details

* (tmp) Batches are not supported.
* (tmp) The server doesn't construct error responses yet.

## Redesign plan

* The server should not throw exceptions; it should provide a hook to log errors,
  and send an error response to the client.
  transports will allow supporting alternative protocols (HTTP, etc.).
* Need to support a function registry on the server, and runtime function lists
  on the client. The client especially shouldn't be required to know its API at
  compile-time.

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
