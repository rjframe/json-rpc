import std.stdio;
import jsonrpc;

enum hostname = "127.0.0.1";
enum ushort port = 54321;

interface API {
    void printHello();
    ulong printGreeting(string name);
}

class ServeFunctions {
    void printHello() { writeln("Hello."); }

    ulong printGreeting(string name) {
        writeln("Hello, " ~ name);
        return name.length;
    }
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

    client.printHello();
    client.notify("printGreeting", JSONValue("again!"));

    auto len = client.printGreeting("Some Person!");
    assert(len == "Some Person!".length);
    client.close();

    writeln("Press ^C to exit.");
}
