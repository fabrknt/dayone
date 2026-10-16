// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// Etched at a precompile address: returns whatever was set for the 32-byte input,
/// and fails (like the real precompiles) for anything unset. Same as hl-price-guard's test mock.
contract MockPrecompile {
    mapping(bytes32 => bytes) internal ret;

    function set(uint32 index, bytes calldata out) external {
        ret[keccak256(abi.encode(index))] = out;
    }

    fallback(bytes calldata input) external returns (bytes memory out) {
        out = ret[keccak256(input)];
        require(out.length != 0, "PrecompileError");
    }
}
