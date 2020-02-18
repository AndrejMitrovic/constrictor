/*******************************************************************************

    Bindings for scp/QuorumSetUtils.h

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module scpd.scp.QuorumSetUtils;

import scpd.types.Stellar_SCP;
import scpd.types.Stellar_types;

import core.stdcpp.string;

extern(C++, `stellar`):

bool isQuorumSetSane(ref const SCPQuorumSet qSet, bool extraChecks,
    basic_string!char* reason);

// normalize the quorum set, optionally removing idToRemove
void normalizeQSet(ref SCPQuorumSet qSet, const NodeID* idToRemove = null);
