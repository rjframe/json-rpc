import jsonrpc;
import std.stdio;

enum hostname = "127.0.0.1";
enum ushort port = 54321;

interface API {
    void printHello();
    int printGreeting(string name);
}

class ServeFunctions {
    void printHello() { writeln("Hello."); }

    int printGreeting(string name) {
        writeln("Hello, " ~ name);
        return name.length;
    }
}

void main(string[] args)
{
    import core.thread : Thread;
    import core.time : dur;

    auto t = new Thread({
        auto rpc = new RPCServer!ServeFunctions(hostname, port);
        rpc.listen;
    });
    t.isDaemon = true;
    t.start;

    Thread.sleep(dur!"seconds"(3));
    auto client = new RPCClient!API(hostname, port);

    import std.json;
    auto a = client.callAsync("printHello");
    auto b = client.callAsync("printGreeting", JSONValue("Some Person!"));
    assert(b.result == JSONValue(3));
    Thread.sleep(dur!"seconds"(3));

    client.printHello();
    auto len = client.printGreeting("again!");
    assert(len == "Some Person!".length);
    Thread.sleep(dur!"seconds"(3));
}
