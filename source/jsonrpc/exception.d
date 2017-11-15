/** Exception base class inspired by Adam Ruppe's exception.d */
module jsonrpc.exception;

/** Generate and throw an exception.

    Additional data can be provided, both for inspection by catching code and
    for viewing/logging if unhandled.

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

// I cannot define an exception within the unittest scope for testing/examples.
///
unittest {
    /* Where InvalidArgummentException is defined as:
    class InvalidArgumentException : Exception {
        this() { super(""); }
    }
    */

    void func(bool one, bool two) {
        if (one == two) {
            raise!(InvalidArgumentException, one, two)("The values shouldn't match!");
        }
    }
    func(false, true);
}

/** Raised when attempting to assign parameters other than an array or
    JSON Object to a Request.
*/
class InvalidParameterException : Exception {
    this() { super(""); }
}

/** Raised when invalid data is passed as an argument to a function. */
class InvalidArgumentException : Exception {
    this() { super(""); }
}

/** Raised when invalid data is received by the client or server. */
class InvalidDataReceivedException : Exception {
    this() { super(""); }
}

/** Raised when data did not send properly. */
class FailedToSendDataException : Exception {
    this() { super(""); }
}
