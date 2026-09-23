// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Addresses} from "../../script/Addresses.sol";

/// Checks that LONG tokens behave like plain ERC-20s, which the hook relies on:
/// exact transfers (no fee-on-transfer), no rebasing, and transfers to 0xdEaD allowed.
/// forge test --match-path test/fork/TokenChecks.t.sol -vv
contract TokenChecksTest is Test {
    address constant POOL_MANAGER = Addresses.POOL_MANAGER; // holds every token
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
    }

    function test_allTokensAreStandard() public {
        _checkStandard(IERC20(Addresses.INU));
        address[4] memory partners = Addresses.partners();
        for (uint256 i; i < partners.length; i++) {
            _checkStandard(IERC20(partners[i]));
        }
    }

    function _checkStandard(IERC20 t) internal {
        string memory sym = t.symbol();
        address alice = makeAddr(string.concat("alice-", sym));
        address bob = makeAddr(string.concat("bob-", sym));
        uint256 supply = t.totalSupply();
        uint256 amt = 1_000e18;

        assertEq(t.decimals(), 18, sym);

        // holder -> fresh wallet: exact amount arrives
        vm.prank(POOL_MANAGER);
        t.transfer(alice, amt);
        assertEq(t.balanceOf(alice), amt, string.concat(sym, ": no fee on transfer"));

        // fresh wallet -> fresh wallet via approve/transferFrom (how v4 settles)
        vm.prank(alice);
        t.approve(bob, amt / 2);
        vm.prank(bob);
        t.transferFrom(alice, bob, amt / 2);
        assertEq(t.balanceOf(bob), amt / 2, string.concat(sym, ": exact transferFrom"));

        // transfer to the burn address works and is exact
        uint256 dead0 = t.balanceOf(DEAD);
        vm.prank(alice);
        t.transfer(DEAD, amt / 4);
        assertEq(t.balanceOf(DEAD) - dead0, amt / 4, string.concat(sym, ": burn to 0xdEaD is exact"));

        // balances don't drift (no rebasing), supply unchanged by transfers
        assertEq(t.balanceOf(alice), amt / 4, string.concat(sym, ": no rebasing"));
        assertEq(t.totalSupply(), supply, string.concat(sym, ": supply unchanged"));
    }
}
