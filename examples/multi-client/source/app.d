import std.stdio;
import jsonrpc;

enum hostname = "127.0.0.1";
enum ushort port = 54321;

interface API {
    int add(int a, int b);
}

class ServeFunctions : API {
    int add(int a, int b) { return a + b; }
}

void main(string[] args)
{
    import core.thread : Thread;
    import core.time : dur;
    import std.range : iota;

    writeln("Starting server...");
    auto t = new Thread({
        auto rpc = new RPCServer!ServeFunctions(hostname, port);
        rpc.listen;
    });
    t.isDaemon = true;
    t.start;

    Thread.sleep(dur!"seconds"(2));

    writeln("Starting ten clients...");
    writeln("Press ^C to exit.");

    foreach (i; iota(10)) {
        writeln("Starting thread ", i);
        new Thread({
            auto client = new RPCClient!API(hostname, port);
            foreach (j; iota(5)) {
                auto sum = client.add(j, j+5);
                writeln("(j, sum): (", j, ", ", sum, ").");
                assert(sum == (j+(j+5)));
            }
        }).start;
    }
}
