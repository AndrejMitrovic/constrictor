/*******************************************************************************

    Definitions of the validator API

    Two kinds of nodes exist: full nodes, and validators.
    A full node follows the network as a passive actor, but does validation
    on the data it receives, and can forward that data to other nodes.
    A validator is a full node which participates in consensus.

    An `API` is used as an interface to communicate with a node.
    As such, a class that implements `API` exists (in `agora.node.Node`),
    and in order to communicate with other nodes, it holds an `API` for
    each of those nodes.

    Note that both full node and validator interfaces are named `API`,
    as users are expected to use only one of them, not both in combination.
    A client either deal with a validator because it needs the validator API
    (only other validators so far), or needs the full node API and don't
    care about the validators functions, and should not knoe about them as
    they also include many more dependencies.

    `API` are defined as D interfaces, following what is done in Vibe.d.
    Those interfaces can be read by a generator to build a client or a server.
    One such generator is Vibe.d's `vibe.web.rest`. `RestInterfaceClient`
    allows to query a REST API, while `registerRestInterface` will route queries
    and deserialize parameters according to the interface's definition.

    Another generator which we use for unittests is "LocalRest".
    It allows to start a node per thread, and uses `std.concurrency`
    to do message passing between nodes.

    Lastly, we plan to implement a generator which works directly on TCP/IP.

    Copyright:
        Copyright (c) 2019-2020 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.api.Validator;

import agora.common.crypto.Key;
import agora.common.Hash;
import agora.consensus.data.PreimageInfo;
static import agora.api.FullNode;

import scpd.types.Stellar_SCP;
import scpd.types.Stellar_types : StellarHash = Hash;

import vibe.web.rest;

///
public import agora.api.FullNode;


/*******************************************************************************

    Define the API a validator exposes to other validators

    A validator can do everything a full node does, and additionally takes
    part of consensus.

*******************************************************************************/

@path("/")
public interface API : agora.api.FullNode.API
{
// The REST generator requires @safe methods
@safe:

    /***************************************************************************

        Returns:
            The public key of this node

        API:
            GET /public_key

    ***************************************************************************/

    public PublicKey getPublicKey ();

    /***************************************************************************

        Returns:
            The quorum hash of this node.
            If the client does not have a mapping of this hash to the quorum set,
            it should call getQuorumSet with the retrieved hash.

        API:
            GET /quorum_hash

    ***************************************************************************/

    public StellarHash getQuorumHash ();

    /***************************************************************************

        Params:
            hash = the hash to look up

        Returns:
            The quorum set for the given quorum hash.

        API:
            GET /quorum_set

    ***************************************************************************/

    public SCPQuorumSet getQuorumSet (StellarHash hash);

    /***************************************************************************

        Receives an SCP envelope and processes it.
        The node does not respond with any status code,
        clients which call this API can & should call it asynchronously.

        Params:
            envelope = Envelope to process (See Stellar_SCP)

    ***************************************************************************/

    public void receiveEnvelope (SCPEnvelope envelope);

    /***************************************************************************

        Reveals a pre-image

        Params:
            preimage = a PreimageInfo object which contains a hash and a height

    ***************************************************************************/

    public void receivePreimage (PreimageInfo preimage);

    /***************************************************************************

        Checks if a pre-image exists

        Params:
            enroll_key = The key for the enrollment in which the pre-image is
                contained.
            height = The block height of the preimage to check existence

        Returns:
            true if the pre-image exists

    ***************************************************************************/

    public bool hasPreimage (Hash enroll_key, ulong height);
}
