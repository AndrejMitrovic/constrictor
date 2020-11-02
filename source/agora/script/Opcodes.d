/*******************************************************************************

    Contains the supported opcodes for the basic execution engine (non-webASM)

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.script.Opcodes;

import std.traits : EnumMembers;

/*******************************************************************************

    The supported opcodes for the script execution engine.

    Opcodes named `CHECK_*` push their result to the stack,
    whereas `VERIFY_*` opcodes will cause the script execution to fail.

    We can encode up to 255 opcodes (one of which is INVALID to halt execution).

    Note that the range of values between `PUSH_BYTES_1` and `PUSH_BYTES_64`
    encodes a push to the stack between 1 .. 64 bytes. This range was chosen
    to allow pushing one of our largest types (Hash) in a single opcode,
    but is small enough to leave room for introducing other 1-byte opcodes.

    For pushes of data longer than 64 bytes use one of the `PUSH_DATA_*`
    opcodes.

*******************************************************************************/

public enum OP : ubyte
{
    /// Executing this is an error and will cause script execution to fail.
    /// Purposefully located first to default OPs to errors.
    INVALID = 0x45,

    /// Used to encode a small data push to the stack (up to 64 bytes),
    /// may be used with `case PUSH_BYTES_1: .. case PUSH_BYTES_64:` syntax.
    PUSH_BYTES_1 = 0x01,

    /// Ditto
    PUSH_BYTES_64 = 0x40, // 64 decimal

    /// The next 1 byte contains the number of bytes to push onto the stack.
    /// This opcode may not be used to encode data pushes of `<= 64` bytes.
    /// PUSH_BYTES_* must be used for this purpose instead.
    PUSH_DATA_1 = 0x41,

    /// The next 2 bytes (ushort in LE format) contains the number of bytes to
    /// push onto the stack.
    /// This opcode may not be used to encode data pushes of `<= 255` bytes.
    /// `PUSH_DATA_1` must be used for this purpose instead.
    PUSH_DATA_2 = 0x42,

    /// This opcode may be reserved for a future PUSH_DATA_4.
    // OP_RESERVED_1 = 0x43,

    /// Pushes True onto the stack. Used by conditional opcodes.
    /// Additionally if after lock + unlock script execution the only
    /// value on the stack is TRUE, the script will be considered valid.
    /// Any other value (FALSE or otherwise) on the top of the stack
    /// after execution will cause the script to fail.
    TRUE = 0x44,

    /// Pushes False onto the stack. Used by conditional opcodes.
    FALSE = 0x00,

    /// Conditionals
    IF = 0x46,
    NOT_IF = 0x47,
    ELSE = 0x48,
    END_IF = 0x49,

    /// Pop the top item on the stack, hash it, and push the hash to the stack.
    /// Note that the item being hashed is a byte array.
    HASH = 0x4A,

    /// Duplicate the item on the stack. Equivalent to `value = pop()` and
    /// `push(value); push(value);`
    DUP = 0x4B,

    /// Pops two items from the stack. Checks that the items are equal to each
    /// other, and pushes either `TRUE` or `FALSE` to the stack.
    CHECK_EQUAL = 0x4C,

    /// Ditto, but instead of pushing to the stack it will cause the script
    /// execution to fail if the two items are not equal to each other.
    VERIFY_EQUAL = 0x4D,

    /// Pops two items from the stack. The two items must be a Point (Schnorr),
    /// and a Signature. If the items cannot be deserialized as a Point and
    /// Signature, the script validation fails.
    /// The signature is then validated using Schnorr, if the signature is
    /// valid then `TRUE` is pushed to the stack.
    CHECK_SIG = 0x4E,
}

/*******************************************************************************

    Converts the byte to an opcode,
    or returns false if it's an unrecognized opcode.

    Params:
        value = the byte containing the opcode
        opcode = will contain the opcode if it was recognized

    Returns:
        true if the value is a recognized opcode

*******************************************************************************/

public bool toOPCode (ubyte value, out OP opcode) pure nothrow @safe @nogc
{
    switch (value)
    {
        foreach (member; EnumMembers!OP)
        {
            case member:
            {
                opcode = member;
                return true;
            }
        }

        default:
            break;
    }

    if (value >= 1 && value <= 64)  // PUSH_BYTES_1 .. PUSH_BYTES_64
    {
        opcode = cast(OP)value;  // dirty, but avoids need to define all pushes
        return true;
    }

    return false;
}

///
pure nothrow @safe @nogc unittest
{
    OP op;
    assert(0x00.toOPCode(op) && op == OP.FALSE);
    assert(0x4A.toOPCode(op) && op == OP.HASH);
    assert(!255.toOPCode(op));
    assert(1.toOPCode(op) && op == OP.PUSH_BYTES_1);
    assert(32.toOPCode(op) && op == cast(OP)32);
    assert(64.toOPCode(op) && op == OP.PUSH_BYTES_64);
}

/*******************************************************************************

    Check if the opcode is a conditional

    Params:
        opcode = opcode to check

    Returns:
        true if the opcode is one of the conditional opcodes

*******************************************************************************/

public bool isConditional (OP opcode) pure nothrow @safe @nogc
{
    switch (opcode)
    {
        case OP.IF, OP.NOT_IF, OP.ELSE, OP.END_IF:
            return true;
        default:
            return false;
    }
}

///
pure nothrow @safe @nogc unittest
{
    assert(OP.IF.isConditional);
    assert(OP.NOT_IF.isConditional);
    assert(OP.ELSE.isConditional);
    assert(OP.END_IF.isConditional);
    assert(!OP.TRUE.isConditional);
    assert(!OP.HASH.isConditional);
}

/*******************************************************************************

    Check if the opcode contains a payload

    Params:
        opcode = opcode to check

    Returns:
        true if the opcode contains a payload

*******************************************************************************/

public bool isPayload (OP opcode) pure nothrow @safe @nogc
{
    return opcode >= OP.PUSH_BYTES_1 && opcode <= OP.PUSH_DATA_2;
}

///
pure nothrow @safe @nogc unittest
{
    assert(OP.PUSH_BYTES_1.isPayload);
    assert(OP.PUSH_BYTES_64.isPayload);
    assert(OP.PUSH_DATA_1.isPayload);
    assert(OP.PUSH_DATA_2.isPayload);
    assert(!OP.IF.isPayload);
    assert(!OP.NOT_IF.isPayload);
    assert(!OP.TRUE.isPayload);
}