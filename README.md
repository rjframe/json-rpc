# JSON-RPC Server and Client Library

There's not much here currently; either check back later or (perhaps) take a
look at the code and show me where I've lost my way.

Documentation is currently in the docs/ folder; I'll host it once the project is
ready.

```
class MyAPI {
    bool f() { return true; }
}

auto server = new RPCServer!MyAPI(new MyAPI());
server.listen("127.0.0.1", 54321);
```
