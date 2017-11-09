# JSON-RPC Server and Client Library

This is a library to create JSON-RPC servers and clients quickly and use them
simply.

```
interface MyAPI {
    bool x(int y);
    void a(bool b, int c, string d);
    int i();
}

/// These are the callable functions.
class APIImpl : MyAPI {
    bool x(int y) { return (y > 5); }
    void a(bool b, int c, string d) { return; }
    int i() { return 100; };
}

auto server = new RPCServer!APIImpl(new APIImpl(), "127.0.0.1", 54321);
server.listen();


// Now create a client.
auto client = new RPCClient!MyAPI("127.0.0.1", 54321);

// These are blocking calls that return an RPCResponse.
client.a(true, 2, "somestring");
auto response = client.x(3);
auto resp2 = client.call(x, 3);

// Non-blocking calls are possible too.
auto id = client.callAsync(i);
RPCResponse asyncResponse;
while (! client.response(id, asyncResponse)) {}
// Do something with asyncResponse here.
```

This is not functional yet, so you'll need to check back later.

Documentation is currently in the docs/ folder; I'll host properly it once the
project is ready.

## Testing

The [tested](http://code.dlang.org/packages/tested) library is an optional
dependency; to use it, add the following `dub.selections.json` to your project
root:
```
{
    "fileVersion": 1,
    "versions": {
        "tested": "0.9.4"
    }
}
```
