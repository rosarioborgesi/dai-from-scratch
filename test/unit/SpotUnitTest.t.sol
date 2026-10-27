// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Spotter} from "../../src/Spot.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {VatLike} from "../../src/Spot.sol";

contract MockVat is VatLike {
    mapping(bytes32 ilk => uint256 spot) public spots;

    function file(bytes32 ilk, bytes32 what, uint256 data) external override {
        require(what == "spot", "MockSpotVat/unrecognized-param");
        spots[ilk] = data;
    }
}

contract SpotUnitTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    bytes32 internal constant ILK = "ETH-A";

    Spotter internal spotter;
    MockOracle internal oracle;
    MockVat internal vat;

    function setUp() public {
        vat = new MockVat();
        oracle = new MockOracle();
        spotter = new Spotter(address(vat));

        spotter.file(ILK, "pip", address(oracle));
        spotter.file("par", RAY); // One Dai is worth $1.
        spotter.file(ILK, "mat", 15e26); // 150% collateralization, in ray.        
    }

    function test_PokeStoresSafetyAdjustedPriceInVat() public {
        // Setting the price of the collateral to $3,000 and has = true
        oracle.setVal(bytes32(uint256(3000 * WAD))); // Oracle prices use wad.

        // Reading from the oracle
        (bytes32 price, bool valid) = oracle.peek();
        assertEq(uint256(price), 3000 * WAD);
        assertTrue(valid);

        spotter.poke(ILK);

        // $3,000 / $1 per Dai / 1.5 = 2,000 Dai per collateral unit.
        // Vat stores the safety-adjusted price in ray (27 decimals).
        assertEq(vat.spots(ILK), 2000 * RAY);
    }

    function test_PokeClearsSpotWhenOracleIsInvalid() public {
        spotter.poke(ILK);
        assertEq(vat.spots(ILK), 2000 * RAY);

        oracle.void();
        spotter.poke(ILK);

        assertEq(vat.spots(ILK), 0);
    }
}
