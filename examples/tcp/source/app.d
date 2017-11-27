import jsonrpc;
import std.stdio;

enum hostname = "127.0.0.1";
enum ushort port = 54321;

interface API {
    void printHello();
    int printGreeting(string name);
}

class ServeFunctions /* Could add `: API` here. */ {
    void printHello() { writeln("Hello."); }
    int printGreeting(string name) {
        writeln("Hello, " ~ name);
        return name.length;
    }
}

void startServer() {
    writeln("listening in new thread");
    auto rpc = new RPCServer!ServeFunctions(hostname, port);
    rpc.listen;
}

void main(string[] args)
{
    import core.thread : Thread;
    import core.time : dur;
    import std.parallelism : task;

    task!startServer.executeInNewThread;

    Thread.sleep(dur!"seconds"(3));
    auto client = new RPCClient!API(hostname, port);

    import std.json;
    auto a = client.callAsync("printHello");
    auto b = client.callAsync("printGreeting", JSONValue("Some Person!"));

    //client.printHello;
    //auto len = client.printGreeting("Some Person!");
    //assert(len == "Some Person!".length);
}
