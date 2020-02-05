/*******************************************************************************

    Contains the SCP consensus driver implementation.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.protocol.Nominator;

import agora.common.crypto.Key;
import agora.common.Deserializer;
import agora.common.Hash : hashFull;
import agora.common.Serializer;
import agora.common.Set;
import agora.common.Task;
import agora.consensus.data.Block;
import agora.consensus.data.Transaction;
import agora.network.NetworkClient;
import agora.node.Ledger;
import agora.utils.Log;
import agora.utils.PrettyPrinter;

import scpd.Cpp;
import scpd.scp.SCP;
import scpd.scp.SCPDriver;
import scpd.scp.Slot;
import scpd.scp.Utils;
import scpd.types.Stellar_types;
import scpd.types.Stellar_types : StellarHash = Hash;
import scpd.types.Stellar_SCP;
import scpd.types.Utils;
import scpd.Util;

alias TimerType = Slot.timerIDs;
import core.stdc.stdint;
import core.time;
import std.conv;
import std.datetime;
import std.stdio;
import std.traits;

mixin AddLogger!();

/// Ditto
public extern (C++) class Nominator : SCPDriver
{
    /// SCP instance
    private SCP* scp;

    /// Key pair of this node
    private KeyPair key_pair;

    /// Task manager
    private TaskManager taskman;

    /// Ledger instance
    private Ledger ledger;

    /// This node's quorum node clients
    private NetworkClient[PublicKey] peers;

    /// The set of active timers
    /// Todo: SCPTests.cpp uses fake timers,
    /// Similar to how we use FakeClockBanManager!
    private Set!ulong timers;

    /// The set of externalized slot indices
    private Set!uint64_t externalized_slots;

    /// The quorum set
    private SCPQuorumSetPtr[Hash] quorum_set;

    /// Tracks incremental timer IDs, and the range of active ones based on type
    private ulong[TimerType] last_timer_id;

    /// ditto
    private ulong[TimerType] active_timer_ids;

extern(D):

    /***************************************************************************

        Constructor

        Params:
            key_pair = the key pair of this node
            ledger = needed for SCP state restoration & block validation
            taskman = used to run timers
            peers = the set of clients to the peers in the quorum
            quorum_set = the quorum set of this node

    ***************************************************************************/

    public this (KeyPair key_pair, Ledger ledger,
        TaskManager taskman, NetworkClient[PublicKey] peers,
        SCPQuorumSet quorum_set)
    {
        foreach (type; EnumMembers!TimerType)
        {
            last_timer_id[type] = 0;
            active_timer_ids[type] = 0;
        }

        this.key_pair = key_pair;
        auto node_id = NodeID(StellarHash(key_pair.address[]));
        const IsValidator = true;
        this.scp = createSCP(this, node_id, IsValidator, quorum_set);
        this.taskman = taskman;
        this.ledger = ledger;
        this.peers = peers;

        // cast: see makeSharedSCPQuorumSet() in Cpp.d
        auto local_quorum_set = this.scp.getLocalQuorumSet();
        auto localQSet = makeSharedSCPQuorumSet(local_quorum_set);

        const bytes = ByteSlice.make(XDRToOpaque(*localQSet));
        auto quorum_hash = sha256(bytes);
        this.quorum_set[quorum_hash] = localQSet;

        this.restoreSCPState(ledger);
        this.ledger.setNominator(&this.nominateTransactionSet);
    }

    /***************************************************************************

        Nominate a new transaction set to the quorum.
        Failure to nominate is only logged.

        Params:
            slot_idx = the index of the slot to nominate for
            prev = the transaction set of the previous slot
            next = the proposed transaction set for the provided slot index

    ***************************************************************************/

    private void nominateTransactionSet (ulong slot_idx, Set!Transaction prev,
        Set!Transaction next) @trusted
    {
        scope (failure) assert(0);

        log.info("{}(): Proposing tx set for slot {}", __FUNCTION__, slot_idx);
        static size_t count;

        auto prev_value = prev.serializeFull().toVec();
        auto next_value = next.serializeFull().toVec();
        if (this.scp.nominate(slot_idx, next_value, prev_value))
        {
            log.info("{}(): Tx set nominated", __FUNCTION__);

            EnableLogging && writefln("-- %s Success SCP.nominate [Node %s] [Count %s]",
                Clock.currTime().stdTime,
                getNode(),
                ++count);
        }
        else
        {
            EnableLogging && writefln("-- %s Failure SCP.nominate [Node %s] [Count %s]",
                Clock.currTime().stdTime,
                getNode(),
                ++count);

            log.info("{}(): Tx set rejected nomination", __FUNCTION__);
        }
    }

    /***************************************************************************

        Restore SCP's internal state based on the provided ledger state

        Params:
            ledger = the ledger instance

    ***************************************************************************/

    private void restoreSCPState (Ledger ledger)
    {
        import agora.common.Serializer;
        import scpd.types.Stellar_SCP;
        import scpd.types.Utils;
        import scpd.types.Stellar_types : StellarHash = Hash, NodeID;
        import std.range;

        auto key = StellarHash(this.key_pair.address[]);
        auto pub_key = NodeID(key);

        foreach (block_idx, block; ledger.getBlocksFrom(0).enumerate)
        {
            Value block_value = block.serializeFull().toVec();

            SCPStatement statement =
            {
                nodeID: pub_key,
                slotIndex: block_idx,
                pledges: {
                    type_: SCPStatementType.SCP_ST_EXTERNALIZE,
                    externalize_: {
                        commit: {
                            counter: 0,
                            value: block_value,
                        },
                        nH: 0,
                    },
                },
            };

            SCPEnvelope env = SCPEnvelope(statement);
            this.scp.setStateFromEnvelope(block_idx, env);
            if (!this.scp.isSlotFullyValidated(block_idx))
                assert(0);
        }

        // there should at least be a genesis block
        if (this.scp.empty())
            assert(0);
    }

    /***************************************************************************

        Called when a new SCP Envelope is received from the network.

        Params:
            envelope = the SCP envelope

        Returns:
            true if the SCP protocol accepted this envelope

    ***************************************************************************/

    public bool receiveEnvelope (SCPEnvelope envelope) @trusted
    {
        return this.scp.receiveEnvelope(envelope) == SCP.EnvelopeState.VALID;
    }

    extern (C++):


    /***************************************************************************

        Signs the SCPEnvelope with the node's private key.

        todo: Currently not signing yet. To be done.

        Params:
            envelope = the SCPEnvelope to sign

    ***************************************************************************/

    public override void signEnvelope (ref SCPEnvelope envelope)
    {
        import std.datetime;
        import std.conv : to;

        scope (failure) assert(0);
        static size_t count;
        EnableLogging && writefln("-- %s [Node %s] [Count #%s] signEnvelope [Envelope #%s] [Type: %s]",
            Clock.currTime().stdTime,
            getNode(),
            ++count,
            cast(ulong)envelope.statement.slotIndex,
            envelope.statement.pledges.type_.typeToString());
    }

    /***************************************************************************

        Validates the provided transaction set for the provided slot index,
        and returns a status code of the validation.

        Params:
            slot_idx = the slot index we're currently reaching consensus for
            value = the transaction set to validate
            nomination = unused, seems to be stellar-specific

    ***************************************************************************/

    public override ValidationLevel validateValue (uint64_t slot_idx,
        ref const(Value) value, bool nomination) nothrow
    {
        scope (failure) assert(0);
        static size_t count;
        EnableLogging && writefln("-- %s [Node %s] [Count #%s] validateValue",
            Clock.currTime().stdTime,
            getNode(),
            ++count);

        scope (failure) assert(0);

        try
        {
            auto tx_set = deserializeFull!(Set!Transaction)(
                cast(ubyte[])value[]);

            if (auto fail_reason = this.ledger.validateTxSet(tx_set))
            {
                log.error("validateValue(): Invalid tx set: {}", fail_reason);
                return ValidationLevel.kInvalidValue;
            }
        }
        catch (Exception ex)
        {
            log.error("{}: Received invalid tx set. Error: {}",
                __FUNCTION__, ex.message);

            return ValidationLevel.kInvalidValue;
        }

        return ValidationLevel.kFullyValidatedValue;
    }

    /***************************************************************************

        Called when consenus has been reached for the provided slot index and
        the transaction set.

        Params:
            slot_idx = the slot index
            value = the transaction set

    ***************************************************************************/

    public override void valueExternalized (uint64_t slot_idx,
        ref const(Value) value)
    {
        scope (failure) assert(0);
        static size_t count;
        EnableLogging && writefln("-- %s [Node %s] [Count #%s] valueExternalized",
            Clock.currTime().stdTime,
            getNode(),
            ++count);

        if (slot_idx in this.externalized_slots)
            return;  // slot was already externalized
        this.externalized_slots.put(slot_idx);

        auto bytes = cast(ubyte[])value[];
        auto tx_set = deserializeFull!(Set!Transaction)(bytes);

        if (tx_set.length == 0)
            assert(0, "Transaction set empty");

        import agora.common.Hash;

        static struct Hashed
        {
            Set!Transaction txs;

            void computeHash (scope HashDg dg) const nothrow @safe @nogc
            {
                scope (failure) assert(0);
                foreach (Transaction tx, bool _; txs._set)
                    hashPart(tx, dg);
            }
        }

        EnableLogging && writefln("-- %s [Node %s] [Height %s] [Hash %s] [Count %s] onTXSetExternalized",
                Clock.currTime().stdTime,
                getNode(),
                slot_idx,
                hashFull(Hashed(tx_set)),
                ++count);

        if (!this.ledger.onTXSetExternalized(slot_idx, tx_set))
            assert(0);
    }

    /***************************************************************************

        Params:
            qSetHash = the hash of the quorum set

        Returns:
            the SCPQuorumSet pointer for the provided quorum set hash

    ***************************************************************************/

    public override SCPQuorumSetPtr getQSet (ref const(StellarHash) qSetHash)
    {
        if (auto scp_quroum = qSetHash in this.quorum_set)
            return *scp_quroum;

        return SCPQuorumSetPtr.init;
    }

    /***************************************************************************

        Floods the given SCPEnvelope to the network of connected peers.

        Params:
            envelope = the SCPEnvelope to flood to the network.

    ***************************************************************************/

    public override void emitEnvelope (ref const(SCPEnvelope) envelope)
    {
        static size_t count;
        scope (failure) assert(0);
        EnableLogging && writefln("-- %s [Node %s] [Count #%s] emitEnvelope [Envelope #%s] [Type: %s]",
            Clock.currTime().stdTime,
            getNode(),
            ++count,
            cast(ulong)envelope.statement.slotIndex,
            envelope.statement.pledges.type_.typeToString());

        try
        {
            foreach (key, node; this.peers)
            {
                // note: cannot deal with const parameter types in the API
                auto env = cast()envelope;

                // note: several error-cases not considered here yet:
                // A) request failure after N attepts => we might have to retry,
                // but exactly how much time do we have before the next round??
                // B) Node rejects the envelope. Possible in circular scenarios,
                // e.g. A => B => C => A (A rejects the envelope because it sent it first)
                node.sendEnvelope(env);
            }
        }
        catch (Exception ex)
        {
            import std.conv;
            assert(0, ex.to!string);
        }
    }

    /***************************************************************************

        Combine a set of transaction sets into a single transaction set.
        This may be done in arbitrary ways, as long as it's consistent
        (for a given input, the combined output is predictable).

        For simplicity we currently only pick the first transaction set
        to become the "combined" transaction set.

        Params:
            slot_idx = the slot index we're currently reaching consensus for
            candidates = a set of a set of transactions

    ***************************************************************************/

    public override Value combineCandidates (uint64_t slot_idx,
        ref const(set!Value) candidates)
    {
        scope (failure) assert(0);
        static size_t count;
        EnableLogging && writefln("-- %s [Node %s] [Count #%s] combineCandidates",
            Clock.currTime().stdTime,
            getNode(),
            ++count);

        foreach (ref const(Value) candidate; candidates)
        {
            auto tx_set = deserializeFull!(Set!Transaction)(
                cast(ubyte[])candidate[]);

            if (auto msg = this.ledger.validateTxSet(tx_set))
            {
                log.error("combineCandidates(): Invalid tx set: {}", msg);
                continue;
            }
            else
            {
                log.info("combineCandidates: {}", slot_idx);
            }

            // todo: currently we just pick the first of the candidate values,
            // but we should ideally pick tx's out of the combined set
            return tx_set.serializeFull().toVec();
        }

        assert(0);  // should not reach here
    }

    /***************************************************************************

        Used for setting and clearing C++ callbacks which fire after a
        given timeout.

        On the D side we spawn a new task which waits until a timer expires.

        The callback is a C++ delegate, we use a helper function to invoke it.

        Params:
            slot_idx = the slot index we're currently reaching consensus for.
            timer_type = the timer ID. required in case the timer gets cancelled.
            timeout = the timeout of the timer, in milliseconds.
            callback = the C++ callback to call.

    ***************************************************************************/

    public override void setupTimer (ulong slot_idx, int timer_type,
        milliseconds timeout, CPPDelegate!SCPCallback* callback)
    {
        scope (failure) assert(0);

        try
        {
            const type = timer_type.to!TimerType;

            static size_t count;
            EnableLogging && writefln("-- %s [Node %s] [Count #%s] [%s Timer] [Timeout: %s] [Callback: %s] setupTimer",
                Clock.currTime().stdTime,
                getNode(),
                ++count,
                type,
                timeout,
                callback);

            if (callback is null || timeout == 0)
            {
                // signal deactivation of all timers with this timer type
                this.active_timer_ids[type] = this.last_timer_id[type] + 1;
                return;
            }

            const timer_id = ++this.last_timer_id[type];
            this.taskman.runTask(
            {
                this.taskman.wait(timeout.msecs);

                // timer was cancelled
                if (timer_id < this.active_timer_ids[type])
                    return;

                callCPPDelegate(callback);
            });
        }
        catch (Throwable err)
        {
            try { EnableLogging && writefln("-- Error thrown in setupTimer: %s", err); } catch (Exception) { }
            //throw err;
        }
    }
}
