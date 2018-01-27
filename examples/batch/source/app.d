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
            try {
        auto rpc = new RPCServer!ServeFunctions(hostname, port);
        rpc.listen;
        } catch (Throwable ex) {writeln(ex.msg);}
    });
    t.isDaemon = true;
    t.start;

    Thread.sleep(dur!"seconds"(2));

    writeln("Starting client...");
    auto client = new RPCClient!API(hostname, port);

    import std.typecons : tuple;
    auto responses = client.batch([
            tuple("someFunc", JSONValue(5)),
            tuple("someFunc", JSONValue(6)),
            tuple("add", JSONValue([1, 2])),
            tuple("someFunc", JSONValue(7)),
            tuple("otherFunc", JSONValue()),
            tuple("someFunc", JSONValue(8)),
            tuple("add", JSONValue([1, -52])),
            tuple("add", JSONValue(`{"one":1,"two":-52}`.parseJSON))
    ]);

    assert(responses[0].result == JSONValue(null));
    assert(responses[2].result == JSONValue(3));
    assert(responses[4].result == JSONValue(null));
    assert(responses[6].result == JSONValue(-51));

    foreach (resp; responses) {
        writeln(resp);
    }

    writeln("Press ^C to exit.");
}
