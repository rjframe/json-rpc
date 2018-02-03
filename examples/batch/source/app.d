import std.stdio;
import jsonrpc;

enum hostname = "127.0.0.1";
enum ushort port = 54321;

interface API {
    void someFunc(int a);
    void otherFunc();
    long add(int one, int two);
}

class ServeFunctions {
    void someFunc(int a) {}
    void otherFunc() {}
    long add(int one, int two) { return one + two; }
}

void main(string[] args)
{
    import std.json;
    import core.thread : Thread;
    import core.time : dur;

    writeln("Starting server...");
    auto t = new Thread({
        auto rpc = new RPCServer!ServeFunctions(hostname, port);
        rpc.listen;
    });
    t.isDaemon = true;
    t.start;

    Thread.sleep(dur!"seconds"(2));

    writeln("Starting client...");
    auto client = new RPCClient!API(hostname, port);

    import std.typecons : Yes;
    auto responses = client.batch(
            batchReq("someFunc", JSONValue(5)),
            batchReq("someFunc", JSONValue(6), Yes.notify),
            batchReq("add", JSONValue([1, 2])),
            batchReq("someFunc", JSONValue(7)),
            batchReq("otherFunc", JSONValue()),
            batchReq("someFunc", JSONValue(8)),
            batchReq("add", JSONValue([1, -52]), Yes.notify),
            batchReq("add", JSONValue(`{"one":1,"two":-52}`.parseJSON))
    );

    assert(responses.length == 6); // Notifications don't return a response.
    assert(responses[0].result == JSONValue(null));
    assert(responses[1].result == JSONValue(3));
    assert(responses[3].result == JSONValue(null));
    assert(responses[5].result == JSONValue(-51));

    foreach (resp; responses) {
        writeln(resp);
    }

    writeln("Press ^C to exit.");
}
