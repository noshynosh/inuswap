// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LiquidityAmounts} from "../lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {INuSwapHook} from "../src/INuSwapHook.sol";
import {Addresses} from "./Addresses.sol";
import {PriceRoute} from "./PriceRoute.sol";

interface IPositionManager {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Creates ONE iNu/X pool on the hook and seeds full-range liquidity, atomically, at the live market
/// price read along Addresses.priceRoute (e.g. INU -> AI -> X). Nothing is spent beyond AMOUNT_INU / AMOUNT_TOKEN.
///
/// Dry run:  forge script script/CreatePool.s.sol --rpc-url robinhood --sender <wallet>
/// For real: forge script script/CreatePool.s.sol --rpc-url robinhood --account deployer --broadcast
///
/// Env: TOKEN (symbol from Addresses.sol, e.g. AI), AMOUNT_INU, AMOUNT_TOKEN (wei)
contract CreatePool is Script {
    using StateLibrary for IPoolManager;

    address constant INU = Addresses.INU;
    IPositionManager constant POSM = IPositionManager(Addresses.POSITION_MANAGER);
    IPermit2 constant PERMIT2 = IPermit2(Addresses.PERMIT2);
    int24 constant TICK_SPACING = 60;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;
    uint8 constant MINT_POSITION = 0x02;
    uint8 constant SETTLE_PAIR = 0x0d;

    function run() external {
        IPoolManager manager = IPoolManager(Addresses.POOL_MANAGER);
        INuSwapHook hook = INuSwapHook(Addresses.HOOK);
        address token = Addresses.partner(vm.envString("TOKEN"));
        uint256 amountInu = vm.envUint("AMOUNT_INU");
        uint256 amountToken = vm.envUint("AMOUNT_TOKEN");

        require(address(hook.poolManager()) == address(manager), "hook is for a different PoolManager");

        // Sort the pair: currency0 is the lower address
        bool inuIs0 = INU < token;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(inuIs0 ? INU : token),
            currency1: Currency.wrap(inuIs0 ? token : INU),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        (uint256 amount0, uint256 amount1) = inuIs0 ? (amountInu, amountToken) : (amountToken, amountInu);

        // Starting price = live market price along the route (read now, used in the same broadcast)
        uint160 sqrtP = PriceRoute.sqrtPriceX96(
            manager, Addresses.priceRoute(token), Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
        );
        (uint160 existing,,,) = manager.getSlot0(key.toId());
        require(existing == 0, "pool already exists");

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(MIN_TICK), TickMath.getSqrtPriceAtTick(MAX_TICK), amount0, amount1
        );
        require(liquidity > 0, "no liquidity");

        uint256 p = FullMath.mulDiv(uint256(sqrtP) * sqrtP, 1e18, 1 << 192); // token1 per token0, 1e18-scaled
        console.log("Pool id:");
        console.logBytes32(PoolId.unwrap(key.toId()));
        console.log("Pair:", IERC20(INU).symbol(), "/", IERC20(token).symbol());
        console.log("Price (token1 per token0, 1e18):", p);
        console.log("  token0:", IERC20(Currency.unwrap(key.currency0)).symbol());
        console.log("  token1:", IERC20(Currency.unwrap(key.currency1)).symbol());
        console.log("Liquidity:", liquidity);

        // The wallet that signs (from --account / --sender). msg.sender is NOT reliable in scripts:
        // with --account alone it is Foundry's placeholder, which would receive the LP NFT.
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(sender != DEFAULT_SENDER, "no signer: pass --account or --sender");
        console.log("Signer / LP NFT owner:", sender);

        uint256 bal0 = key.currency0.balanceOf(sender);
        uint256 bal1 = key.currency1.balanceOf(sender);

        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, MIN_TICK, MAX_TICK, uint256(liquidity), amount0, amount1, sender, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPositionManager.initializePool, (key, sqrtP));
        calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp + 10 minutes));

        _approve(sender, Currency.unwrap(key.currency0), amount0);
        _approve(sender, Currency.unwrap(key.currency1), amount1);
        POSM.multicall(calls); // create + seed in one transaction, so nobody can front-run the price
        vm.stopBroadcast();

        console.log("Deposited token0:", bal0 - key.currency0.balanceOf(sender));
        console.log("Deposited token1:", bal1 - key.currency1.balanceOf(sender));

        // Post-checks
        (uint160 created,,,) = manager.getSlot0(key.toId());
        require(created == sqrtP, "price mismatch");
        (uint8 mult,,,) = hook.currentFees(key);
        require(mult == 1, "not calm at launch");
        console.log("OK: pool live at market price, fees at 1x");
    }

    /// LONG tokens (Solady ERC20) give Permit2 an infinite allowance built in and revert on approve,
    /// so only approve when needed. The spend cap is the exact Permit2 -> PositionManager allowance.
    function _approve(address owner, address token, uint256 amount) internal {
        if (IERC20(token).allowance(owner, address(PERMIT2)) < amount) {
            IERC20(token).approve(address(PERMIT2), amount);
        }
        PERMIT2.approve(token, address(POSM), uint160(amount), uint48(block.timestamp + 1 hours));
    }
}
