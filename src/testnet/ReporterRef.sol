// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {IRefSource} from "../LaunchPool.sol";

/// @notice A reference price that one reporter key writes. Testnet only: it is not an independent
/// signed price, only as good as the reporter, who can hold every settlement (stop pushing, or push
/// a price far from the oracle) and can let a wrong oracle through inside the bound. On mainnet use a
/// signed source (`PythRef`). Day One's testnet keeper pushes HL mainnet's oracle for the same
/// market (`REF_COIN`), so a testnet oracle that stops or drifts trips the guard.
///
/// `updatedAt` is when the reporter pushed, not when the source last changed. Before the first push
/// it reads as stale, so a pool that starts with it settles nothing until a price arrives.
contract ReporterRef is IRefSource {
    address public immutable reporter;
    uint256 public immutable maxAge; // seconds
    uint256 public price; // 1e18
    uint256 public updatedAt;

    event Pushed(uint256 price);

    error NotReporter();
    error BadPrice();

    constructor(address reporter_, uint256 maxAge_) {
        if (reporter_ == address(0) || maxAge_ == 0) revert BadPrice();
        reporter = reporter_;
        maxAge = maxAge_;
    }

    function push(uint256 price_) external {
        if (msg.sender != reporter) revert NotReporter();
        if (price_ == 0) revert BadPrice();
        price = price_;
        updatedAt = block.timestamp;
        emit Pushed(price_);
    }

    function ref() external view returns (HLPriceGuard.Ref memory) {
        // price 0 would mean "no reference" to the guard: never pushed reads as stale instead
        if (price == 0) return HLPriceGuard.Ref(1, 0, maxAge);
        return HLPriceGuard.Ref(price, updatedAt, maxAge);
    }
}
