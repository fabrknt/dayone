// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// The precompile mock comes from hl-price-guard (test/HLTest.sol); this name is kept for the
// existing `.set(index, rawBytes)` calls.
import {HLMockPrecompile as MockPrecompile} from "hl-price-guard/test/HLTest.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked; // like USDC's blacklist: transfers to it revert

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}
