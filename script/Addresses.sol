// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PriceRoute} from "./PriceRoute.sol";

/// Every Robinhood Chain (4663) address the scripts and fork tests use. Add new partner tokens here.
library Addresses {
    // ------------------------------------------------------------ Uniswap v4
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ------------------------------------------------------------ iNuSwap
    /// Live hook (deploy tx 0x744e28fcee7b02d42906911439fbcd68b256587eb185d71ac51fd81a7effc429)
    address internal constant HOOK = 0xac5187fA1FFBD9882cE6Eba5B29aA0A6692e50Cc;

    // ---------------------------------------------------------------- tokens
    address internal constant INU = 0x63Ee32Ac3077d1fbd8a77eBBA2a6ed4b8e9c1e18;
    address internal constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
    address internal constant BONER = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18;
    address internal constant MEME = 0x385F4f8ae47651ce5F58F5265395a669f8281e18;
    address internal constant MOO = 0xD9dB30BB0D2b8d2eae3826A1372117E058791e18;

    // ------------------------------------------------------------ iNuSwap pools
    /// AI/INU on the hook (created in tx 0xde78c49ba0a9b38af6a8d6953eb93a5e519492abaf76f6447d6f521f46688178)
    bytes32 internal constant INUSWAP_AI_INU_POOL = 0xece5b96aee6848dd9c0c549e8700878be0cfbaf07ef676e829e33a99fc3e35ad;

    // ----------------------------------------------------------- price pools
    /// The existing hookless AI/INU pool (0.2%, tick spacing 20), used as the AI price source
    bytes32 internal constant AI_INU_POOL = 0xcc9ff7f12eb7546b83431ccd44068a424cba6438b398ab1766b787b11f439c3c;
    /// Deepest hookless X/AI pools, used to price X through AI
    bytes32 internal constant BONER_AI_POOL = 0x1f1778596d8c1ee3e1eaf64ea83a5e77063b142fa3ef59a7c81e520c516379bc; // 0.9%
    bytes32 internal constant MEME_AI_POOL = 0x2c226b0a1045aff5e702928a6e5ddfa480092913acf722a06ee2d7041bb3dd4e; // 0.31%
    bytes32 internal constant MOO_AI_POOL = 0x827bc6826b2328942e512791bb1f653335d6b496330d3da6a7b96eda60456432; // 0.9%

    /// All partner tokens (the X in iNu/X)
    function partners() internal pure returns (address[4] memory) {
        return [AI, BONER, MEME, MOO];
    }

    /// Look up a partner token by symbol, e.g. "AI"
    function partner(string memory symbol) internal pure returns (address) {
        bytes32 s = keccak256(bytes(symbol));
        if (s == keccak256("AI")) return AI;
        if (s == keccak256("BONER")) return BONER;
        if (s == keccak256("MEME")) return MEME;
        if (s == keccak256("MOO")) return MOO;
        revert(string.concat("unknown token: ", symbol));
    }

    /// The live-price route from INU to a partner token, read at launch for the new pool's starting price.
    /// AI prices directly off the AI/INU pool; other tokens go INU -> AI -> X through their deepest X/AI pool.
    function priceRoute(address token) internal pure returns (PriceRoute.Hop[] memory hops) {
        if (token == AI) {
            hops = new PriceRoute.Hop[](1);
            hops[0] = PriceRoute.Hop(AI_INU_POOL, INU, AI);
            return hops;
        }
        bytes32 xAi;
        if (token == BONER) xAi = BONER_AI_POOL;
        else if (token == MEME) xAi = MEME_AI_POOL;
        else if (token == MOO) xAi = MOO_AI_POOL;
        else revert("no price route for this token");
        hops = new PriceRoute.Hop[](2);
        hops[0] = PriceRoute.Hop(AI_INU_POOL, INU, AI);
        hops[1] = PriceRoute.Hop(xAi, AI, token);
    }
}
