/*******************************************************************************

    Contains supporting code for enrollment process.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.EnrollmentManager;

import agora.common.crypto.ECC;
import agora.common.crypto.Key;
import agora.common.crypto.Schnorr;
import agora.common.Deserializer;
import agora.common.Hash;
import agora.common.Serializer;
import agora.consensus.data.Enrollment;
import agora.consensus.data.UTXOSet;
import agora.consensus.Validation;
import agora.utils.Log;

import d2sqlite3.database;
import d2sqlite3.library;
import d2sqlite3.results;
import d2sqlite3.sqlite3;

import std.algorithm;
import std.file;
import std.path;

mixin AddLogger!();

/*******************************************************************************

    Handle enrollment data and manage the validators set

*******************************************************************************/

public class EnrollmentManager
{
    /// SQLite db instance
    private Database db;

    /// Node's key pair
    private Pair key_pair;

    /// Random seed
    private Scalar random_seed_src;

    /// Preimages of hashes of random value
    public Hash[] preimages;

    /// Random key for enrollment
    private Pair signature_noise;

    /// Enrollment data object
    private Enrollment data;

    /***************************************************************************

        Constructor

        Params:
            db_path = path to the database file, or in-memory storage if
                        :memory: was passed
            key_pair = the keypair of the owner node

    ***************************************************************************/

    public this (string db_path, KeyPair key_pair)
    {
        this.db = Database(db_path);

        // create the table for validator set if it doesn't exist yet
        this.db.execute("CREATE TABLE IF NOT EXISTS validator_set " ~
            "(key TEXT PRIMARY KEY, val BLOB NOT NULL, enrolled_height INTEGER)");

        // create the table for enrollment data for a node itself
        this.db.execute("CREATE TABLE IF NOT EXISTS node_enroll_data " ~
            "(key CHAR(128) PRIMARY KEY, val BLOB NOT NULL)");

        // create Pair object from KeyPair object
        this.key_pair.v = secretKeyToCurveScalar(key_pair.secret);
        this.key_pair.V = this.key_pair.v.toPoint();

        // load signature noise
        auto results = this.db.execute("SELECT val FROM node_enroll_data " ~
            "WHERE key = ?", "signature_noise");

        foreach (row; results)
        {
            signature_noise = deserializeFull!Pair(row.peek!(ubyte[])(0));
            break;
        }

        // load preimages
        results = this.db.execute("SELECT val FROM node_enroll_data " ~
            "WHERE key = ?", "preimages");

        if (!results.empty)
            this.preimages = results.oneValue!(ubyte[]).deserializeFull!(Hash[]);
    }

    /***************************************************************************

        Shut down the database

        Note: this method must be called explicitly, and not inside of
        a destructor.

    ***************************************************************************/

    public void shutdown ()
    {
        this.db.close();
    }

    /***************************************************************************

        Add a enrollment data to the validators set

        Params:
            block_height = the current block height in the ledger
            finder = the delegate to find UTXOs with
            enroll = the enrollment data to add

        Returns:
            true if the enrollment data has been added to the validator set

    ***************************************************************************/

    public bool addEnrollment (ulong block_height, scope UTXOFinder finder,
        const ref Enrollment enroll) @safe nothrow
    {
        static ubyte[] buffer;

        // check validity of the enrollment data
        if (auto reason = isInvalidEnrollmentReason(block_height + 1,
            enroll, finder))
        {
            this.logMessage("Invalid enrollment data, Reason: " ~ reason,
                enroll);
            return false;
        }

        // check if already exists
        try
        {
            if (this.hasEnrollment(enroll.utxo_key))
            {
                this.logMessage("Rejected already existing enrollment",
                    enroll);
                return false;
            }
        }
        catch (Exception ex)
        {
            this.logMessage("Exception occured in checking if " ~
                "the enrollment data exists", enroll, ex);
            return false;
        }

        buffer.length = 0;
        () @trusted { assumeSafeAppend(buffer); } ();

        scope SerializeDg dg = (scope const(ubyte[]) data) nothrow @safe
        {
            buffer ~= data;
        };

        try
        {
            serializePart(enroll, dg);
        }
        catch (Exception ex)
        {
            this.logMessage("Serialization error", enroll, ex);
            return false;
        }

        try
        {
            () @trusted {
                this.db.execute("INSERT INTO validator_set (key, val) VALUES (?, ?)",
                    enroll.utxo_key.toString(), buffer);
            }();

        }
        catch (Exception ex)
        {
            this.logMessage("Database operation error", enroll, ex);
            return false;
        }

        return true;
    }

    /***************************************************************************

        Returns:
            the number of validators in the validator set

    ***************************************************************************/

    public size_t getEnrollmentLength () @safe
    {
        return () @trusted {
            return this.db.execute("SELECT count(*) FROM validator_set").oneValue!size_t;
        }();
    }

    /***************************************************************************

        Remove the enrollment data with the given key from the validator set

        Params:
            enroll_hash = key for an enrollment data to remove

    ***************************************************************************/

    public void removeEnrollment (const ref Hash enroll_hash) @trusted
    {
        this.db.execute("DELETE FROM validator_set WHERE key = ?",
            enroll_hash.toString());
    }

    /***************************************************************************

        In validatorSet DB, return the enrolled block height.

        Params:
            enroll_hash = key for an enrollment block height

        Returns:
            the enrolled block height, or 0 if no matching key exists

    ***************************************************************************/

    public size_t getEnrolledHeight (const ref Hash enroll_hash) @trusted
    {
        try
        {
            auto results = this.db.execute("SELECT enrolled_height FROM validator_set" ~
                " WHERE key = ?", enroll_hash.toString());
            if (results.empty)
                return size_t.init;

            return results.oneValue!(size_t);
        }
        catch (Exception ex)
        {
            log.error("Database operation error {}", ex);
            return size_t.init;
        }
    }

    /***************************************************************************

        Update the enrolled height of the validatorSet DB.

        Params:
            enroll_hash = enrollment blockheight to update enroll hash
            block_height = enrolled blockheight

        Returns:
            true if the update operation was successful, false otherwise

    ***************************************************************************/

    public bool updateEnrolledHeight (const ref Hash enroll_hash,
        const size_t block_height) @safe
    {
        try
        {
            if (this.getEnrolledHeight(enroll_hash) > 0)
                return false;

            () @trusted {
                this.db.execute(
                    "UPDATE validator_set SET enrolled_height = ? WHERE key = ?",
                    block_height, enroll_hash.toString());
            }();
        }
        catch (Exception ex)
        {
            log.error("Database operation error, updateEnrolledHeight:{}, exception:{}",
                enroll_hash, ex);
            return false;
        }
        return true;
    }

    /***************************************************************************

        Make an enrollment data for enrollment process

        Params:
            frozen_utxo_hash = the hash of a frozen UTXO used to identify a validator
                        and to generate a siging key
            enroll = will contain the Enrollment if created

        Returns:
            true if the enrollment manager succeeded in creating the Enrollment

    ***************************************************************************/

    public bool createEnrollment (Hash frozen_utxo_hash, out Enrollment enroll) @trusted nothrow
    {
        static ubyte[] buffer;
        buffer.length = 0;

        // K, frozen UTXO hash
        this.data.utxo_key = frozen_utxo_hash;

        // N, cycle length
        this.data.cycle_length = 1008; // freezing period / 2

        // generate random seed value
        this.random_seed_src = Scalar.random();

        // X, final seed data and preimages of hashes
        this.preimages.length = 0;
        assumeSafeAppend(this.preimages);
        this.preimages ~= hashFull(this.random_seed_src);
        foreach (i; 0 .. this.data.cycle_length-1)
            this.preimages ~= hashFull(this.preimages[i]);
        this.data.random_seed = this.preimages[$-1];

        // R, signature noise
        this.signature_noise = Pair.random();
        () @trusted { assumeSafeAppend(buffer); }();

        scope SerializeDg dg = (scope const(ubyte[]) data) nothrow @safe
        {
            buffer ~= data;
        };

        try
        {
            serializePart(this.signature_noise, dg);
        }
        catch (Exception ex)
        {
            this.logMessage("Serialization error", enroll, ex);
            return false;
        }

        try
        {
            () @trusted {
                auto results = this.db.execute("SELECT EXISTS(SELECT 1 FROM node_enroll_data " ~
                    "WHERE key = ?)", "signature_noise");
                if (results.oneValue!(bool))
                {
                    this.db.execute("UPDATE node_enroll_data SET val = ? WHERE key = ?",
                        buffer, "signature_noise");
                }
                else
                {
                    this.db.execute("INSERT INTO node_enroll_data (key, val) VALUES (?, ?)",
                        "signature_noise", buffer);
                }
            }();
        }
        catch (Exception ex)
        {
            this.logMessage("Database operation error", enroll, ex);
            return false;
        }

        // serialize preimages
        buffer.length = 0;
        assumeSafeAppend(buffer);
        try
        {
            serializePart(this.preimages, dg);
        }
        catch (Exception ex)
        {
            this.logMessage("Serialization error of preimages", enroll, ex);
            return false;
        }

        try
        {
            () @trusted {
                auto results = this.db.execute("SELECT EXISTS(SELECT 1 FROM node_enroll_data " ~
                    "WHERE key = ?)", "preimages");
                if (results.oneValue!(bool))
                {
                    this.db.execute("UPDATE node_enroll_data SET val = ? WHERE key = ?",
                        buffer, "preimages");
                }
                else
                {
                    this.db.execute("INSERT INTO node_enroll_data (key, val) VALUES (?, ?)",
                        "preimages", buffer);
                }
            }();
        }
        catch (Exception ex)
        {
            this.logMessage("Database operation error", enroll, ex);
            return false;
        }

        // signature
        data.enroll_sig = sign(this.key_pair.v, this.key_pair.V, this.signature_noise.V,
            this.signature_noise.v, this.data);

        enroll = this.data;
        return true;
    }

    /***************************************************************************

        Check if a enrollment data exists in the validator set.

        Params:
            enroll_hash = key for an enrollment data which is hash of frozen UTXO

        Returns:
            true if the validator set has the enrollment data

    ***************************************************************************/

    public bool hasEnrollment (const ref Hash enroll_hash) @trusted
    {
        auto results = this.db.execute("SELECT EXISTS(SELECT 1 FROM validator_set " ~
            "WHERE key = ?)", enroll_hash.toString());

        return results.front().peek!bool(0);
    }

    /***************************************************************************

        Get the enrollment data with the key, and store it to 'enroll' if found

        Params:
            enroll_hash = key for an enrollment data which is a hash of a frozen
                            UTXO
            enroll = will contain the enrollment data if found

        Returns:
            Return true if the enrollment data was found

    ***************************************************************************/

    public bool getEnrollment (const ref Hash enroll_hash,
        out Enrollment enroll) @trusted
    {
        auto results = this.db.execute("SELECT key, val FROM validator_set " ~
            "WHERE key = ?", enroll_hash.toString());

        foreach (row; results)
        {
            enroll = deserializeFull!Enrollment(row.peek!(ubyte[])(1));
            return true;
        }

        return false;
    }

    /***************************************************************************

        Get the unregistered enrollments in the block
        And this is arranged in ascending order with the utxo_key

        Params:
            enrolls = will contain the unregistered enrollments data if found

        Returns:
            The unregistered enrollments data

    ***************************************************************************/

    public Enrollment[] getUnregisteredEnrollments (ref Enrollment[] enrolls)
        @trusted
    {
        enrolls.length = 0;
        assumeSafeAppend(enrolls);
        auto results = this.db.execute("SELECT val FROM validator_set" ~
            " WHERE enrolled_height is null ORDER BY key ASC");

        foreach (row; results)
            enrolls ~= deserializeFull!Enrollment(row.peek!(ubyte[])(0));

        return enrolls;
    }

    /***************************************************************************

        Logs message

        Params:
            msg = the log message to be logged
            enroll = the Enrollment object, the information of which will be logged
            ex = the Exception object, the message of which will be logged

    ***************************************************************************/

    private static void logMessage (string msg, const ref Enrollment enroll,
        const Exception ex = null) @safe nothrow
    {
        try
        {
            if (ex !is null)
            {
                log.error("{}, enrollment:{}, exception:{}", msg, enroll, ex);
            }
            else
            {
                log.info("{}, enrollment:{}", msg, enroll);
            }
        }
        catch (Exception ex)
        {}
    }

    /***************************************************************************

        Get pre-images

        Returns:
            an array of hashes of pre-images

    ***************************************************************************/

    version (unittest) public const(Hash)[] getPreimages ()
    {
        return this.preimages;
    }

    /***************************************************************************

        Load pre-images from the storage

        Returns:
            an array of hashes of pre-images

    ***************************************************************************/

    version (unittest) public Hash[] loadPreimages () @safe
    {
        Hash[] preimages;
        () @trusted {
            auto results = this.db.execute("SELECT val FROM node_enroll_data " ~
                "WHERE key = ?", "preimages");
            if (!results.empty)
                preimages = results.oneValue!(ubyte[]).deserializeFull!(Hash[]);
        }();

        return preimages;
    }
}

/// tests for member functions of EnrollmentManager
unittest
{
    import agora.common.Amount;
    import agora.consensus.data.Transaction;
    import agora.consensus.Genesis;
    import std.format;
    import std.conv;

    Transaction[Hash] storage;
    scope findUTXO = (Hash hash, size_t index, out UTXOSetValue value) @trusted
    {
        assert(index == size_t.max);
        if (auto tx = hash in storage)
        {
            value.unlock_height = 0;
            value.type = tx.type;
            value.output = tx.outputs[0];
            return true;
        }

        return false;
    };

    auto gen_key_pair = getGenesisKeyPair();
    KeyPair key_pair = KeyPair.random();

    foreach (idx; 0 .. 8)
    {
        auto input = Input(hashFull(GenesisTransaction), idx.to!uint);

        Transaction tx =
        {
            TxType.Freeze,
            [input],
            [Output(Amount.MinFreezeAmount, key_pair.address)]
        };

        auto signature = gen_key_pair.secret.sign(hashFull(tx)[]);
        tx.inputs[0].signature = signature;
        storage[hashFull(tx)] = tx;
    }

    // create an EnrollmentManager object
    auto man = new EnrollmentManager(":memory:", key_pair);
    scope (exit) man.shutdown();
    Hash[] utxo_hashes = storage.keys;

    // create and add the first Enrollment object
    auto utxo_hash = utxo_hashes[0];
    Enrollment enroll;
    assert(man.createEnrollment(utxo_hash, enroll));
    assert(!man.hasEnrollment(utxo_hash));
    assert(man.addEnrollment(0, findUTXO, enroll));
    assert(man.getEnrollmentLength() == 1);
    assert(man.hasEnrollment(utxo_hash));
    assert(!man.addEnrollment(0, findUTXO, enroll));

    // create and add the second Enrollment object
    auto utxo_hash2 = utxo_hashes[1];
    Enrollment enroll2;
    assert(man.createEnrollment(utxo_hash2, enroll2));
    assert(man.addEnrollment(0, findUTXO, enroll2));
    assert(man.getEnrollmentLength() == 2);

    auto utxo_hash3 = utxo_hashes[2];
    Enrollment enroll3;
    assert(man.createEnrollment(utxo_hash3, enroll3));
    assert(man.addEnrollment(0, findUTXO, enroll3));
    assert(man.getEnrollmentLength() == 3);

    Enrollment[] enrolls;
    man.getUnregisteredEnrollments(enrolls);
    assert(enrolls.length == 3);
    assert(enrolls.isStrictlyMonotonic!("a.utxo_key < b.utxo_key"));

    // get a stored Enrollment object
    Enrollment stored_enroll;
    assert(man.getEnrollment(utxo_hash2, stored_enroll));
    assert(stored_enroll == enroll2);

    // remove an Enrollment object
    man.removeEnrollment(utxo_hash2);
    assert(man.getEnrollmentLength() == 2);

    // test for getEnrollment with removed enrollment
    assert(!man.getEnrollment(utxo_hash2, stored_enroll));

    // test for enrollment block height update
    assert(!man.getEnrolledHeight(utxo_hash));
    assert(man.updateEnrolledHeight(utxo_hash, 9));
    assert(man.getEnrolledHeight(utxo_hash) == 9);
    assert(!man.updateEnrolledHeight(utxo_hash, 9));
    assert(man.getEnrolledHeight(utxo_hash2) == 0);
    man.getUnregisteredEnrollments(enrolls);
    assert(enrolls.length == 1);

    man.removeEnrollment(utxo_hash);
    man.removeEnrollment(utxo_hash2);
    man.removeEnrollment(utxo_hash3);
    assert(man.getUnregisteredEnrollments(enrolls).length == 0);

    Enrollment[] ordered_enrollments;
    ordered_enrollments ~= enroll;
    ordered_enrollments ~= enroll2;
    ordered_enrollments ~= enroll3;
    // Reverse ordering
    ordered_enrollments.sort!("a.utxo_key > b.utxo_key");
    foreach (ordered_enroll; ordered_enrollments)
        assert(man.addEnrollment(0, findUTXO, ordered_enroll));
    man.getUnregisteredEnrollments(enrolls);
    assert(enrolls.length == 3);
    assert(enrolls.isStrictlyMonotonic!("a.utxo_key < b.utxo_key"));

    // test serialization/deserializetion for pre-images
    auto preimages_1 = man.getPreimages();
    auto preimages_2 = man.loadPreimages();
    int true_count;
    foreach (i; 0 .. 1008)
        if (preimages_1[i] == preimages_2[i])
            true_count++;
    assert(true_count == 1008);
}
