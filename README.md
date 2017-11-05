# JSON-RPC Server and Client Library

There's not much here currently; either check back later or (perhaps) take a
look at the code and show me where I've lost my way.

Documentation is currently in the docs/ folder; I'll host it once the project is
ready.

```
interface MyAPI {
    bool x(int y);
    void a(bool b, int c, string d);
    int i();
}

class APIImpl : MyAPI {
    bool x(int y) { return (y > 5); }
    void a(bool b, int c, string d) { return; }
    int i() { return 100; };
}

auto server = new RPCServer!APIImpl(new APIImpl());
server.listen("127.0.0.1", 54321);


auto client = new RPCClient!MyAPI("127.0.0.1", 54321);
client.a(true, 2, "somestring");
client.x(3);
client.i;
```
