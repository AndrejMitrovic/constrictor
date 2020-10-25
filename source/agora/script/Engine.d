/*******************************************************************************

    Contains the script execution engine (non-webASM)

    Copyright:
        Copyright (c) 2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.script.Engine;

import agora.common.crypto.ECC;
import Schnorr = agora.common.crypto.Schnorr;
import agora.common.Hash;
import agora.consensus.data.Transaction;
import agora.script.Codes;
import agora.script.ScopeCondition;
import agora.script.Script;
import agora.script.Stack;

import ocean.core.Test;

import std.bitmanip;
import std.range;
import std.traits;

version (unittest)
{
    import std.stdio;
}

private enum Type
{
    Lock,
    Unlock,
    //Redeem  // needs to be a separate type?
}

/// The engine executes scripts, and returns a value or throws
public class Engine
{
    // tx: the transaction that's trying to spend (used for the commitment check)
    public string execute (in Script lock, in Script unlock,
        in Transaction tx)
    {
        if (auto error = lock.isInvalidSyntaxReason())
            return "Lock script error: " ~ error;

        if (auto error = unlock.isInvalidSyntaxReason())
            return "Unlock script error: " ~ error;

        // todo: check script weight:
        // - max opcode length
        // - num of opcodes
        // - weight of each opcode (e.g. sig checks more expensive than ADD)
        // might want to calculate the weight in an out parameter in
        // isInvalidSyntaxReason()

        // todo: check *executed* instructions and that they don't
        // go over the configured (consensus) limit

        // non-standard scripts (meaning non-recognized ones with unexpected opcodes)
        // are not relayed to the network, even though they are technically valid.
        // see: https://bitcoin.stackexchange.com/questions/73728/why-can-non-standard-transactions-be-mined-but-not-relayed/
        // however this only makes sense in the scope of PoW. If a miner did spend
        // the time to mine a block, then the time they spent on running the contract
        // can be verified not to DDoS the system.

        // for the locking script the rule is:
        // valid only if there is one element on the stack: 1
        // invalid if: stack is empty, top element is not 1,
        // there is more than 1 element on the stack,
        // the script exits prematurely
        // for the unlocking script we have different validation rules.

        // the unlock script must be ran separately from the lock script
        // to avoid a form of vulnerability:
        // https://bitcoin.stackexchange.com/q/80258/93682

        Stack stack;
        if (auto error = this.executeScript(Type.Unlock, unlock, stack, tx))
            return error;

        if (auto error = this.executeScript(Type.Lock, lock, stack, tx))
            return error;

        return null;
    }

    // based on the type, this may return an error message:
    // unlock script => only if there are no dangling operators it's valid,
    //                  but stack may have any data on it
    // lock script => only if there is a TRUE value on the stack it's valid
    private string executeScript (in Type type, in Script script,
        ref Stack stack, in Transaction tx)
    {
        static immutable ubyte[1] TRUE = [1];
        static immutable ubyte[1] FALSE = [0];

        // if *any* items are false, then the current execution
        // state is false, and we continue executing next
        // instructions. however the fExec level is set to false,
        // until an ELSE or ENDIF sets it to true (I think),
        // and then we can execute code again.

        // todo: verify stack data pushes via CheckMinimalPush(),
        // it seems it's related to BIP62 where pushes can be
        // encoded in different ways. Note: BIP141 (segwit)
        // largely replaces BIP62, so we may not require
        // the validation in CheckMinimalPush(). It is likely
        // still there for compatibility reasons.

        // todo: check max stack size
        // todo: do not implement alt stack, it's unnecessary

        // todo: do not add any more support other than the bare
        // minimum for script validation. e.g. don't add OP_ADD support
        // because this requires emulating a specific virtual machine
        // platform which handles integer arithmetic the same on all platforms.

        ScopeCondition sc;
        const(ubyte)[] bytes = script[];
        while (!bytes.empty())
        {
            const OP opcode = bytes.front.toOPCode();
            bytes.popFront();

            switch (opcode)
            {
                case OP.PUSH_DATA_1:
                    pushToStack!(OP.PUSH_DATA_1)(stack, bytes);
                    break;

                case OP.PUSH_DATA_2:
                    pushToStack!(OP.PUSH_DATA_2)(stack, bytes);
                    break;

                case OP.PUSH_BYTES_1: .. case OP.PUSH_BYTES_64:
                    const payload_size = opcode;  // encoded in the opcode
                    if (bytes.length < payload_size)
                        assert(0);  // should have been validated

                    stack.push(bytes[0 .. payload_size]);
                    bytes.popFrontN(payload_size);
                    break;

                case OP.DUP:
                    if (stack.empty)
                        return "DUP opcode requires an item on the stack";

                    auto top = stack.peek();
                    stack.push(top);
                    break;

                case OP.HASH:
                    if (stack.empty)
                        return "HASH opcode requires an item on the stack";

                    auto top = stack.pop();
                    const Hash hash = hashFull(top);
                    stack.push(hash[]);
                    break;

                case OP.VERIFY_EQUAL:
                    if (stack.count() < 2)
                        return "VERIFY_EQUAL opcode requires two items on the stack";

                    auto a = stack.pop();
                    auto b = stack.pop();
                    if (a != b)
                        return "VERIFY_EQUAL operation failed";
                    break;

                case OP.CHECK_SIG:
                    // if changed, check assumptions
                    static assert(Point.sizeof == 32);
                    static assert(Signature.sizeof == 64);

                    if (stack.count() < 2)
                        return "CHECK_SIG opcode requires two items on the stack";

                    auto key_bytes = stack.pop();
                    if (key_bytes.length != Point.sizeof)
                        return "CHECK_SIG opcode requires 32-byte public key on the stack";
                    if (!isValidPointBytes(key_bytes))
                        return "CHECK_SIG 32-byte public key on the stack is invalid";

                    auto sig_bytes = stack.pop();
                    if (sig_bytes.length != Signature.sizeof)
                        return "CHECK_SIG opcode requires 64-byte signature on the stack";

                    const point = Point(key_bytes);
                    const sig = Signature(sig_bytes);
                    if (Schnorr.verify(point, sig, tx))
                        stack.push(TRUE);
                    else
                        stack.push(FALSE);
                    break;

                default:
                    break;
            }
        }

        final switch (type)
        {
            case Type.Lock:
                if (!stack.empty() && stack.pop() == TRUE)
                    return null;

                // todo: emit diag which OP pushed the last FALSE to stack?
                return "Script failed";

            // todo: check for dangling ops in the bytes array
            case Type.Unlock:
                return null;
        }
    }

    // safer for the tests as it provides its own stack,
    // otherwise leaking this outside can make tests
    // inadvertently depend on intermittent stacks.
    // this overload is alos not taking any transaction,
    // it's not supposed to be tested with unlocking scripts
    version (unittest)
    private string executeScript (in Type type, in Script script)
    {
        Stack stack;
        Transaction tx;
        return this.executeScript(type, script, stack, tx);
    }

    /***************************************************************************

        Reads the length and payload of the associated `PUSH_DATA_*` opcode,
        pushes the payload onto the stack, and advances the `bytes` array
        to the next opcode.

        Params:
            OP = the associated `PUSH_DATA_*` opcode
            stack = the stack to push the payload to
            bytes = the opcode / data byte array

    ***************************************************************************/

    private static void pushToStack (OP op)(ref Stack stack,
        ref const(ubyte)[] bytes) nothrow @safe /*@nogc*/
    {
        static assert(op == OP.PUSH_DATA_1 || op == OP.PUSH_DATA_2);
        alias T = Select!(op == OP.PUSH_DATA_1, ubyte, ushort);
        if (bytes.length < T.sizeof)
            assert(0);  // script should have been validated

        const T size = littleEndianToNative!T(bytes[0 .. T.sizeof]);
        if (size == 0 || size > MAX_STACK_ITEM_SIZE)
            assert(0);  // ditto

        bytes.popFrontN(T.sizeof);
        if (bytes.length < size)
            assert(0);  // ditto

        stack.push(bytes[0 .. size]);  // push to stack
        bytes.popFrontN(size);  // advance to next opcode
    }
}

///
unittest
{
    import agora.common.crypto.ECC;
    import agora.common.crypto.Schnorr;
    import agora.common.Hash;
    import agora.utils.Test;

    Pair kp = Pair.random();
    Transaction tx;
    auto sig = sign(kp, tx);

    const key_hash = hashFull(kp.V);
    Script lock_script = createLockP2PKH(key_hash);
    assert(lock_script.isValidSyntax());

    Script unlock_script = createUnlockP2PKH(sig, kp.V);
    assert(unlock_script.isValidSyntax());

    const invalid_script = Script([255]);
    scope engine = new Engine();
    test!("==")(engine.execute(lock_script, unlock_script, tx), null);

    // invalid scripts / sigs
    test!("==")(engine.execute(invalid_script, unlock_script, tx),
        "Lock script error: Script contains an unrecognized opcode");
    test!("==")(engine.execute(lock_script, invalid_script, tx),
        "Unlock script error: Script contains an unrecognized opcode");
    const bad_sig = sign(kp, "foobar");
    Script bad_sig_unlock = createUnlockP2PKH(bad_sig, kp.V);
    assert(bad_sig_unlock.isValidSyntax());
    test!("==")(engine.execute(lock_script, bad_sig_unlock, tx),
        "Script failed");

    Script bad_key_unlock = createUnlockP2PKH(sig, Pair.random.V);
    test!("==")(engine.execute(lock_script, bad_key_unlock, tx),
        "VERIFY_EQUAL operation failed");
}

// OP.DUP
unittest
{
    scope engine = new Engine();
    test!("==")(engine.executeScript(Type.Unlock, Script([OP.DUP])),
        "DUP opcode requires an item on the stack");
}

// OP.HASH
unittest
{
    scope engine = new Engine();
    test!("==")(engine.executeScript(Type.Unlock, Script([OP.HASH])),
        "HASH opcode requires an item on the stack");
}

// OP.VERIFY_EQUAL
unittest
{
    scope engine = new Engine();
    test!("==")(engine.executeScript(Type.Unlock,
        Script([OP.VERIFY_EQUAL])),
        "VERIFY_EQUAL opcode requires two items on the stack");
    test!("==")(engine.executeScript(Type.Unlock,
        Script([OP.PUSH_BYTES_1, 1, OP.VERIFY_EQUAL])),
        "VERIFY_EQUAL opcode requires two items on the stack");
    test!("==")(engine.executeScript(Type.Unlock,
        Script([OP.PUSH_BYTES_1, 1, OP.PUSH_BYTES_1, 1, OP.VERIFY_EQUAL])),
        null);
    test!("==")(engine.executeScript(Type.Unlock,
        Script([OP.PUSH_BYTES_1, 2, OP.PUSH_BYTES_1, 1, OP.VERIFY_EQUAL])),
        "VERIFY_EQUAL operation failed");
}

// OP.CHECK_SIG
unittest
{
    scope engine = new Engine();
    test!("==")(engine.executeScript(Type.Lock,
        Script([OP.CHECK_SIG])),
        "CHECK_SIG opcode requires two items on the stack");
    test!("==")(engine.executeScript(Type.Lock,
        Script([OP.PUSH_BYTES_1, 1, OP.CHECK_SIG])),
        "CHECK_SIG opcode requires two items on the stack");
    test!("==")(engine.executeScript(Type.Lock,
        Script([OP.PUSH_BYTES_1, 1, OP.PUSH_BYTES_1, 1, OP.CHECK_SIG])),
        "CHECK_SIG opcode requires 32-byte public key on the stack");

    // invalid key (crypto_core_ed25519_is_valid_point() fails)
    Point invalid_key;
    test!("==")(engine.executeScript(Type.Lock,
        Script(cast(ubyte[])[OP.PUSH_BYTES_1, 1]
            ~ [ubyte(32)] ~ invalid_key[]
            ~ cast(ubyte[])[OP.CHECK_SIG])),
        "CHECK_SIG 32-byte public key on the stack is invalid");

    Point valid_key = Point.fromString(
        "0x44404b654d6ddf71e2446eada6acd1f462348b1b17272ff8f36dda3248e08c81");
    test!("==")(engine.executeScript(Type.Lock,
        Script(cast(ubyte[])[OP.PUSH_BYTES_1, 1]
            ~ [ubyte(32)] ~ valid_key[]
            ~ cast(ubyte[])[OP.CHECK_SIG])),
        "CHECK_SIG opcode requires 64-byte signature on the stack");

    Signature invalid_sig;
    test!("==")(engine.executeScript(Type.Lock,
        Script(cast(ubyte[])[OP.PUSH_BYTES_64] ~ invalid_sig[]
            ~ [ubyte(32)] ~ valid_key[]
            ~ cast(ubyte[])[OP.CHECK_SIG])),
        "Script failed");
}

/// See #1279
private bool isValidPointBytes (in ubyte[] bytes) /*pure*/ nothrow @trusted @nogc
{
    import libsodium.crypto_core_ed25519;
    return crypto_core_ed25519_is_valid_point(bytes.ptr) == 1;
}

///
unittest
{
    ubyte[32] data;
    assert(!isValidPointBytes(data));
}
