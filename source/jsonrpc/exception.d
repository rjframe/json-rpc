/** Exception base class inspired by Adam Ruppe's exception.d

    Error messages include the names and values of relevant data, but no
    further introspection capabilities.
*/
module jsonrpc.exception; @safe:

// I cannot define an exception within the unittest scope for testing/examples.
///
unittest {
    /* Where InvalidArgumment is defined as:
    class InvalidArgument : Exception {
        this() { super(""); }
    }
    */

    void func(bool one, bool two) {
        if (one == two) {
            raise!(InvalidArgument, one, two)("The values shouldn't match!");
        }
    }
    func(false, true);
}

/** Raised when invalid data is passed as an argument to a function. */
class InvalidArgument : Exception {
    this() { super(""); }
}

/** Raised when invalid data is received by the client or server. */
class InvalidDataReceived : Exception {
    this() { super(""); }
}

/** Raised when there's a network connection error. */
class ConnectionException : Exception {
    this() { super(""); }
}

/** Raised when a function call via RPCClient.opDispatch receives an error
    response.
*/
class RPCErrorResponse : Exception {
    this() { super(""); }
}

/** Raised when attempting to access a JSONValue via a different type than the
    underlying type.
*/
class IncorrectType : Exception {
    this() { super(""); }
}

package:

/** Generate and throw an exception.

    Additional data can be provided, both for inspection by catching code and
    for viewing/logging if unhandled.

    Template_Parameters:
        ExceptionClass = The exception class to throw.
        T...           = A list of objects to include as part of the exception.

    Params:
        msg =   An optional message concerning the exception.
        file =  The file in which the exception was raised.
        line =  The line number at which the exception was raised.
*/
void raise(ExceptionClass, T...)(
        string msg = "",
        string file = __FILE__,
        size_t line = __LINE__) {

    class Except : ExceptionClass {
        this(string message, string file, size_t line) {
            super.file = file;
            super.line = line;
            msg ~= message ~ "\n  Data:";
            foreach (i, obj; T) {
                import std.string : format;
                msg ~= "\n\t%s: %s".format(__traits(identifier, T[i]), obj);
            }
        }
    }
    throw new Except(msg, file, line);
}

/** Raise the specified exception of the provided expression evaluates to false.

    Behavior is similar to $(D_INLINECODE assert() ) but throws an exception on
    failure.

    Example:
    ---
    enforce!(OutOfRange, myvar)(myvar > 0, "myvar must be greater than 0");
    ---
*/
auto enforce(ExceptionClass, T...)(
        bool val,
        string msg = "",
        string file = __FILE__,
        size_t line = __LINE__) {
    if (!val) raise!(ExceptionClass, T)(msg, file, line);
    return val;
}
