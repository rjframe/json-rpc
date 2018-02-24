# JSON-RPC Server and Client Library

[![Build Status](https://travis-ci.org/rjframe/json-rpc.svg?branch=master)](https://travis-ci.org/rjframe/json-rpc) [![codecov](https://codecov.io/gh/rjframe/json-rpc/branch/master/graph/badge.svg)](https://codecov.io/gh/rjframe/json-rpc)

This is a library to create JSON-RPC servers and clients quickly and use them
simply.

```d
interface MyAPI {
    bool one(int y);
    void two(bool b, int c, string d);
    int three();
}

// These are the callable functions.
// Inheritance isn't necessary.
class APIImpl : MyAPI {
    bool one(int y) { return (y > 5); }
    void two(bool b, int c, string d) { return; }
    int three() { return 100; };
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
    client.two(true, 2, "somestring");
    assert(client.one(3) == false);
    assert(client.three() == 100);

    // `call` returns the RPCResponse from the server.
    auto resp = client.call("one", 3);
    assert(resp.result == JSONValue(false));

    // `notify` executes a function, but doesn't get a response from the server.
    client.notify("one", 3);

    // Send a batch.
    import std.typecons : Yes;
    import std.json : parseJSON;
    auto responses = client.batch(
            batchReq("one", JSONValue(3)),
            batchReq("one", JSONValue(3), Yes.notify),
            batchReq("two", JSONValue(`{"b": false, "c": -50, "d": "fifty"}`.parseJSON)),
            batchReq("three", JSONValue()),
            batchReq("three", JSONValue(), Yes.notify)
    );

    assert(responses.length == 3); // Notifications don't return a response.
    assert(responses[2].result == JSONValue(100));
}
```

This is currently usable but may not be stable/reliable (so, usable-ish).

Documentation is currently in the docs/ folder and is not rebuilt often; I'll
host them properly it once the project is ready.

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
