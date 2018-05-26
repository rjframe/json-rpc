import std.stdio;
import jsonrpc;

enum hostname = "127.0.0.1";
enum ushort port = 54321;

struct MyObject {
    this(int i, string s) { num = i; str = s; }
    int num;
    string str;
}

// TODO
struct EmbeddedObject {
    int j;
}

interface API {
    MyObject getObject();
    void setObject(MyObject obj_);
    MyObject getAndReplace(MyObject obj);
}

class ServeFunctions {
    MyObject getObject() { return MyObject(5, "five"); }

    void setObject(MyObject obj_) {
        import std.stdio;
        writeln("Setting ", obj_);
        myObject = obj_;
        writeln("Finished");
    }

    MyObject getAndReplace(MyObject obj) {
        auto tmp = myObject;
        myObject = obj;
        return tmp;
    }

    // Cannot be private - must be visible to jsonrpc library.
    MyObject myObject;
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

    client.call("setObject", MyObject(5, "five").serialize());

    auto response = client.call("getObject");
    writeln("Returned value: ", response.result.deserialize!MyObject());

    writeln("Press ^C to exit.");
}
